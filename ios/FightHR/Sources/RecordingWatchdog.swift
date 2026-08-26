import Foundation

/// A small, privacy-safe checkpoint that survives process termination. If iOS
/// kills the app while the camera is recording, the next launch can report the
/// last known recorder state instead of losing the only useful evidence.
struct RecordingDiagnosticSnapshot: Codable, Equatable {
    let id: UUID
    let startedAt: Date
    var updatedAt: Date
    let orientation: String
    var phase: String?
    var elapsedSeconds: Int
    var frameWidth: Int
    var frameHeight: Int
    var encoderFailures: Int
    var captureDrops: Int
    var backpressureDrops: Int
    var thermalState: Int
    var memoryMB: Int
    var availableDiskMB: Int
}

enum RecordingWatchdog {
    private static let key = "fighthr.recording-diagnostic-snapshot"

    static func begin(orientation: String, now: Date = Date(),
                      defaults: UserDefaults = .standard) {
        let snapshot = RecordingDiagnosticSnapshot(
            id: UUID(), startedAt: now, updatedAt: now, orientation: orientation,
            phase: "recording",
            elapsedSeconds: 0, frameWidth: 0, frameHeight: 0,
            encoderFailures: 0, captureDrops: 0, backpressureDrops: 0,
            thermalState: ProcessInfo.ThermalState.nominal.rawValue,
            memoryMB: 0, availableDiskMB: 0
        )
        save(snapshot, defaults: defaults)
    }

    static func heartbeat(elapsed: TimeInterval, width: Int, height: Int,
                          encoderFailures: Int, captureDrops: Int,
                          backpressureDrops: Int, thermalState: Int,
                          memoryMB: Int, availableDiskMB: Int,
                          now: Date = Date(), defaults: UserDefaults = .standard) {
        guard var snapshot = load(defaults: defaults) else { return }
        snapshot.updatedAt = now
        snapshot.elapsedSeconds = max(0, Int(elapsed))
        snapshot.frameWidth = width
        snapshot.frameHeight = height
        snapshot.encoderFailures = encoderFailures
        snapshot.captureDrops = captureDrops
        snapshot.backpressureDrops = backpressureDrops
        snapshot.thermalState = thermalState
        snapshot.memoryMB = memoryMB
        snapshot.availableDiskMB = availableDiskMB
        save(snapshot, defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    static func markFinalizing(now: Date = Date(), defaults: UserDefaults = .standard) {
        guard var snapshot = load(defaults: defaults) else { return }
        snapshot.updatedAt = now
        snapshot.phase = "finalizing"
        save(snapshot, defaults: defaults)
    }

    /// Returns and removes the previous run's checkpoint atomically enough for
    /// the single app process. A successfully handled report is never repeated.
    static func consume(defaults: UserDefaults = .standard) -> RecordingDiagnosticSnapshot? {
        guard let snapshot = load(defaults: defaults) else { return nil }
        clear(defaults: defaults)
        return snapshot
    }

    private static func load(defaults: UserDefaults) -> RecordingDiagnosticSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecordingDiagnosticSnapshot.self, from: data)
    }

    private static func save(_ snapshot: RecordingDiagnosticSnapshot, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Keeps routine short clips out of Sentry while making the long-running
/// device test remotely verifiable. Unexpected stops already emit their own
/// failure event, so a second success event would only add noise.
enum RecordingTelemetryPolicy {
    static let longRecordingThreshold: TimeInterval = 120

    static func shouldCaptureSuccessfulSave(ok: Bool, unexpected: Bool,
                                            elapsed: TimeInterval) -> Bool {
        ok && !unexpected && elapsed >= longRecordingThreshold
    }
}
