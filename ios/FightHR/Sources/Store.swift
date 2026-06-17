import Foundation
import Combine

/// Persists profile, per-sport timers, active sport, and session history.
/// Profile/timers/active sport live in UserDefaults; sessions in a JSON file in Documents.
final class Store: ObservableObject {
    @Published var profile: Profile { didSet { persistProfile() } }
    @Published var timers: [Activity: TimerConfig] { didSet { persistTimers() } }
    @Published var activity: Activity { didSet { defaults.set(activity.rawValue, forKey: kActivity) } }
    @Published private(set) var sessions: [Session] = []

    private let defaults = UserDefaults.standard
    private let kProfile = "fighthr.profile"
    private let kTimers = "fighthr.timers"
    private let kActivity = "fighthr.activity"

    private var sessionsURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sessions.json")
    }

    init() {
        profile = Self.decode(defaults.data(forKey: kProfile)) ?? Profile()
        if let map: [String: TimerConfig] = Self.decode(defaults.data(forKey: kTimers)) {
            var t: [Activity: TimerConfig] = [:]
            for a in Activity.allCases { t[a] = map[a.rawValue] ?? .defaults(for: a) }
            timers = t
        } else {
            timers = Dictionary(uniqueKeysWithValues: Activity.allCases.map { ($0, .defaults(for: $0)) })
        }
        activity = Activity(rawValue: defaults.string(forKey: kActivity) ?? "mt") ?? .mt
        sessions = (try? JSONDecoder().decode([Session].self, from: Data(contentsOf: sessionsURL))) ?? []
    }

    var timerCfg: TimerConfig {
        get { timers[activity] ?? .defaults(for: activity) }
        set { timers[activity] = newValue }
    }

    func add(_ s: Session) {
        sessions.append(s)
        if sessions.count > 300 { sessions.removeFirst(sessions.count - 300) }
        persistSessions()
    }

    func deleteAll() { sessions = []; persistSessions() }

    // MARK: persistence
    private func persistProfile() { defaults.set(try? JSONEncoder().encode(profile), forKey: kProfile) }
    private func persistTimers() {
        let map = Dictionary(uniqueKeysWithValues: timers.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(map), forKey: kTimers)
    }
    private func persistSessions() { try? JSONEncoder().encode(sessions).write(to: sessionsURL) }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: CSV export — same columns as exportCsv() in index.html
    func csv() -> String {
        var out = "date,time,activity,duration_sec,kcal,avg_hr,max_hr,z1_sec,z2_sec,z3_sec,z4_sec,z5_sec,mode,rounds\n"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for s in sessions {
            let zones = s.zoneSec.map(String.init).joined(separator: ",")
            out += [df.string(from: s.ts), tf.string(from: s.ts), s.activity.rawValue,
                    "\(s.durSec)", "\(s.kcal)", "\(s.avg)", "\(s.max)", zones,
                    s.mode.rawValue, "\(s.rounds.count)"].joined(separator: ",") + "\n"
        }
        return out
    }
}
