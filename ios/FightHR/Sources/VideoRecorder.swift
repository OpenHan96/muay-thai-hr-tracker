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
    private var cachedKey = ""
    private var cachedLabel = CIImage.empty()

    /// Burn the HR badge (heart + big BPM + zone pill) into the frame.
    /// Re-rendered only when the value changes; a stale signal shows "--".
    private func overlay(on base: CIImage) -> CIImage {
        let (bpm, zone) = overlayProvider()
        let extent = base.extent
        let scale = max(1, extent.width / 1080)   // badge designed for 1080-wide video
        let key = "\(bpm)|\(zone)"
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

    /// Z1..Z5 fills, mirroring Theme.zoneColors for UIKit drawing.
    private static let zoneFill: [UIColor] = [
        UIColor(red: 0x5d / 255.0, green: 0x8a / 255.0, blue: 0xa8 / 255.0, alpha: 1),
        UIColor(red: 0x2a / 255.0, green: 0x9d / 255.0, blue: 0x8f / 255.0, alpha: 1),
        UIColor(red: 0xe9 / 255.0, green: 0xc4 / 255.0, blue: 0x6a / 255.0, alpha: 1),
        UIColor(red: 0xf4 / 255.0, green: 0xa2 / 255.0, blue: 0x61 / 255.0, alpha: 1),
        UIColor(red: 0xe6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 1),
    ]

    static func pillLabel(bpm: Int, zone: Int) -> String {
        guard bpm > 0 else { return "NO SIGNAL" }
        guard zone >= 0 else { return "WARM-UP" }
        let parts = Theme.zoneNames[zone].split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? "\(parts[0]) · \(String(parts[1]).uppercased())"
                               : Theme.zoneNames[zone].uppercased()
    }

    private static func renderBadge(bpm: Int, zone: Int, scale: CGFloat) -> CIImage {
        let hasHR = bpm > 0
        let pad: CGFloat = 30, gap: CGFloat = 16

        let numFont: UIFont = {
            let f = UIFont.monospacedDigitSystemFont(ofSize: 110, weight: .heavy)
            guard let d = f.fontDescriptor.withDesign(.rounded) else { return f }
            return UIFont(descriptor: d, size: 110)
        }()
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: 3)
        let numText = hasHR ? "\(bpm)" : "--"
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: numFont, .foregroundColor: UIColor.white, .shadow: shadow,
        ]
        let numSize = (numText as NSString).size(withAttributes: numAttrs)

        let bpmFont = UIFont.systemFont(ofSize: 30, weight: .bold)
        let bpmAttrs: [NSAttributedString.Key: Any] = [
            .font: bpmFont, .foregroundColor: UIColor(white: 1, alpha: 0.55), .kern: 3,
        ]
        let bpmSize = ("BPM" as NSString).size(withAttributes: bpmAttrs)

        let heartCfg = UIImage.SymbolConfiguration(pointSize: 58, weight: .bold)
        let heartTint = hasHR ? zoneFill[4] : UIColor(white: 1, alpha: 0.35)
        let heart = UIImage(systemName: "heart.fill", withConfiguration: heartCfg)?
            .withTintColor(heartTint, renderingMode: .alwaysOriginal)
        let heartSz = heart?.size ?? CGSize(width: 58, height: 52)

        let pillText = pillLabel(bpm: bpm, zone: zone)
        let inZone = hasHR && zone >= 0
        let darkText = zone == 2 || zone == 3   // yellow/orange pills read better dark
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 33, weight: .heavy),
            .foregroundColor: inZone
                ? (darkText ? UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1) : UIColor.white)
                : UIColor(white: 1, alpha: 0.7),
            .kern: 1.5,
        ]
        let pillTextSize = (pillText as NSString).size(withAttributes: pillAttrs)
        let pillFill: UIColor = inZone ? zoneFill[zone] : UIColor(white: 1, alpha: 0.15)
        let pillH = pillTextSize.height + 26
        let pillW = pillTextSize.width + 54

        let row1H = max(heartSz.height, numSize.height)
        let row1W = heartSz.width + 22 + numSize.width + 16 + bpmSize.width
        let W = max(row1W, pillW) + pad * 2
        let H = pad + row1H + gap + pillH + pad

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale   // sizes above are pixels on a 1080-wide frame
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt)
        let img = renderer.image { _ in
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerRadius: 34).fill()

            var x = pad
            heart?.draw(at: CGPoint(x: x, y: pad + (row1H - heartSz.height) / 2))
            x += heartSz.width + 22

            let numY = pad + (row1H - numSize.height) / 2
            (numText as NSString).draw(at: CGPoint(x: x, y: numY), withAttributes: numAttrs)

            // share the number's baseline
            let bpmY = numY + numFont.ascender - bpmFont.ascender
            ("BPM" as NSString).draw(at: CGPoint(x: x + numSize.width + 16, y: bpmY),
                                     withAttributes: bpmAttrs)

            let pillY = pad + row1H + gap
            pillFill.setFill()
            UIBezierPath(roundedRect: CGRect(x: pad, y: pillY, width: pillW, height: pillH),
                         cornerRadius: pillH / 2).fill()
            (pillText as NSString).draw(
                at: CGPoint(x: pad + (pillW - pillTextSize.width) / 2,
                            y: pillY + (pillH - pillTextSize.height) / 2),
                withAttributes: pillAttrs)
        }
        // UIKit images are y-flipped relative to CoreImage; flip back
        let ci = CIImage(image: img) ?? CIImage.empty()
        return ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ci.extent.height))
    }
}
