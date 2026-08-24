import Foundation
import SentrySwift
import UIKit

/// Privacy-minimal diagnostics for failures that only happen on a real phone.
/// The DSN is supplied through the SENTRY_DSN build setting; without it the
/// app works normally and this layer is a no-op.
enum Telemetry {
    private(set) static var isEnabled = false

    static func start() {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String else { return }
        let dsn = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dsn.hasPrefix("https://"), !dsn.contains("$(") else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.enableWatchdogTerminationTracking = true
            options.sendDefaultPii = false
            options.tracesSampleRate = 0.1
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif
        }
        isEnabled = true
        SentrySDK.configureScope { scope in
            scope.setTag(value: "ios-native", key: "app.variant")
            scope.setTag(value: UIDevice.current.systemVersion, key: "device.ios")
        }
        breadcrumb("app.telemetry_started")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sentry-test-event") {
            SentrySDK.capture(message: "FightHR Sentry integration test")
        }
        #endif
    }

    static func recordingStarted(orientation: CaptureOrientation) {
        guard isEnabled else { return }
        SentrySDK.configureScope { scope in
            scope.setTag(value: "true", key: "recording.active")
            scope.setTag(value: orientation.rawValue, key: "recording.orientation")
        }
        breadcrumb("video.recording_started", data: ["orientation": orientation.rawValue])
    }

    static func recordingHeartbeat(elapsed: TimeInterval, width: Int, height: Int,
                                   encoderFailures: Int, captureDrops: Int,
                                   backpressureDrops: Int) {
        breadcrumb("video.recording_heartbeat", data: [
            "elapsed_seconds": Int(elapsed),
            "frame_width": width,
            "frame_height": height,
            "consecutive_encoder_failures": encoderFailures,
            "capture_drops": captureDrops,
            "backpressure_drops": backpressureDrops,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
        ])
    }

    static func recordingSignal(_ message: String, data: [String: Any] = [:]) {
        breadcrumb(message, level: .warning, data: data)
    }

    static func recordingFinished(reason: String, elapsed: TimeInterval,
                                  unexpected: Bool, error: Error? = nil) {
        guard isEnabled else { return }
        let data: [String: Any] = [
            "reason": reason,
            "elapsed_seconds": Int(elapsed),
            "unexpected": unexpected,
        ]
        breadcrumb("video.recording_finished", level: unexpected ? .warning : .info, data: data)
        SentrySDK.configureScope { scope in
            scope.setTag(value: "false", key: "recording.active")
            scope.setTag(value: reason, key: "recording.stop_reason")
        }
        guard unexpected else { return }
        if let error {
            SentrySDK.capture(error: error)
        } else {
            SentrySDK.capture(message: "Video recording ended unexpectedly: \(reason)")
        }
    }

    static func videoSaved(ok: Bool, denied: Bool) {
        breadcrumb("video.photo_save_finished", level: ok ? .info : .error, data: [
            "success": ok,
            "permission_denied": denied,
        ])
        if isEnabled && !ok && !denied {
            SentrySDK.capture(message: "Video failed to save to Photos")
        }
    }

    static func breadcrumb(_ message: String, level: SentryLevel = .info,
                           data: [String: Any] = [:]) {
        guard isEnabled else { return }
        let crumb = Breadcrumb(level: level, category: "fighthr")
        crumb.message = message
        for (key, value) in data { crumb.setData(value: value, key: key) }
        SentrySDK.addBreadcrumb(crumb)
    }
}
