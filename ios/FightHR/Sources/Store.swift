import Foundation
import Combine

/// Persists profile, per-activity timers, active activity, and session history.
/// Profile/timers/active activity live in UserDefaults; sessions in a JSON file in Documents.
final class Store: ObservableObject {
    @Published var profile: Profile { didSet { persistProfile() } }
    @Published var timers: [Activity: TimerConfig] { didSet { persistTimers() } }
    @Published var activity: Activity { didSet { defaults.set(activity.rawValue, forKey: kActivity) } }
    @Published private(set) var sessions: [Session] = []

    private let defaults = UserDefaults.standard
    private let kProfile = "fighthr.profile"
    private let kTimers = "fighthr.timers"
    private let kActivity = "fighthr.activity"

    /// Set when the previous run died mid-session and its autosave was recovered.
    @Published var recoveredNotice: String?

    private static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var sessionsURL: URL { Self.documentsDir.appendingPathComponent("sessions.json") }
    /// Snapshot of the live session, rewritten every few seconds so a crash or
    /// an iOS memory kill can't lose the whole workout.
    private var inProgressURL: URL { Self.documentsDir.appendingPathComponent("session-inprogress.json") }

    init() {
        profile = Self.decode(defaults.data(forKey: kProfile)) ?? Profile()
        if let map: [String: TimerConfig] = Self.decode(defaults.data(forKey: kTimers)) {
            var t: [Activity: TimerConfig] = [:]
            for a in Activity.allCases {
                t[a] = (map[a.rawValue] ?? .defaults(for: a)).normalized(for: a)
            }
            timers = t
        } else {
            timers = Dictionary(uniqueKeysWithValues: Activity.allCases.map { ($0, .defaults(for: $0)) })
        }
        activity = Activity(rawValue: defaults.string(forKey: kActivity) ?? "mt") ?? .mt
        sessions = (try? JSONDecoder().decode([Session].self, from: Data(contentsOf: sessionsURL))) ?? []
        recoverInProgressSession()
    }

    /// If an autosaved session is on disk at launch, the app never reached a
    /// clean stop last time. Keep the workout instead of discarding it.
    private func recoverInProgressSession() {
        guard let data = try? Data(contentsOf: inProgressURL) else { return }
        defer { clearInProgress() }
        guard let s = try? JSONDecoder().decode(Session.self, from: data), s.durSec >= 30 else { return }
        guard !sessions.contains(where: { $0.id == s.id }) else { return }
        sessions.append(s)
        persistSessions()
        recoveredNotice = "Recovered \(Self.durationLabel(s.durSec)) \(s.activity.label) session that ended unexpectedly."
    }

    /// Local m:ss / h:mm:ss formatter — Store stays free of UI imports so the
    /// model tests can compile it on its own.
    static func durationLabel(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    func saveInProgress(_ s: Session) {
        try? JSONEncoder().encode(s).write(to: inProgressURL, options: .atomic)
    }

    func clearInProgress() { try? FileManager.default.removeItem(at: inProgressURL) }

    var timerCfg: TimerConfig {
        get { (timers[activity] ?? .defaults(for: activity)).normalized(for: activity) }
        set { timers[activity] = newValue.normalized(for: activity) }
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
    /// Atomic so a crash mid-write can't truncate the whole history file.
    private func persistSessions() {
        try? JSONEncoder().encode(sessions).write(to: sessionsURL, options: .atomic)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: CSV export — same columns as exportCsv() in index.html
    func csv() -> String { Self.csv(sessions: sessions) }

    static func csv(sessions: [Session]) -> String {
        var out = "date,time,activity,duration_sec,kcal,avg_hr,max_hr,z1_sec,z2_sec,z3_sec,z4_sec,z5_sec,mode,rounds,distance_m\n"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for s in sessions {
            let zones = s.zoneSec.map(String.init).joined(separator: ",")
            let dist = s.distanceMeters.map { String(Int($0.rounded())) } ?? ""
            out += [df.string(from: s.ts), tf.string(from: s.ts), s.activity.rawValue,
                    "\(s.durSec)", "\(s.kcal)", "\(s.avg)", "\(s.max)", zones,
                    s.mode.rawValue, "\(s.rounds.count)", dist].joined(separator: ",") + "\n"
        }
        return out
    }
}
