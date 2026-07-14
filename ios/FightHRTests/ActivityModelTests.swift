import Foundation

@main
enum ActivityModelTests {
    static func main() throws {
        try activityCatalogIncludesTherapies()
        try therapyTimersAreAlwaysContinuous()
        try activityValuesRoundTripThroughJSON()
        try therapySessionsRoundTripAndExportTheirActivity()
        try demoSignalsMatchActivityIntensity()
        print("ActivityModelTests: all tests passed")
    }

    private static func activityCatalogIncludesTherapies() throws {
        try expect(Activity.allCases.count == 5, "expected five activities")
        try expect(Activity.sauna.label == "Sauna", "missing Sauna label")
        try expect(Activity.iceBath.label == "Ice Bath", "missing Ice Bath label")
        try expect(Activity.iceBath.rawValue == "ice_bath", "Ice Bath storage key changed")
        try expect(!Activity.sauna.usesGPS && !Activity.iceBath.usesGPS,
                   "therapy activities must not start GPS")
    }

    private static func therapyTimersAreAlwaysContinuous() throws {
        for activity in [Activity.sauna, .iceBath] {
            let defaults = TimerConfig.defaults(for: activity)
            try expect(defaults.mode == .continuous, "\(activity.label) must default to continuous")
            try expect(defaults.bells == .off, "\(activity.label) must default to silent")

            let invalid = TimerConfig(mode: .rounds, roundMin: 3, restMin: 1, rounds: 5, bells: .on)
            let normalized = invalid.normalized(for: activity)
            try expect(normalized.mode == .continuous, "\(activity.label) accepted round mode")
            try expect(normalized.bells == .off, "\(activity.label) accepted bells")
        }

        let combat = TimerConfig(mode: .rounds, roundMin: 3, restMin: 1, rounds: 5, bells: .on)
        try expect(combat.normalized(for: .mt) == combat, "Muay Thai round settings changed")
    }

    private static func activityValuesRoundTripThroughJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for activity in Activity.allCases {
            let decoded = try decoder.decode(Activity.self, from: encoder.encode(activity))
            try expect(decoded == activity, "\(activity.label) failed Codable round trip")
        }
    }

    private static func therapySessionsRoundTripAndExportTheirActivity() throws {
        let session = Session(
            ts: Date(timeIntervalSince1970: 0),
            durSec: 180,
            kcal: 12,
            avg: 78,
            max: 91,
            zoneSec: [120, 60, 0, 0, 0],
            mode: .continuous,
            activity: .iceBath,
            rounds: [],
            samples: [[0, 82], [5, 78]],
            distanceMeters: nil,
            route: nil
        )

        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        try expect(decoded.activity == .iceBath, "Ice Bath session lost its activity when persisted")
        try expect(decoded.samples == session.samples, "Ice Bath HR samples changed when persisted")

        let fields = Store.csv(sessions: [session]).split(separator: "\n").last?.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        try expect(fields?.count == 15, "therapy CSV row has the wrong number of columns")
        try expect(fields?[2] == "ice_bath", "therapy CSV row lost its activity")
        try expect(fields?[12] == "continuous", "therapy CSV row lost its timer mode")
    }

    private static func demoSignalsMatchActivityIntensity() throws {
        let sauna = Activity.sauna.demoHeartRate(at: 0)
        let iceBath = Activity.iceBath.demoHeartRate(at: 0)
        try expect(sauna > iceBath, "Sauna demo HR should start above Ice Bath demo HR")
        try expect((55...195).contains(sauna) && (55...195).contains(iceBath),
                   "therapy demo HR fell outside monitor limits")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
