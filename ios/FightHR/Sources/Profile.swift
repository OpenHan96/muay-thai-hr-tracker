import Foundation

enum Sex: String, Codable, CaseIterable { case m, f }
enum ZoneMethod: String, Codable, CaseIterable { case maxhr, karvonen }

/// User profile for zones & calories. Mirrors `defaultProfile` in index.html.
struct Profile: Codable, Equatable {
    var age: Int = 30
    var weightKg: Double = 75
    var sex: Sex = .m
    var maxHrOverride: Int = 0      // 0 = auto (208 − 0.7·age)
    var restHr: Int = 55
    var zoneMethod: ZoneMethod = .karvonen
}
