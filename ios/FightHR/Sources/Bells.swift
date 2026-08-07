import Foundation
import AVFoundation
import UIKit

/// Single owner of the shared AVAudioSession.
///
/// Bells and spoken cues used to each call `setCategory(.playback…)` whenever
/// they fired. Doing that while the camera is capturing tears down the audio
/// route and interrupts AVCaptureSession — every round bell or zone
/// announcement could stop a recording. Now the category is set in one place
/// and only changes when capture starts or stops.
enum AudioHub {
    private static var capturing = false
    private static var configured = false
    private static let lock = NSLock()

    /// Switch to a capture-safe category. Call before starting the camera.
    static func beginCapture() { set(capturing: true) }
    /// Return to plain playback once the camera is torn down.
    static func endCapture() { set(capturing: false) }

    /// Bells/speech call this; it is a no-op while capturing.
    static func ensureReady() {
        lock.lock(); let done = configured; lock.unlock()
        if !done { set(capturing: capturing) }
    }

    private static func set(capturing wantsCapture: Bool) {
        lock.lock()
        capturing = wantsCapture
        configured = true
        lock.unlock()
        let s = AVAudioSession.sharedInstance()
        if wantsCapture {
            // playAndRecord keeps the mic alive for AVCaptureSession while the
            // bells still play out loud through the speaker.
            try? s.setCategory(.playAndRecord, mode: .videoRecording,
                               options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        } else {
            try? s.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        }
        try? s.setActive(true)
    }
}

/// Round-bell + warning tones, generated as short sine buffers (no asset files needed).
/// Mirrors bell(times) / clack() from index.html. Adds haptics for the gym.
enum Chime {
    private static let engine = AVAudioEngine()

    /// Ring `times` bell tones, 0.45s apart at 880Hz.
    static func play(_ times: Int, enabled: Bool) {
        guard enabled else { return }
        AudioHub.ensureReady()
        for i in 0..<times {
            tone(freq: 880, dur: 0.9, after: Double(i) * 0.45)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 10-second warning: two quick high clacks.
    static func clack() {
        AudioHub.ensureReady()
        for i in 0..<2 { tone(freq: 1700, dur: 0.08, after: Double(i) * 0.18) }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private static func tone(freq: Double, dur: Double, after: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            let player = AVAudioPlayerNode()
            let rate = 44100.0
            let frames = AVAudioFrameCount(dur * rate)
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
            buf.frameLength = frames
            let ptr = buf.floatChannelData![0]
            for n in 0..<Int(frames) {
                let t = Double(n) / rate
                let env = exp(-t / (dur * 0.4))            // exponential decay
                ptr[n] = Float(sin(2 * .pi * freq * t) * 0.6 * env)
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            if !engine.isRunning {
                // Starting can fail if the route is mid-change; drop the tone
                // rather than scheduling onto a dead engine.
                do { try engine.start() } catch { engine.detach(player); return }
            }
            player.scheduleBuffer(buf) {
                DispatchQueue.main.async { engine.detach(player) }
            }
            player.play()
        }
    }
}
