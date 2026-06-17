import SwiftUI

struct TrainView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var hr: HeartRateMonitor
    @EnvironmentObject var engine: SessionEngine
    @EnvironmentObject var loc: LocationTracker
    @State private var showSummary = false
    @State private var beat = false

    private var zone: Int { Zones.zoneOf(hr.bpm, store.profile) }
    private var canStart: Bool { hr.status.isLive && !engine.running }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    sportSwitcher
                    connectButton
                    sessionButtons
                    hrCard
                    timerCard
                    statGrid
                    Card("Time in Zones") { ZoneBars(zoneSec: engine.zoneSec) }
                    Card("Heart Rate") {
                        HRChart(samples: engine.samples, profile: store.profile)
                    }
                    if store.timerCfg.mode == .rounds && !engine.liveRounds.isEmpty {
                        roundsCard
                    }
                    Button(hr.isDemo ? "Stop demo" : "Demo mode (simulated HR)") { hr.toggleDemo() }
                        .font(.footnote).foregroundStyle(Theme.muted)
                        .padding(.top, 4)
                }
                .padding(14)
            }
            .background(Theme.bg)
            .navigationTitle("\(store.activity.label) HR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        Circle().fill(hr.status.isLive ? Theme.good : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(hr.status.label).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            .onChange(of: engine.justFinished) { s in if s != nil { showSummary = true } }
            .sheet(isPresented: $showSummary) {
                if let s = engine.justFinished { SummarySheet(session: s) }
            }
        }
    }

    private var sportSwitcher: some View {
        Picker("Sport", selection: Binding(
            get: { store.activity },
            set: { if !engine.running { store.activity = $0 } }
        )) {
            ForEach(Activity.allCases) { a in Text("\(a.icon) \(a.label)").tag(a) }
        }
        .pickerStyle(.segmented)
        .disabled(engine.running)
    }

    private var connectButton: some View {
        Button {
            hr.status.isLive ? hr.disconnect() : hr.connect()
        } label: {
            Text(hr.status.isLive ? "Connected: \(hr.status.label)" : "Connect HR Monitor")
                .frame(maxWidth: .infinity).padding()
        }
        .background(Color(hex: 0x2563eb)).foregroundStyle(.white).bold()
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var sessionButtons: some View {
        HStack(spacing: 10) {
            bigButton("Start", Theme.good, enabled: canStart) { engine.start() }
            bigButton(engine.paused ? "Resume" : "Pause", Color(hex: 0x475069), enabled: engine.running) {
                engine.togglePause()
            }
            bigButton("End", Theme.accent, enabled: engine.running) { engine.stop() }
        }
    }

    private func bigButton(_ t: String, _ c: Color, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).frame(maxWidth: .infinity).padding(.vertical, 14) }
            .background(c).foregroundStyle(.white).bold()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? 1 : 0.35).disabled(!enabled)
    }

    private var hrCard: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill").foregroundStyle(Theme.accent)
                    .scaleEffect(beat ? 1.25 : 1.0)
                    .animation(hr.isFresh ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: beat)
                    .onAppear { beat = true }
                Text(hr.bpm > 0 ? "\(hr.bpm)" : "--").font(.system(size: 72, weight: .heavy)).monospacedDigit()
                Text("bpm").font(.title3).foregroundStyle(Theme.muted)
            }
            Text(zone < 0 ? (hr.bpm > 0 ? "Below Zone 1" : "—") : Theme.zoneNames[zone])
                .bold().foregroundStyle(zone < 0 ? Theme.muted : Theme.zoneColors[zone])
            if hr.bpm > 0 {
                Text("\(Int(Double(hr.bpm) / Double(Zones.maxHr(store.profile)) * 100))% of max HR (\(Zones.maxHr(store.profile)))")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(zone >= 0 ? Theme.zoneColors[zone].opacity(0.13) : Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.5), value: zone)
    }

    private var timerCard: some View {
        let rounds = store.timerCfg.mode == .rounds && engine.running
        return VStack(spacing: 2) {
            Text(rounds ? (engine.phase == .work ? "ROUND \(engine.round)" : "REST")
                        : (engine.paused ? "PAUSED" : "SESSION"))
                .font(.caption).bold().tracking(2)
                .foregroundStyle(engine.phase == .rest ? Theme.good : (rounds ? Theme.accent : Theme.muted))
            Text(rounds ? fmtTime(engine.phaseLeft) : fmtTime(engine.elapsed))
                .font(.system(size: 48, weight: .heavy)).monospacedDigit()
            if rounds {
                Text("Round \(engine.round) / \(store.timerCfg.rounds) · total \(fmtTime(engine.elapsed))")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity).padding(14)
        .background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var statGrid: some View {
        HStack(spacing: 8) {
            if store.activity.usesGPS {
                StatCell(value: fmtKm(loc.distanceMeters), label: "km")
                StatCell(value: fmtPace(loc.paceSecPerKm), label: "pace /km")
                StatCell(value: "\(Int(engine.calories.rounded()))", label: "kcal")
                StatCell(value: engine.hrCount > 0 ? "\(Int((engine.hrSum / engine.hrCount).rounded()))" : "--", label: "avg hr")
            } else {
                StatCell(value: "\(Int(engine.calories.rounded()))", label: "kcal")
                StatCell(value: engine.hrCount > 0 ? "\(Int((engine.hrSum / engine.hrCount).rounded()))" : "--", label: "avg hr")
                StatCell(value: engine.hrMax > 0 ? "\(engine.hrMax)" : "--", label: "max hr")
                StatCell(value: hr.bpm > 0 ? "\(Int(Double(hr.bpm) / Double(Zones.maxHr(store.profile)) * 100))%" : "--", label: "% max")
            }
        }
    }

    private var roundsCard: some View {
        Card("Rounds") {
            VStack(spacing: 4) {
                HStack { Text("Rd"); Spacer(); Text("Avg"); Text("Max"); Text("kcal"); Text("Rec") }
                    .font(.caption2).foregroundStyle(Theme.muted)
                ForEach(engine.liveRounds) { r in
                    HStack {
                        Text("R\(r.n)"); Spacer()
                        Text("\(r.avg)").frame(width: 40, alignment: .trailing)
                        Text("\(r.max)").frame(width: 40, alignment: .trailing)
                        Text("\(Int(r.kcal))").frame(width: 40, alignment: .trailing)
                        Text(r.recovery.map { "-\($0)" } ?? "-").frame(width: 40, alignment: .trailing)
                    }.font(.caption).monospacedDigit()
                }
            }
        }
    }
}
