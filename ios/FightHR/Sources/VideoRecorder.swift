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
    private var observers: [NSObjectProtocol] = []

    /// Pulled each frame to draw the overlay. Set by the view from live HR.
    var overlayProvider: () -> (bpm: Int, zone: Int) = { (0, -1) }

    override init() {
        super.init()
        // Screen lock, phone call, app switch, camera grabbed by another app:
        // finish and save the recording instead of abandoning the file.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.finish(note: "Interrupted — video saved")
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                        object: session, queue: .main) { [weak self] _ in
            self?.finish(note: "Camera interrupted — video saved")
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                        object: session, queue: .main) { [weak self] _ in
            self?.finish(note: "Camera error — video saved")
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                        object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.queue.async { if !self.session.isRunning { self.session.startRunning() } }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: setup
    func configure() {
        queue.async { [weak self] in
            guard let self else { return }
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
            self.videoOut.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(self.videoOut) { self.session.addOutput(self.videoOut) }
            self.audioOut.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(self.audioOut) { self.session.addOutput(self.audioOut) }
            if let c = self.videoOut.connection(with: .video), c.isVideoOrientationSupported {
                c.videoOrientation = .portrait
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
            self.finishOnQueue(note: nil)
            if self.session.isRunning { self.session.stopRunning() }
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
            self.active = true
            self.pendingStart = true
            DispatchQueue.main.async { self.isRecording = true; self.elapsed = 0; self.savedMessage = nil }
        }
    }

    func finish(note: String? = nil) {
        queue.async { [weak self] in self?.finishOnQueue(note: note) }
    }

    private func finishOnQueue(note: String?) {
        guard active else { return }
        active = false
        pendingStart = false
        DispatchQueue.main.async { self.isRecording = false }
        defer {
            writer = nil; videoIn = nil; audioIn = nil
            adaptor = nil; startPTS = .invalid; fileURL = nil
        }
        guard let w = writer, let url = fileURL, w.status == .writing else {
            let reason = writer?.error?.localizedDescription ?? "no video frames captured"
            DispatchQueue.main.async { self.savedMessage = "Recording failed (\(reason))" }
            return
        }
        videoIn?.markAsFinished(); audioIn?.markAsFinished()
        // The closure holds `w` and `url` strongly: writing + saving complete
        // even if the view (and this recorder) are dismissed meanwhile.
        w.finishWriting { [weak self] in
            if w.status == .completed {
                VideoRecorder.saveToPhotos(url) { ok, denied in
                    DispatchQueue.main.async {
                        self?.savedMessage = ok ? (note ?? "Saved to Photos ✓")
                            : denied ? "Allow Photos access in Settings to save videos"
                            : "Save to Photos failed"
                    }
                }
            } else {
                let reason = w.error?.localizedDescription ?? "unknown error"
                DispatchQueue.main.async { self?.savedMessage = "Recording failed (\(reason))" }
            }
        }
    }

    /// Build the writer sized to the actual frame (called on first video buffer).
    private func setupWriter(width: Int, height: Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fighthr-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
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
        if w.canAdd(vIn) { w.add(vIn) }
        if w.canAdd(aIn) { w.add(aIn) }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: attrs)
        self.writer = w; self.videoIn = vIn; self.audioIn = aIn; self.fileURL = url
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
        guard active else { return }
        // Build the writer on the first video frame, sized to that frame.
        if pendingStart {
            guard output == videoOut, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            setupWriter(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
            pendingStart = false
        }
        guard let w = writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startPTS == .invalid {
            guard output == videoOut else { return }   // start the timeline on a video frame
            guard w.startWriting() else {
                let reason = w.error?.localizedDescription ?? "writer error"
                active = false
                writer = nil; videoIn = nil; audioIn = nil; adaptor = nil
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.savedMessage = "Recording failed (\(reason))"
                }
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
        } else if output == audioOut, let aIn = audioIn, aIn.isReadyForMoreMediaData {
            aIn.append(sampleBuffer)
        }
        if w.status == .failed { finishOnQueue(note: nil) }   // disk full etc. — surface it
    }

    private func appendVideo(_ sb: CMSampleBuffer, pts: CMTime) {
        guard let vIn = videoIn, vIn.isReadyForMoreMediaData,
              let adaptor, let pool = adaptor.pixelBufferPool,
              let src = CMSampleBufferGetImageBuffer(sb) else { return }
        // draw overlay onto the camera frame, into a fresh writable buffer from the pool
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let dst = out else { return }
        let composited = overlay(on: CIImage(cvPixelBuffer: src))
        ciContext.render(composited, to: dst)
        adaptor.append(dst, withPresentationTime: pts)
    }

    // MARK: overlay
    private var cachedText = ""
    private var cachedLabel = CIImage.empty()

    /// Burn big BPM + zone name into the frame. Always draws (shows "--" with
    /// no HR). The label bitmap is re-rendered only when the text changes.
    private func overlay(on base: CIImage) -> CIImage {
        let (bpm, zone) = overlayProvider()
        let bpmText = bpm > 0 ? "\(bpm)" : "--"
        let zoneName = (bpm <= 0 || zone < 0) ? "—" : Theme.zoneNames[zone]
        let text = "\(bpmText) BPM   \(zoneName)"
        if text != cachedText {
            cachedText = text
            cachedLabel = makeLabel(text)
        }
        let extent = base.extent
        // top-left with padding, in the base frame's coordinate space
        let tx = extent.minX + 40
        let ty = extent.maxY - cachedLabel.extent.height - 40
        let placed = cachedLabel.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        return placed.composited(over: base)
    }

    private func makeLabel(_ text: String) -> CIImage {
        let font = UIFont.systemFont(ofSize: 72, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black, .strokeWidth: -4,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 24
        let rect = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let renderer = UIGraphicsImageRenderer(size: rect)
        let img = renderer.image { ctx in
            UIColor.black.withAlphaComponent(0.35).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: rect), cornerRadius: 16).fill()
            (text as NSString).draw(at: CGPoint(x: pad, y: pad), withAttributes: attrs)
        }
        // UIKit images are y-flipped relative to CoreImage; flip back
        let ci = CIImage(image: img) ?? CIImage.empty()
        return ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ci.extent.height))
    }
}
