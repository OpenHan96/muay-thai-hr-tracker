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

    /// Pulled each frame to draw the overlay. Set by the view from live HR.
    var overlayProvider: () -> (bpm: Int, zone: Int) = { (0, -1) }

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

    func stopSession() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    // MARK: record
    func toggle() { isRecording ? finish() : start() }

    private func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fighthr-\(Int(Date().timeIntervalSince1970)).mov")
            try? FileManager.default.removeItem(at: url)
            guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let vSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080, AVVideoHeightKey: 1920,
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
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920,
            ]
            self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: attrs)
            self.writer = w; self.videoIn = vIn; self.audioIn = aIn
            self.fileURL = url; self.startPTS = .invalid
            DispatchQueue.main.async { self.isRecording = true; self.elapsed = 0 }
        }
    }

    private func finish() {
        queue.async { [weak self] in
            guard let self, let w = self.writer else { return }
            self.videoIn?.markAsFinished(); self.audioIn?.markAsFinished()
            w.finishWriting { [weak self] in
                guard let self, let url = self.fileURL else { return }
                if w.status == .completed { self.saveToPhotos(url) }
                self.writer = nil; self.videoIn = nil; self.audioIn = nil
                DispatchQueue.main.async { self.isRecording = false }
            }
        }
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.savedMessage = "Saved to app (Photos access denied)" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, _ in
                DispatchQueue.main.async { self.savedMessage = ok ? "Saved to Photos ✓" : "Save failed" }
            }
        }
    }

    // MARK: capture delegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording, let w = writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startPTS == .invalid {
            startPTS = pts
            w.startWriting(); w.startSession(atSourceTime: pts)
        }
        if output == videoOut {
            appendVideo(sampleBuffer, pts: pts)
            DispatchQueue.main.async { self.elapsed = CMTimeGetSeconds(pts - self.startPTS) }
        } else if output == audioOut, let aIn = audioIn, aIn.isReadyForMoreMediaData {
            aIn.append(sampleBuffer)
        }
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

    /// Burn big BPM + zone name into the frame.
    private func overlay(on base: CIImage) -> CIImage {
        let (bpm, zone) = overlayProvider()
        guard bpm > 0 else { return base }
        let zoneName = zone < 0 ? "—" : Theme.zoneNames[zone]
        let text = "\(bpm) BPM   \(zoneName)"
        let extent = base.extent
        let label = makeLabel(text, maxWidth: extent.width)
        // position near top-left with padding
        let tx = extent.minX + 40
        let ty = extent.maxY - label.extent.height - 60
        let placed = label.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        return placed.composited(over: base)
    }

    private func makeLabel(_ text: String, maxWidth: CGFloat) -> CIImage {
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
