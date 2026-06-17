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
}
