import Foundation

/// Sports, mirroring ACTIVITIES in index.html.
enum Activity: String, Codable, CaseIterable, Identifiable {
    case mt, bjj
    var id: String { rawValue }
    var label: String { self == .mt ? "Muay Thai" : "BJJ" }
    var icon: String { self == .mt ? "🥊" : "🥋" }
}

enum TimerMode: String, Codable, CaseIterable { case continuous, rounds }
enum Bells: String, Codable { case on, off }

/// Per-sport round-timer config. Defaults mirror `defaultTimers`.
struct TimerConfig: Codable, Equatable {
    var mode: TimerMode = .continuous
    var roundMin: Double = 3
    var restMin: Double = 1
    var rounds: Int = 5
    var bells: Bells = .on

    static func defaults(for a: Activity) -> TimerConfig {
        switch a {
        case .mt:  return TimerConfig(mode: .continuous, roundMin: 3, restMin: 1, rounds: 5, bells: .on)
        case .bjj: return TimerConfig(mode: .continuous, roundMin: 5, restMin: 1, rounds: 5, bells: .on)
        }
    }
}
