import Foundation
import AVFoundation
import CoreImage
import UIKit
import Photos

/// Records video from the back camera with a live BPM + zone overlay burned
/// into each frame, then saves the finished .mov to the Photos library.
final class VideoRecorder: NSObject, ObservableObject,
                           AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var ready = false
    @Published var savedMessage: String?

    let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "fighthr.recorder")
    private let ciContext = CIContext()

    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startPTS: CMTime = .invalid
    private var fileURL: URL?
    // Recording state used on the capture queue; isRecording mirrors it for UI.
    private var active = false
    private var pendingStart = false
    private var lastElapsedWhole = -1
    private var lastHeartbeatWhole = -1
    private var frameWidth = 0
    private var frameHeight = 0
    private var captureDroppedFrames = 0
    private var backpressureDroppedFrames = 0
    private var observers: [NSObjectProtocol] = []

    private enum StopReason: String {
        case user
        case viewClosed = "view_closed"
        case appBackgrounded = "app_backgrounded"
        case captureInterrupted = "capture_interrupted"
        case captureRuntimeError = "capture_runtime_error"
        case encoderStalled = "encoder_stalled"
        case writerFailed = "writer_failed"

        var unexpected: Bool {
            switch self {
            case .user: return false
            default: return true
            }
        }
    }

    /// Pulled each frame to draw the overlay. Set by the view from live HR.
    var overlayProvider: () -> (bpm: Int, zone: Int) = { (0, -1) }

    // MARK: orientation
    /// Orientation the camera records in. It used to be hard-locked to
    /// .portrait at setup, so filming with the phone upside down (propped or
    /// clipped to a tripod) produced a 180°-rotated video with the HR badge
    /// upside down in the corner. Now it follows the device, and is frozen for
    /// the duration of a recording — changing it mid-file would change the
    /// frame dimensions and break the writer.
    @Published private(set) var captureOrientation: CaptureOrientation = .portrait

    private static func captureOrientation(from device: UIDeviceOrientation) -> CaptureOrientation? {
        switch device {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil          // faceUp/faceDown/unknown — keep last good
        }
    }

    /// Legacy path for iOS 16, which has no videoRotationAngle. A device held
    /// landscape-left produces a landscape-right video frame.
    private static func legacyOrientation(_ o: CaptureOrientation) -> AVCaptureVideoOrientation {
        switch o {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        }
    }

    static func apply(_ o: CaptureOrientation, to connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            let angle = CGFloat(o.rotationAngle)
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = legacyOrientation(o)
        }
    }

    @objc private func deviceOrientationChanged() {
        // Never re-orient mid-recording: the writer is sized to the first
        // frame, so a rotation would change frame dimensions and stall it.
        guard !isRecording,
              let o = Self.captureOrientation(from: UIDevice.current.orientation),
              o != captureOrientation else { return }
        captureOrientation = o
        queue.async { [weak self] in
            guard let self, !self.active,
                  let c = self.videoOut.connection(with: .video) else { return }
            Self.apply(o, to: c)
        }
    }

    override init() {
        super.init()
        // Seed from the device now, then track it.
        if let o = Self.captureOrientation(from: UIDevice.current.orientation) { captureOrientation = o }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceOrientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)

        // Screen lock, phone call, app switch, camera grabbed by another app:
        // finish and save the recording instead of abandoning the file.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard self?.isRecording == true else { return }
            Telemetry.recordingSignal("video.app_became_inactive")
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.finish(note: "Backgrounded — video saved", reason: .appBackgrounded)
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                        object: session, queue: .main) { [weak self] notification in
            let interruption = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            Telemetry.recordingSignal("video.capture_interrupted",
                                      data: ["interruption_reason": interruption ?? -1])
            self?.finish(note: "Camera interrupted — video saved", reason: .captureInterrupted)
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                        object: session, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.finish(note: "Camera error — video saved", reason: .captureRuntimeError,
                         error: error)
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                        object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.configured, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard self?.isRecording == true else { return }
            Telemetry.recordingSignal("video.memory_warning")
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // MARK: setup
    private var configured = false
    func configure() {
        queue.async { [weak self] in
            guard let self, !self.configured else { return }
            self.configured = true
            // Capture-safe audio category BEFORE the session starts, so bells
            // and spoken cues can't tear down the mic route mid-recording.
            AudioHub.beginCapture()
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            // camera
            if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let vin = try? AVCaptureDeviceInput(device: cam), self.session.canAddInput(vin) {
                self.session.addInput(vin)
            }
            // mic
            if let mic = AVCaptureDevice.default(for: .audio),
               let ain = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(ain) {
                self.session.addInput(ain)
            }
            self.videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            // Never allow camera frames to queue without bound when Core Image
            // or the encoder is briefly slower than the capture frame rate.
            self.videoOut.alwaysDiscardsLateVideoFrames = true
            self.videoOut.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(self.videoOut) { self.session.addOutput(self.videoOut) }
            self.audioOut.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(self.audioOut) { self.session.addOutput(self.audioOut) }
            if let c = self.videoOut.connection(with: .video) {
                Self.apply(self.captureOrientation, to: c)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.ready = true }
        }
    }

    /// Stops the camera. If a recording is in flight it is finished and saved
    /// first — the writer is kept alive by its completion handler, so the file
    /// lands in Photos even if this object is deallocated right after.
    func stopSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.finishOnQueue(note: nil, reason: .viewClosed)
            if self.session.isRunning { self.session.stopRunning() }
            self.configured = false
            AudioHub.endCapture()
        }
    }

    // MARK: record
    func toggle() { isRecording ? finish() : start() }

    private func start() {
        queue.async { [weak self] in
            guard let self, !self.active else { return }
            // Writer is built lazily on the first frame so it matches the real
            // capture dimensions (avoids cropping / off-screen overlay).
            self.writer = nil; self.videoIn = nil; self.audioIn = nil
            self.adaptor = nil; self.startPTS = .invalid
            self.lastElapsedWhole = -1
            self.lastHeartbeatWhole = -1
            self.droppedFrames = 0
            self.captureDroppedFrames = 0
            self.backpressureDroppedFrames = 0
            self.frameWidth = 0; self.frameHeight = 0
            self.cachedKey = ""       // resolution may differ from the last take
            self.active = true
            self.pendingStart = true
            Telemetry.recordingStarted(orientation: self.captureOrientation)
            DispatchQueue.main.async { self.isRecording = true; self.elapsed = 0; self.savedMessage = nil }
        }
    }

    func finish(note: String? = nil) {
        finish(note: note, reason: .user)
    }

    private func finish(note: String?, reason: StopReason, error: Error? = nil) {
        queue.async { [weak self] in self?.finishOnQueue(note: note, reason: reason, error: error) }
    }

    private func finishOnQueue(note: String?, reason: StopReason, error: Error? = nil) {
        guard active else { return }
        active = false
        pendingStart = false
        let recordedElapsed = startPTS == .invalid ? 0 : Double(max(0, lastElapsedWhole))
        DispatchQueue.main.async { self.isRecording = false }
        defer {
            writer = nil; videoIn = nil; audioIn = nil
            adaptor = nil; startPTS = .invalid; fileURL = nil
        }
        guard let w = writer, let url = fileURL, w.status == .writing else {
            let failure = error ?? writer?.error
            let reason = failure?.localizedDescription ?? "no video frames captured"
            Telemetry.recordingFinished(reason: StopReason.writerFailed.rawValue,
                                        elapsed: recordedElapsed, unexpected: true,
                                        error: failure)
            DispatchQueue.main.async { self.savedMessage = "Recording failed (\(reason))" }
            return
        }
        Telemetry.recordingFinished(reason: reason.rawValue, elapsed: recordedElapsed,
                                    unexpected: reason.unexpected, error: error)
        videoIn?.markAsFinished(); audioIn?.markAsFinished()
        // The closure holds `w` and `url` strongly: writing + saving complete
        // even if the view (and this recorder) are dismissed meanwhile.
        w.finishWriting { [weak self] in
            if w.status == .completed {
                VideoRecorder.saveToPhotos(url) { ok, denied in
                    Telemetry.videoSaved(ok: ok, denied: denied)
                    DispatchQueue.main.async {
                        self?.savedMessage = ok ? (note ?? "Saved to Photos ✓")
                            : denied ? "Allow Photos access in Settings to save videos"
                            : "Save to Photos failed"
                    }
                }
            } else {
                let reason = w.error?.localizedDescription ?? "unknown error"
                Telemetry.recordingFinished(reason: StopReason.writerFailed.rawValue,
                                            elapsed: recordedElapsed, unexpected: true,
                                            error: w.error)
                DispatchQueue.main.async { self?.savedMessage = "Recording failed (\(reason))" }
            }
        }
    }

    /// Build the writer sized to the actual frame (called on first video buffer).
    private func setupWriter(width: Int, height: Int) throws {
        frameWidth = width
        frameHeight = height
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fighthr-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = true
        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100,
        ]
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        aIn.expectsMediaDataInRealTime = true
        guard w.canAdd(vIn) else { throw RecorderError.cannotAddVideoInput }
        w.add(vIn)
        let acceptedAudioInput: AVAssetWriterInput?
        if w.canAdd(aIn) {
            w.add(aIn)
            acceptedAudioInput = aIn
        } else {
            acceptedAudioInput = nil
            Telemetry.recordingSignal("video.audio_writer_input_unavailable")
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: attrs)
        self.writer = w; self.videoIn = vIn; self.audioIn = acceptedAudioInput; self.fileURL = url
    }

    private enum RecorderError: LocalizedError {
        case cannotAddVideoInput

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput: return "The video encoder rejected the camera format."
            }
        }
    }

    private static func saveToPhotos(_ url: URL, done: @escaping (_ ok: Bool, _ denied: Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { done(false, true); return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, _ in
                if ok { try? FileManager.default.removeItem(at: url) }
                done(ok, false)
            }
        }
    }

    // MARK: capture delegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Core Image / CoreVideo autorelease heavily at 30fps. Without an
        // explicit pool the capture queue never drains and memory climbs until
        // iOS kills the app — that was the long-recording crash.
        autoreleasepool { handle(output, sampleBuffer) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active, output == videoOut else { return }
        captureDroppedFrames += 1
    }

    private func handle(_ output: AVCaptureOutput, _ sampleBuffer: CMSampleBuffer) {
        guard active else { return }
        // Build the writer on the first video frame, sized to that frame.
        if pendingStart {
            guard output == videoOut, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            pendingStart = false
            do {
                try setupWriter(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
            } catch {
                finishOnQueue(note: nil, reason: .writerFailed, error: error)
                return
            }
        }
        guard let w = writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startPTS == .invalid {
            guard output == videoOut else { return }   // start the timeline on a video frame
            guard w.startWriting() else {
                finishOnQueue(note: nil, reason: .writerFailed, error: w.error)
                return
            }
            w.startSession(atSourceTime: pts)
            startPTS = pts
        }
        if output == videoOut {
            appendVideo(sampleBuffer, pts: pts)
            let secs = CMTimeGetSeconds(pts - startPTS)
            let whole = Int(secs)
            if whole != lastElapsedWhole {   // one UI update per second, not per frame
                lastElapsedWhole = whole
                DispatchQueue.main.async { self.elapsed = secs }
            }
            if whole > 0 && whole % 30 == 0 && whole != lastHeartbeatWhole {
                lastHeartbeatWhole = whole
                Telemetry.recordingHeartbeat(elapsed: secs, width: frameWidth, height: frameHeight,
                                             encoderFailures: droppedFrames,
                                             captureDrops: captureDroppedFrames,
                                             backpressureDrops: backpressureDroppedFrames)
            }
        } else if output == audioOut, let aIn = audioIn, aIn.isReadyForMoreMediaData {
            aIn.append(sampleBuffer)
        }
        if w.status == .failed {
            finishOnQueue(note: nil, reason: .writerFailed, error: w.error)
        }
    }

    private func appendVideo(_ sb: CMSampleBuffer, pts: CMTime) {
        guard let vIn = videoIn, let adaptor,
              let src = CMSampleBufferGetImageBuffer(sb) else {
            recordEncoderFailure("missing writer input, adaptor, or camera buffer")
            return
        }
        guard vIn.isReadyForMoreMediaData else {
            backpressureDroppedFrames += 1
            return
        }
        guard let pool = adaptor.pixelBufferPool else {
            recordEncoderFailure("pixel buffer pool unavailable")
            return
        }
        // draw overlay onto the camera frame, into a fresh writable buffer from the pool
        var out: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard allocation == kCVReturnSuccess, let dst = out else {
            recordEncoderFailure("pixel buffer allocation failed (\(allocation))")
            return
        }
        let composited = overlay(on: CIImage(cvPixelBuffer: src))
        ciContext.render(composited, to: dst)
        if !adaptor.append(dst, withPresentationTime: pts) {
            recordEncoderFailure("asset writer rejected a rendered frame")
        } else {
            droppedFrames = 0
        }
    }

    private func recordEncoderFailure(_ detail: String) {
        droppedFrames += 1
        if droppedFrames == 1 {
            Telemetry.recordingSignal("video.encoder_frame_failed", data: ["detail": detail])
        }
        // A handful of drops is normal under load; sustained failures mean the
        // writer is no longer producing a usable file.
        if droppedFrames > 90 {
            finishOnQueue(note: "Recording ended early (encoder stalled)", reason: .encoderStalled)
        }
    }
    private var droppedFrames = 0

    // MARK: overlay
    private var cachedKey = ""
    private var cachedLabel = CIImage.empty()

    /// Burn the HR badge (heart + big BPM + zone pill) into the frame.
    /// Re-rendered only when the value changes; a stale signal shows "--".
    private func overlay(on base: CIImage) -> CIImage {
        let (bpm, zone) = overlayProvider()
        let extent = base.extent
        // Scale off the SHORT edge so the badge is the same relative size in
        // portrait (1080x1920) and landscape (1920x1080).
        let scale = max(0.75, min(extent.width, extent.height) / 1080)
        let key = "\(bpm)|\(zone)|\(scale)"
        if key != cachedKey {
            cachedKey = key
            cachedLabel = Self.renderBadge(bpm: bpm, zone: zone, scale: scale)
        }
        let margin = 40 * scale
        let tx = extent.minX + margin
        let ty = extent.maxY - cachedLabel.extent.height - margin
        let placed = cachedLabel.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        return placed.composited(over: base)
    }

    static func pillLabel(bpm: Int, zone: Int) -> String {
        VideoOverlayRenderer.pillLabel(bpm: bpm, zone: zone)
    }

    private static func renderBadge(bpm: Int, zone: Int, scale: CGFloat) -> CIImage {
        VideoOverlayRenderer.renderBadge(bpm: bpm, zone: zone, scale: scale)
    }
}
