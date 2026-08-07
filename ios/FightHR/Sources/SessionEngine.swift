import Foundation
import Combine
import SwiftUI

/// Live session state + 1Hz tick loop. Ports tick()/tickRounds()/stopSession() from index.html.
final class SessionEngine: ObservableObject {
    enum Phase { case idle, session, work, rest }

    // live, published for the UI
    @Published var running = false
    @Published var paused = false
    @Published var phase: Phase = .idle
    @Published var phaseLeft: Double = 0
    @Published var round = 1
    @Published var elapsed: Double = 0
    @Published var calories: Double = 0
    @Published var hrSum: Double = 0
    @Published var hrCount: Double = 0
    @Published var hrMax: Int = 0
    @Published var zoneSec: [Double] = Array(repeating: 0, count: 5)
    /// Downsampled series for the live chart — never more than `chartCap`
    /// points. Publishing every raw sample rebuilt a chart with thousands of
    /// marks once a second, which is what hung/killed long sessions.
    @Published private(set) var chartSamples: [HRPoint] = []
    @Published var liveRounds: [RoundStat] = []
    @Published var justFinished: Session?
    /// User-facing explanation when a session ends without being saved.
    @Published var notice: String?

    /// Full-fidelity 1Hz samples. Deliberately NOT @Published.
    private var samples: [(t: Int, hr: Int)] = []
    private static let chartCap = 180
    private static let sampleCap = 8 * 3600      // 8h hard ceiling
    private var lastChartRefresh: Double = -99
    private var lastAutosave: Double = -99

    // wall-clock timing, so a backgrounded/locked phone doesn't lose time
    private var startTs = Date()
    private var pausedTotal: Double = 0
    private var pauseBegan: Date?
    private var phaseEndsAt = Date()
    private var lastTick = Date()
    private var warned = false
    private var timer: AnyCancellable?
    private var lastAnnouncedZone: Int? = nil
    private var lastPeriodicAnnounce: Double = 0

    // mutable working round accumulator
    private struct Acc { var n: Int; var sum = 0.0; var count = 0.0; var max = 0; var kcal = 0.0
        var zoneSec = [Double](repeating: 0, count: 5); var endHr = 0; var recovery: Int? = nil }
    private var cur: Acc?
    /// HR at the end of the round now resting, plus its index in `liveRounds`,
    /// so the 60s recovery drop can be filled in once rest has run that long.
    private var restCarry: (endHr: Int, index: Int)?

    private unowned let store: Store
    private unowned let hr: HeartRateMonitor
    private unowned let loc: LocationTracker
    init(store: Store, hr: HeartRateMonitor, loc: LocationTracker) {
        self.store = store; self.hr = hr; self.loc = loc
    }

    private var cfg: TimerConfig { store.timerCfg }

