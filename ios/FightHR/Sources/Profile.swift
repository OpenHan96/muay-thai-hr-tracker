import Foundation

enum Sex: String, Codable, CaseIterable { case m, f }
enum ZoneMethod: String, Codable, CaseIterable { case maxhr, karvonen }

/// When to speak the current training zone aloud.
enum VoiceMode: String, Codable, CaseIterable {
    case off, onChange, periodic, both
    var label: String {
        switch self {
        case .off: return "Off"
        case .onChange: return "On zone change"
        case .periodic: return "Every interval"
        case .both: return "Change + interval"
        }
    }
    var announcesOnChange: Bool { self == .onChange || self == .both }
    var announcesPeriodic: Bool { self == .periodic || self == .both }
}

/// User profile for zones & calories. Mirrors `defaultProfile` in index.html.
struct Profile: Codable, Equatable {
    var age: Int = 30
    var weightKg: Double = 75
    var sex: Sex = .m
    var maxHrOverride: Int = 0      // 0 = auto (208 − 0.7·age)
    var restHr: Int = 55
    var zoneMethod: ZoneMethod = .karvonen
    var voiceMode: VoiceMode = .off
    var voiceIntervalSec: Int = 30

    init() {}

    // Tolerate older stored profiles that lack the newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        age = try c.decodeIfPresent(Int.self, forKey: .age) ?? 30
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg) ?? 75
        sex = try c.decodeIfPresent(Sex.self, forKey: .sex) ?? .m
        maxHrOverride = try c.decodeIfPresent(Int.self, forKey: .maxHrOverride) ?? 0
        restHr = try c.decodeIfPresent(Int.self, forKey: .restHr) ?? 55
        zoneMethod = try c.decodeIfPresent(ZoneMethod.self, forKey: .zoneMethod) ?? .karvonen
        voiceMode = try c.decodeIfPresent(VoiceMode.self, forKey: .voiceMode) ?? .off
        voiceIntervalSec = try c.decodeIfPresent(Int.self, forKey: .voiceIntervalSec) ?? 30
    }
}
