import CoreImage
import CoreVideo
import Foundation
import UIKit

enum VideoOverlayRenderingTests {
    static func run() throws {
        try badgeIsUprightInWriterPixelBuffer()
        try recordingWatchdogSurvivesAndConsumesAnUncleanExit()
        try longRecordingSuccessTelemetryPolicyHasCorrectBoundary()
        print("VideoOverlayRenderingTests: all tests passed")
    }

    /// Zone 1 uses a blue pill while the heart is red. In the final BGRA
    /// writer buffer, the red centroid must be above the blue centroid.
    private static func badgeIsUprightInWriterPixelBuffer() throws {
        let image = VideoOverlayRenderer.renderBadge(bpm: 123, zone: 0, scale: 1)
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        try expect(status == kCVReturnSuccess && pixelBuffer != nil, "could not allocate pixel buffer")
        let buffer = pixelBuffer!
        CIContext().render(image, to: buffer,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: CGColorSpaceCreateDeviceRGB())

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var redY = 0.0, redCount = 0.0, blueY = 0.0, blueCount = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * rowBytes + x * 4
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2]), a = Int(p[3])
                guard a > 180 else { continue }
                if r > 180 && r > g * 3 / 2 && r > b * 3 / 2 {
                    redY += Double(y); redCount += 1
                } else if b > 120 && b > r * 6 / 5 && b > g * 6 / 5 {
                    blueY += Double(y); blueCount += 1
                }
            }
        }
        try expect(redCount > 20 && blueCount > 20, "badge colors were not rendered")
        try expect(redY / redCount < blueY / blueCount,
                   "BPM badge is vertically inverted in the writer pixel buffer")
    }

    private static func recordingWatchdogSurvivesAndConsumesAnUncleanExit() throws {
        let suite = "fighthr.recording-watchdog-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw TestFailure(message: "could not create isolated UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let checkpointAt = startedAt.addingTimeInterval(90)
        RecordingWatchdog.begin(orientation: "portrait", now: startedAt, defaults: defaults)
        RecordingWatchdog.heartbeat(
            elapsed: 90.8, width: 1080, height: 1920,
            encoderFailures: 2, captureDrops: 3, backpressureDrops: 4,
            thermalState: 1, memoryMB: 245, availableDiskMB: 9_876,
            now: checkpointAt, defaults: defaults
        )
        let finalizingAt = checkpointAt.addingTimeInterval(1)
        RecordingWatchdog.markFinalizing(now: finalizingAt, defaults: defaults)

        let snapshot = RecordingWatchdog.consume(defaults: defaults)
        try expect(snapshot != nil, "unclean recording checkpoint was not recovered")
        try expect(snapshot?.startedAt == startedAt, "recording start time was not preserved")
        try expect(snapshot?.updatedAt == finalizingAt, "finalizing time was not updated")
        try expect(snapshot?.phase == "finalizing", "recording phase was not persisted")
        try expect(snapshot?.elapsedSeconds == 90, "elapsed checkpoint was wrong")
        try expect(snapshot?.frameWidth == 1080 && snapshot?.frameHeight == 1920,
                   "frame dimensions were not preserved")
        try expect(snapshot?.encoderFailures == 2 && snapshot?.captureDrops == 3
                   && snapshot?.backpressureDrops == 4, "frame-pressure counters were wrong")
        try expect(snapshot?.memoryMB == 245 && snapshot?.availableDiskMB == 9_876,
                   "resource checkpoint was wrong")
        try expect(RecordingWatchdog.consume(defaults: defaults) == nil,
                   "consumed checkpoint should not be reported twice")
    }

    private static func longRecordingSuccessTelemetryPolicyHasCorrectBoundary() throws {
        try expect(!RecordingTelemetryPolicy.shouldCaptureSuccessfulSave(
            ok: true, unexpected: false, elapsed: 119.9
        ), "short successful recordings should not create Sentry events")
        try expect(RecordingTelemetryPolicy.shouldCaptureSuccessfulSave(
            ok: true, unexpected: false, elapsed: 120
        ), "a two-minute successful recording should be remotely verifiable")
        try expect(!RecordingTelemetryPolicy.shouldCaptureSuccessfulSave(
            ok: false, unexpected: false, elapsed: 600
        ), "failed saves must not be reported as successes")
        try expect(!RecordingTelemetryPolicy.shouldCaptureSuccessfulSave(
            ok: true, unexpected: true, elapsed: 600
        ), "unexpected stops already have a failure event")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

@main
struct VideoOverlayTestRunner {
    static func main() {
        do {
            try VideoOverlayRenderingTests.run()
        } catch {
            fputs("VideoOverlayRenderingTests FAILED: \(error)\n", stderr)
            exit(1)
        }
    }
}
