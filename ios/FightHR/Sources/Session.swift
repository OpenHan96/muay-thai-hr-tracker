import Foundation

/// One completed round's stats. Mirrors the `rounds` entries saved in index.html.
struct RoundStat: Codable, Identifiable, Equatable {
    var id = UUID()
    var n: Int
    var avg: Int
    var max: Int
    var kcal: Double
    var recovery: Int?      // bpm drop 60s into rest, nil if not captured
}

/// How the phone is physically held while filming, kept free of UIKit so the
/// rotation table can be unit tested. Getting this table wrong is what recorded
/// upside-down video with a flipped HR badge.
enum CaptureOrientation: String, CaseIterable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    /// Clockwise rotation the capture pipeline must apply, in degrees. The
    /// camera sensor is landscape-native, so holding the phone upright needs
    /// a quarter turn.
    var rotationAngle: Double {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        }
    }

    /// Upright and upside down differ by a half turn; so do the two landscapes.
    var opposite: CaptureOrientation {
        switch self {
        case .portrait: return .portraitUpsideDown
        case .portraitUpsideDown: return .portrait
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        }
    }
}

/// One point on the live HR chart. The series is downsampled, so this is not
/// necessarily a raw 1Hz reading.
struct HRPoint: Identifiable, Equatable {
    let id: Int
    let t: Int
    let hr: Int

    /// Average raw samples into at most `cap` buckets, so charting cost stays
    /// flat however long a session runs. Drawing one mark per raw second is
    /// what made long sessions hang and get killed by iOS.
    static func downsample(_ s: [(t: Int, hr: Int)], cap: Int) -> [HRPoint] {
        guard cap > 0, !s.isEmpty else { return [] }
        if s.count <= cap {
            return s.enumerated().map { HRPoint(id: $0.offset, t: $0.element.t, hr: $0.element.hr) }
        }
        var out: [HRPoint] = []
        out.reserveCapacity(cap)
        let step = Double(s.count) / Double(cap)
        for i in 0..<cap {
            let lo = min(s.count - 1, Int(Double(i) * step))
            let hi = min(s.count, max(lo + 1, Int(Double(i + 1) * step)))
            let bucket = s[lo..<hi]
            let avg = bucket.reduce(0) { $0 + $1.hr } / bucket.count
            out.append(HRPoint(id: i, t: bucket[bucket.startIndex].t, hr: avg))
        }
        return out
    }
}

/// A finished training session. Mirrors the saved `sess` object.
struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var ts: Date
    var durSec: Int
    var kcal: Int
    var avg: Int
    var max: Int
    var zoneSec: [Int]              // 5 entries
    var mode: TimerMode
    var activity: Activity
    var rounds: [RoundStat]
    var samples: [[Int]]            // [secOffset, hr], ~1 per 5s
    var distanceMeters: Double?     // running only
    var route: [[Double]]?          // running only: [lat, lon] pairs
}
