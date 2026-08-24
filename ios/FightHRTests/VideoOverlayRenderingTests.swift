import CoreImage
import CoreVideo
import Foundation
import UIKit

enum VideoOverlayRenderingTests {
    static func run() throws {
        try badgeIsUprightInWriterPixelBuffer()
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
