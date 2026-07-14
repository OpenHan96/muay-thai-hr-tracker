import Foundation

/// Activities that can be recorded with the native heart-rate tracker.
enum Activity: String, Codable, CaseIterable, Identifiable {
    case mt, bjj, run, sauna, iceBath = "ice_bath"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mt: return "Muay Thai"
        case .bjj: return "BJJ"
        case .run: return "Running"
        case .sauna: return "Sauna"
        case .iceBath: return "Ice Bath"
        }
    }

    var icon: String {
        switch self {
        case .mt: return "🥊"
        case .bjj: return "🥋"
        case .run: return "🏃"
        case .sauna: return "🧖"
        case .iceBath: return "🧊"
        }
    }

    /// Running uses GPS for distance/pace/route.
    var usesGPS: Bool { self == .run }

    /// Recovery therapies are intentionally continuous sessions, not round timers.
    var supportsRounds: Bool { self != .sauna && self != .iceBath }

    /// A representative demo signal so therapy flows can be tried without a strap.
    func demoHeartRate(at elapsed: Double) -> Double {
        switch self {
        case .sauna: return 110 + 12 * sin(elapsed / 45)
        case .iceBath: return 82 + 8 * sin(elapsed / 30)
        case .mt, .bjj, .run: return 155 + 20 * sin(elapsed / 40)
        }
    }
}

enum TimerMode: String, Codable, CaseIterable { case continuous, rounds }
enum Bells: String, Codable { case on, off }

/// Per-activity timer config. Combat sports and running may use rounds; therapies are continuous.
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
        case .run: return TimerConfig(mode: .continuous, roundMin: 5, restMin: 1, rounds: 4, bells: .off)
        case .sauna, .iceBath:
            return TimerConfig(mode: .continuous, roundMin: 1, restMin: 0, rounds: 1, bells: .off)
        }
    }

    func normalized(for activity: Activity) -> TimerConfig {
        guard !activity.supportsRounds else { return self }
        var value = self
        value.mode = .continuous
        value.bells = .off
        return value
    }
}