    // MARK: lifecycle
    func start() {
        guard !running else { return }
        running = true; paused = false
        startTs = Date(); lastTick = Date()
        pausedTotal = 0; pauseBegan = nil
        elapsed = 0; calories = 0; hrSum = 0; hrCount = 0; hrMax = 0
        zoneSec = Array(repeating: 0, count: 5)
        samples = []; chartSamples = []; liveRounds = []; warned = false
        lastChartRefresh = -99; lastAutosave = -99
        lastAnnouncedZone = nil; lastPeriodicAnnounce = 0
        notice = nil; justFinished = nil
        cur = nil; restCarry = nil
        store.clearInProgress()
        if cfg.mode == .rounds {
            phase = .work; round = 1
            phaseEndsAt = Date().addingTimeInterval(cfg.roundMin * 60)
            phaseLeft = cfg.roundMin * 60
            cur = Acc(n: 1); Chime.play(2, enabled: cfg.bells == .on)
        } else {
            phase = .session; phaseLeft = 0; cur = nil
        }
        if store.activity.usesGPS { loc.start() }
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func togglePause() {
        guard running else { return }
        if paused {
            if let began = pauseBegan {
                let d = Date().timeIntervalSince(began)
                pausedTotal += d
                phaseEndsAt = phaseEndsAt.addingTimeInterval(d)   // don't burn round time while paused
                pauseBegan = nil
            }
            paused = false
            lastTick = Date()
        } else {
            paused = true
            pauseBegan = Date()
            store.saveInProgress(buildSession(includeCurrentRound: true))
        }
    }

    func stop() {
        guard running else { return }
        running = false
        paused = false
        pauseBegan = nil
        timer?.cancel(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        elapsed = wallElapsed()
        let wasGPS = store.activity.usesGPS
        if wasGPS { loc.stop() }
        // include in-progress round if it has data
        if let c = cur, (phase == .work || phase == .session), c.count > 5 {
            liveRounds.append(roundStat(c))
        }
        cur = nil
        refreshChart(force: true)
        // discard sessions that are too short — but say so, don't vanish
        guard elapsed >= 30, hrCount >= 10 else {
            store.clearInProgress()
            notice = elapsed < 30
                ? "Session under 30s — not saved."
                : "Not saved: no heart-rate data was received. Check the strap is connected."
            phase = .idle
            return
        }
        let s = buildSession(includeCurrentRound: false)
        store.add(s)
        store.clearInProgress()
        justFinished = s
        phase = .idle
    }

    /// Snapshot of the session as it stands right now.
    private func buildSession(includeCurrentRound: Bool) -> Session {
        var rounds = liveRounds
        if includeCurrentRound, let c = cur, c.count > 5 { rounds.append(roundStat(c)) }
        let wasGPS = store.activity.usesGPS
        let path = loc.route
        return Session(
            ts: startTs, durSec: Int(elapsed.rounded()), kcal: Int(calories.rounded()),
            avg: hrCount > 0 ? Int((hrSum / hrCount).rounded()) : 0, max: hrMax,
            zoneSec: zoneSec.map { Int($0.rounded()) },
            mode: cfg.mode, activity: store.activity, rounds: rounds,
            samples: compress(samples),
            distanceMeters: wasGPS ? loc.distanceMeters : nil,
            route: wasGPS && !path.isEmpty ? path.map { [$0.latitude, $0.longitude] } : nil)
    }

    /// Elapsed from the clock, not accumulated ticks, so time is right even if
    /// the phone locked or the app was backgrounded.
    private func wallElapsed() -> Double {
        var e = Date().timeIntervalSince(startTs) - pausedTotal
        if let began = pauseBegan { e -= Date().timeIntervalSince(began) }
        return max(0, e)
    }

    // MARK: tick
    private func tick() {
        guard running, !paused else { return }
        let now = Date()
        // dt drives stat accumulation only, and is capped so a long background
        // gap can't attribute minutes of zone time to one stale reading.
        let dt = min(5, max(0, now.timeIntervalSince(lastTick)))
        lastTick = now
        elapsed = wallElapsed()

        let fresh = hr.bpm > 0 && hr.isFresh
        if fresh {
            let bpm = hr.bpm
            if samples.count < Self.sampleCap {
                samples.append((Int(elapsed.rounded()), bpm))
            }
            hrSum += Double(bpm) * dt; hrCount += dt
            if bpm > hrMax { hrMax = bpm }
            let kc = Zones.kcalPerMin(bpm, store.profile) / 60 * dt
            calories += kc
            let z = Zones.zoneOf(bpm, store.profile)
            if z >= 0, z < zoneSec.count { zoneSec[z] += dt }
            if var c = cur, phase == .work {
                c.sum += Double(bpm) * dt; c.count += dt; c.kcal += kc
                if bpm > c.max { c.max = bpm }
                if z >= 0, z < c.zoneSec.count { c.zoneSec[z] += dt }
                c.endHr = bpm
                cur = c
            }
            // 60s-into-rest recovery, written back onto the round that just
            // ended. It used to be stored on the working accumulator, which
            // had already been appended and was then thrown away — so the
            // "Rec" column never showed anything.
            if phase == .rest, let carry = restCarry,
               (cfg.restMin * 60 - phaseLeft) >= 60,
               liveRounds.indices.contains(carry.index) {
                liveRounds[carry.index].recovery = carry.endHr - bpm
                restCarry = nil
            }
            announceZoneIfNeeded(z)
        }
        if cfg.mode == .rounds { tickRounds() }
        guard running else { return }   // tickRounds may have ended the session
        refreshChart()
        autosaveIfNeeded()
    }

    /// Spoken zone cues per the user's VoiceMode setting.
    private func announceZoneIfNeeded(_ z: Int) {
        let mode = store.profile.voiceMode
        guard mode != .off else { return }
        var spoke = false
        if mode.announcesOnChange, z != lastAnnouncedZone {
            Announcer.announceZone(z)
            spoke = true
        }
        if !spoke, mode.announcesPeriodic {
            let interval = Double(max(10, store.profile.voiceIntervalSec))
            if elapsed - lastPeriodicAnnounce >= interval {
                Announcer.announceZone(z)
                lastPeriodicAnnounce = elapsed
            }
        }
        lastAnnouncedZone = z
    }

    private func tickRounds() {
        if cfg.bells == .on, phase == .work, !warned {
            let left = phaseEndsAt.timeIntervalSinceNow
            if left <= 10, left > 0 { warned = true; Chime.clack() }
        }
        // Loop in case several phases elapsed while backgrounded. Bells only
        // ring for a transition happening now, not for ones being caught up.
        var guardCount = 0
        while running, phaseEndsAt.timeIntervalSinceNow <= 0, guardCount < 200 {
            guardCount += 1
            let live = phaseEndsAt.timeIntervalSinceNow > -3
            warned = false
            if phase == .work {
                if let c = cur {
                    liveRounds.append(roundStat(c))
                    restCarry = (endHr: c.endHr, index: liveRounds.count - 1)
                    cur = nil
                }
                if round >= cfg.rounds {
                    Chime.play(3, enabled: cfg.bells == .on && live)
                    stop()
                    return
                }
                if cfg.restMin > 0 {
                    phase = .rest
                    phaseEndsAt = phaseEndsAt.addingTimeInterval(cfg.restMin * 60)
                    Chime.play(1, enabled: cfg.bells == .on && live)
                } else {
                    nextRound(chime: live)
                }
            } else {
                nextRound(chime: live)
            }
        }
        phaseLeft = max(0, phaseEndsAt.timeIntervalSinceNow)
    }

    private func nextRound(chime: Bool) {
        restCarry = nil          // rest ended before the 60s mark
        round += 1; phase = .work
        phaseEndsAt = phaseEndsAt.addingTimeInterval(cfg.roundMin * 60)
        cur = Acc(n: round); Chime.play(2, enabled: cfg.bells == .on && chime)
    }

    private func roundStat(_ c: Acc) -> RoundStat {
        RoundStat(n: c.n, avg: c.count > 0 ? Int((c.sum / c.count).rounded()) : 0,
                  max: c.max, kcal: (c.kcal * 10).rounded() / 10, recovery: c.recovery)
    }

    // MARK: chart + autosave
    private func refreshChart(force: Bool = false) {
        guard force || elapsed - lastChartRefresh >= 5 else { return }
        lastChartRefresh = elapsed
        chartSamples = HRPoint.downsample(samples, cap: Self.chartCap)
    }

    private func autosaveIfNeeded() {
        guard elapsed - lastAutosave >= 10 else { return }
        lastAutosave = elapsed
        guard elapsed >= 30, hrCount >= 10 else { return }
        store.saveInProgress(buildSession(includeCurrentRound: true))
    }

    /// Keep ~1 sample / 5s for storage (mirrors compressSamples).
    private func compress(_ s: [(t: Int, hr: Int)]) -> [[Int]] {
        var out: [[Int]] = []; var last = -5
        for p in s where p.t - last >= 5 { out.append([p.t, p.hr]); last = p.t }
        return out
    }

    /// Demo target HR for the monitor's simulator (rest vs work intensity).
    func demoTarget() -> Double {
        guard running, !paused else { return 75 }
        return phase == .rest ? 120 : store.activity.demoHeartRate(at: elapsed)
    }
}
