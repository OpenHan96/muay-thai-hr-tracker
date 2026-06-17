import Foundation

/// Pure zone & calorie math, ported from index.html (maxHr/zoneBounds/zoneOf/kcalPerMin).
enum Zones {
    /// Max HR: explicit override, else 208 − 0.7·age (Tanaka).
    static func maxHr(_ p: Profile) -> Int {
        p.maxHrOverride > 0 ? p.maxHrOverride : Int((208 - 0.7 * Double(p.age)).rounded())
    }

    /// Lower bounds (bpm) of zones 1...5.
    static func bounds(_ p: Profile) -> [Int] {
        let mx = Double(maxHr(p))
        let pcts = [0.5, 0.6, 0.7, 0.8, 0.9]
        if p.zoneMethod == .karvonen && p.restHr > 0 {
            let hrr = mx - Double(p.restHr)
            return pcts.map { Int((Double(p.restHr) + $0 * hrr).rounded()) }
        }
        return pcts.map { Int(($0 * mx).rounded()) }
    }

    /// Zone index 0...4 for a given HR, or -1 if below zone 1.
    static func zoneOf(_ hr: Int, _ p: Profile) -> Int {
        let b = bounds(p)
        if hr < b[0] { return -1 }
        var z = 0
        for i in 1..<5 where hr >= b[i] { z = i }
        return z
    }

    /// Keytel et al. 2005 — kcal per minute from HR. Clamped at 0.
    static func kcalPerMin(_ hr: Int, _ p: Profile) -> Double {
        let h = Double(hr), w = p.weightKg, a = Double(p.age)
        let k: Double
        switch p.sex {
        case .f: k = (-20.4022 + 0.4472 * h - 0.1263 * w + 0.074 * a) / 4.184
        case .m: k = (-55.0969 + 0.6309 * h + 0.1988 * w + 0.2017 * a) / 4.184
        }
        return max(0, k)
    }
}
