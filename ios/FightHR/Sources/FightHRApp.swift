import SwiftUI

@main
struct FightHRApp: App {
    @StateObject private var store: Store
    @StateObject private var hr: HeartRateMonitor
    @StateObject private var engine: SessionEngine

    init() {
        let s = Store()
        let h = HeartRateMonitor()
        _store = StateObject(wrappedValue: s)
        _hr = StateObject(wrappedValue: h)
        _engine = StateObject(wrappedValue: SessionEngine(store: s, hr: h))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(hr)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { hr.demoTarget = { [weak engine] in engine?.demoTarget() ?? 75 } }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            TrainView()
                .tabItem { Label("Train", systemImage: "bolt.heart") }
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
