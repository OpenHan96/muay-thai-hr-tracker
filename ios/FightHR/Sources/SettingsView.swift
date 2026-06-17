import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var showShare = false
    @State private var showWipe = false
    @State private var csvURL: URL?

    private var p: Binding<Profile> { $store.profile }

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                modeSection
                zonePreviewSection
                dataSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .sheet(isPresented: $showShare) { if let csvURL { ShareSheet(items: [csvURL]) } }
            .alert("Delete ALL session history?", isPresented: $showWipe) {
                Button("Delete", role: .destructive) { store.deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This cannot be undone.") }
        }
    }

    private var profileSection: some View {
        Section("Profile (for zones & calories)") {
            Stepper("Age: \(store.profile.age)", value: p.age, in: 10...100)
            HStack { Text("Weight (kg)"); Spacer()
                TextField("75", value: p.weightKg, format: .number).keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing).frame(width: 80) }
            Picker("Sex", selection: p.sex) {
                Text("Male").tag(Sex.m); Text("Female").tag(Sex.f)
            }.pickerStyle(.segmented)
            HStack { Text("Max HR (0 = auto)"); Spacer()
                TextField("0", value: p.maxHrOverride, format: .number).keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing).frame(width: 80) }
            HStack { Text("Resting HR"); Spacer()
                TextField("55", value: p.restHr, format: .number).keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing).frame(width: 80) }
            Picker("Zone method", selection: p.zoneMethod) {
                Text("% of Max HR").tag(ZoneMethod.maxhr)
                Text("Karvonen (HR reserve)").tag(ZoneMethod.karvonen)
            }
        }
    }

    private var modeSection: some View {
        let cfg = Binding(get: { store.timerCfg }, set: { store.timerCfg = $0 })
        return Section("Session Mode — \(store.activity.icon) \(store.activity.label)") {
            Picker("Mode", selection: cfg.mode) {
                Text("Continuous").tag(TimerMode.continuous)
                Text("Rounds").tag(TimerMode.rounds)
            }.pickerStyle(.segmented)
            if store.timerCfg.mode == .rounds {
                HStack { Text("Round length (min)"); Spacer()
                    TextField("3", value: cfg.roundMin, format: .number).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).frame(width: 70) }
                HStack { Text("Rest length (min)"); Spacer()
                    TextField("1", value: cfg.restMin, format: .number).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).frame(width: 70) }
                Stepper("Rounds: \(store.timerCfg.rounds)", value: cfg.rounds, in: 1...30)
                Toggle("Bells & 10s warning", isOn: Binding(
                    get: { store.timerCfg.bells == .on },
                    set: { var c = store.timerCfg; c.bells = $0 ? .on : .off; store.timerCfg = c }))
            }
        }
    }

    private var zonePreviewSection: some View {
        let b = Zones.bounds(store.profile)
        let mx = Zones.maxHr(store.profile)
        return Section("Your zones") {
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    Text(Theme.zoneNames[i]).foregroundStyle(Theme.zoneColors[i]).bold()
                    Spacer()
                    Text(i < 4 ? "\(b[i]) – \(b[i+1]-1) bpm" : "\(b[i])+ bpm")
                        .foregroundStyle(Theme.muted).font(.caption).monospacedDigit()
                }
            }
            Text("Max HR: \(mx) bpm\(store.profile.maxHrOverride > 0 ? "" : " (auto)")")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button("Export all sessions (CSV)") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("fight-hr-sessions.csv")
                try? store.csv().write(to: url, atomically: true, encoding: .utf8)
                csvURL = url; showShare = true
            }
            Button("Delete all history", role: .destructive) { showWipe = true }
            Text("All data stays on this device. No account, no cloud.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }
}
