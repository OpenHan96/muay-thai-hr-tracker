import Foundation
import AVFoundation

/// Spoken zone announcements via text-to-speech. Ducks other audio so it
/// coexists with the round bells (Chime).
enum Announcer {
    private static let synth = AVSpeechSynthesizer()

    /// Speak the current zone, e.g. "Zone 4, Threshold". zone is 0...4, or -1 (below).
    static func announceZone(_ zone: Int) {
        let text: String
        if zone < 0 {
            text = "Below zone 1"
        } else {
            // ZONE_NAMES like "Z4 Threshold" -> "Zone 4, Threshold"
            let parts = Theme.zoneNames[zone].split(separator: " ")
            let name = parts.count > 1 ? String(parts[1]) : ""
            text = "Zone \(zone + 1), \(name)"
        }
        speak(text)
    }

    static func speak(_ text: String) {
        // Duck/mix with the bells; don't interrupt an in-flight utterance abruptly.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.volume = 1.0
        synth.speak(u)
    }
}
