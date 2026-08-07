import Foundation

/// Covers the pure logic behind the long-session crash fixes: chart
/// downsampling (unbounded chart marks were killing long sessions), zone/
/// calorie math, and the labels used by the recovery notice.
enum SessionLogicTests {
    static func runAll() throws {
        try downsampleStaysBoundedForLongSessions()
        try downsampleHandlesEdgeCases()
        try downsampleAveragesAndKeepsTimeOrder()
        try zoneBoundariesAreInclusiveAtTheLowerEdge()
        try karvonenZonesRespectRestingHeartRate()
        try maxHrOverrideWins()
        try caloriesNeverGoNegative()
        try durationLabelsFormatCorrectly()
        try captureRotationTableIsCorrect()
        try oppositeOrientationsAreHalfATurnApart()
        print("SessionLogicTests: all tests passed")
    }

    // MARK: chart downsampling

    /// A 3-hour session is ~10,800 samples; the chart must stay at the cap.
    private static func downsampleStaysBoundedForLongSessions() throws {
        for seconds in [600, 3_600, 10_800, 28_800] {
            let raw = (0..<seconds).map { (t: $0, hr: 120 + ($0 % 40)) }
            let out = HRPoint.downsample(raw, cap: 180)
            try expect(out.count <= 180,
                       "\(seconds)s session produced \(out.count) chart points, over the 180 cap")
            try expect(Set(out.map(\.id)).count == out.count,
                       "downsample produced duplicate ids at \(seconds)s")
        }
    }

    private static func downsampleHandlesEdgeCases() throws {
        try expect(HRPoint.downsample([], cap: 180).isEmpty, "empty input should give empty output")
        try expect(HRPoint.downsample([(t: 0, hr: 90)], cap: 0).isEmpty, "cap 0 should give no points")
        try expect(HRPoint.downsample([(t: 0, hr: 90)], cap: -5).isEmpty, "negative cap should be safe")

        let small = [(t: 0, hr: 100), (t: 1, hr: 110)]
        let out = HRPoint.downsample(small, cap: 180)
        try expect(out.count == 2, "input under the cap should pass through untouched")
        try expect(out[0].hr == 100 && out[1].hr == 110, "small input values changed")

        // exactly at the cap
        let exact = (0..<180).map { (t: $0, hr: 100) }
        try expect(HRPoint.downsample(exact, cap: 180).count == 180, "cap-sized input should pass through")
    }

    private static func downsampleAveragesAndKeepsTimeOrder() throws {
        let raw = (0..<1_000).map { (t: $0, hr: $0 < 500 ? 100 : 180) }
        let out = HRPoint.downsample(raw, cap: 10)
        try expect(out.count == 10, "expected exactly 10 buckets, got \(out.count)")
        try expect(out.first?.hr == 100, "first bucket should average the low half")
        try expect(out.last?.hr == 180, "last bucket should average the high half")
        let times = out.map(\.t)
        try expect(times == times.sorted(), "chart points must stay in time order")
        try expect(out.allSatisfy { (100...180).contains($0.hr) },
                   "averaged HR fell outside the source range")
    }

    // MARK: zones & calories

    private static func zoneBoundariesAreInclusiveAtTheLowerEdge() throws {
        var p = Profile()
        p.age = 35
        p.restHr = 0
        p.zoneMethod = .maxhr
        p.maxHrOverride = 200                 // bounds land on 100/120/140/160/180
        try expect(Zones.zoneOf(99, p) == -1, "99bpm should be below zone 1")
        try expect(Zones.zoneOf(100, p) == 0, "the zone 1 lower bound should be in zone 1")
        try expect(Zones.zoneOf(139, p) == 1, "139bpm should still be zone 2")
        try expect(Zones.zoneOf(140, p) == 2, "the zone 3 lower bound should be in zone 3")
        try expect(Zones.zoneOf(180, p) == 4, "the zone 5 lower bound should be in zone 5")
        try expect(Zones.zoneOf(250, p) == 4, "above max should clamp into zone 5")
    }

    private static func karvonenZonesRespectRestingHeartRate() throws {
        var p = Profile()
        p.maxHrOverride = 200
        p.restHr = 60
        p.zoneMethod = .karvonen
        let bounds = Zones.bounds(p)
        try expect(bounds.count == 5, "expected five zone bounds")
        try expect(bounds == bounds.sorted(), "zone bounds must increase")
        // Karvonen: rest + pct * (max - rest) -> 60 + 0.5*140 = 130
        try expect(bounds[0] == 130, "Karvonen zone 1 bound should be 130, got \(bounds[0])")
        try expect(bounds[4] == 186, "Karvonen zone 5 bound should be 186, got \(bounds[4])")
    }

    private static func maxHrOverrideWins() throws {
        var p = Profile()
        p.age = 30
        p.maxHrOverride = 0
        try expect(Zones.maxHr(p) == 187, "Tanaka max HR for age 30 should be 187, got \(Zones.maxHr(p))")
        p.maxHrOverride = 195
        try expect(Zones.maxHr(p) == 195, "explicit max HR override was ignored")
    }

    private static func caloriesNeverGoNegative() throws {
        var p = Profile()
        p.age = 30
        p.weightKg = 75
        for hr in [0, 30, 40, 60, 100, 150, 200] {
            try expect(Zones.kcalPerMin(hr, p) >= 0, "kcal/min went negative at \(hr)bpm")
        }
        try expect(Zones.kcalPerMin(160, p) > Zones.kcalPerMin(120, p),
                   "higher HR should burn more per minute")
    }

    // MARK: misc

    private static func durationLabelsFormatCorrectly() throws {
        try expect(Store.durationLabel(0) == "0:00", "zero duration label wrong")
        try expect(Store.durationLabel(59) == "0:59", "sub-minute label wrong")
        try expect(Store.durationLabel(90) == "1:30", "minute label wrong")
        try expect(Store.durationLabel(3_600) == "1:00:00", "hour label wrong")
        try expect(Store.durationLabel(3_725) == "1:02:05", "hour+ label wrong")
        try expect(Store.durationLabel(-10) == "0:00", "negative duration should clamp")
    }

    // MARK: capture orientation

    /// Pins the rotation table. Hard-locking this to portrait is what recorded
    /// upside-down video with a flipped HR badge when the phone was propped
    /// or clipped the other way up.
    private static func captureRotationTableIsCorrect() throws {
        try expect(CaptureOrientation.portrait.rotationAngle == 90,
                   "upright portrait needs a quarter turn off the landscape-native sensor")
        try expect(CaptureOrientation.portraitUpsideDown.rotationAngle == 270,
                   "upside-down portrait must be 270, not 90 — this is the flipped-video bug")
        try expect(CaptureOrientation.landscapeLeft.rotationAngle == 0,
                   "landscape left is the sensor's native orientation")
        try expect(CaptureOrientation.landscapeRight.rotationAngle == 180,
                   "landscape right must be a half turn from landscape left")

        // every orientation distinct, and all within one full turn
        let angles = CaptureOrientation.allCases.map(\.rotationAngle)
        try expect(Set(angles).count == 4, "two orientations share a rotation angle")
        try expect(angles.allSatisfy { (0..<360).contains($0) }, "rotation angle outside 0..<360")
    }

    private static func oppositeOrientationsAreHalfATurnApart() throws {
        for o in CaptureOrientation.allCases {
            let delta = abs(o.rotationAngle - o.opposite.rotationAngle)
            try expect(delta == 180, "\(o) and its opposite are \(delta)° apart, expected 180°")
            try expect(o.opposite.opposite == o, "\(o) opposite is not symmetric")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
