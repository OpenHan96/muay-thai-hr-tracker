import Foundation
import AVFoundation
import UIKit

/// Round-bell + warning tones, generated as short sine buffers (no asset files needed).
/// Mirrors bell(times) / clack() from index.html. Adds haptics for the gym.
enum Bells {
    private static let engine = AVAudioEngine()
    private static var started = false

    private static func ensureStarted() {
        guard !started else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        started = true
    }

    /// Ring `times` bell tones, 0.45s apart at 880Hz.
    static func play(_ times: Int, enabled: Bool) {
        guard enabled else { return }
        ensureStarted()
        for i in 0..<times {
            tone(freq: 880, dur: 0.9, after: Double(i) * 0.45)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 10-second warning: two quick high clacks.
    static func clack() {
        ensureStarted()
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
            if !engine.isRunning { try? engine.start() }
            player.scheduleBuffer(buf) {
                DispatchQueue.main.async { engine.detach(player) }
            }
            player.play()
        }
    }
}
