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
    @Published var samples: [(t: Int, hr: Int)] = []
    @Published var liveRounds: [RoundStat] = []
    @Published var justFinished: Session?

    private var startTs = Date()
    private var lastTick = Date()
    private var warned = false
    private var timer: AnyCancellable?

    // mutable working round accumulator
    private struct Acc { var n: Int; var sum = 0.0; var count = 0.0; var max = 0; var kcal = 0.0
        var zoneSec = [Double](repeating: 0, count: 5); var endHr = 0; var recovery: Int? = nil }
    private var cur: Acc?

    private unowned let store: Store
    private unowned let hr: HeartRateMonitor
    init(store: Store, hr: HeartRateMonitor) { self.store = store; self.hr = hr }

    private var cfg: TimerConfig { store.timerCfg }

    // MARK: lifecycle
    func start() {
        running = true; paused = false; startTs = Date(); lastTick = Date()
        elapsed = 0; calories = 0; hrSum = 0; hrCount = 0; hrMax = 0
        zoneSec = Array(repeating: 0, count: 5); samples = []; liveRounds = []; warned = false
        if cfg.mode == .rounds {
            phase = .work; phaseLeft = cfg.roundMin * 60; round = 1
            cur = Acc(n: 1); Bells.play(2, enabled: cfg.bells == .on)
        } else {
            phase = .session; phaseLeft = 0; cur = nil
        }
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func togglePause() { paused.toggle(); if !paused { lastTick = Date() } }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        // include in-progress round if it has data
        if let c = cur, (phase == .work || phase == .session), c.count > 5 {
            liveRounds.append(roundStat(c))
        }
        // discard sessions that are too short
        guard elapsed >= 30, hrCount >= 10 else { phase = .idle; return }
        let s = Session(
            ts: startTs, durSec: Int(elapsed.rounded()), kcal: Int(calories.rounded()),
            avg: Int((hrSum / hrCount).rounded()), max: hrMax,
            zoneSec: zoneSec.map { Int($0.rounded()) },
            mode: cfg.mode, activity: store.activity, rounds: liveRounds,
            samples: compress(samples))
        store.add(s)
        justFinished = s
        phase = .idle
    }

    // MARK: tick
    private func tick() {
        guard running, !paused else { return }
        let now = Date()
        let dt = min(5, now.timeIntervalSince(lastTick))   // guard against background jumps
        lastTick = now
        elapsed += dt

        let fresh = hr.bpm > 0 && hr.isFresh
        if fresh {
            let bpm = hr.bpm
            samples.append((Int(elapsed.rounded()), bpm))
            hrSum += Double(bpm) * dt; hrCount += dt
            if bpm > hrMax { hrMax = bpm }
            let kc = Zones.kcalPerMin(bpm, store.profile) / 60 * dt
            calories += kc
            let z = Zones.zoneOf(bpm, store.profile)
            if z >= 0 { zoneSec[z] += dt }
            if var c = cur, phase == .work {
                c.sum += Double(bpm) * dt; c.count += dt; c.kcal += kc
                if bpm > c.max { c.max = bpm }
                if z >= 0 { c.zoneSec[z] += dt }
                c.endHr = bpm
                cur = c
            }
            if var c = cur, phase == .rest, c.recovery == nil,
               (cfg.restMin * 60 - phaseLeft) >= 60 {
                c.recovery = c.endHr - bpm
                cur = c
            }
        }
        if cfg.mode == .rounds { tickRounds(dt) }
    }

    private func tickRounds(_ dt: Double) {
        phaseLeft -= dt
        if cfg.bells == .on, phase == .work, phaseLeft <= 10, !warned {
            warned = true; Bells.clack()
        }
        if phaseLeft > 0 { return }
        warned = false
        if phase == .work {
            if let c = cur { liveRounds.append(roundStat(c)) }
            if round >= cfg.rounds { Bells.play(3, enabled: cfg.bells == .on); stop(); return }
            if cfg.restMin > 0 {
                phase = .rest; phaseLeft = cfg.restMin * 60; Bells.play(1, enabled: cfg.bells == .on)
            } else { nextRound() }
        } else {
            nextRound()
        }
    }

    private func nextRound() {
        round += 1; phase = .work; phaseLeft = cfg.roundMin * 60
        cur = Acc(n: round); Bells.play(2, enabled: cfg.bells == .on)
    }

    private func roundStat(_ c: Acc) -> RoundStat {
        RoundStat(n: c.n, avg: c.count > 0 ? Int((c.sum / c.count).rounded()) : 0,
                  max: c.max, kcal: (c.kcal * 10).rounded() / 10, recovery: c.recovery)
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
        return phase == .rest ? 120 : 155 + 20 * sin(elapsed / 40)
    }
}
