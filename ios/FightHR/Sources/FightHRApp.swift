import SwiftUI

@main
struct FightHRApp: App {
    @StateObject private var store: Store
    @StateObject private var hr: HeartRateMonitor
    @StateObject private var loc: LocationTracker
    @StateObject private var engine: SessionEngine

    init() {
        let s = Store()
        let h = HeartRateMonitor()
        let l = LocationTracker()
        _store = StateObject(wrappedValue: s)
        _hr = StateObject(wrappedValue: h)
        _loc = StateObject(wrappedValue: l)
        _engine = StateObject(wrappedValue: SessionEngine(store: s, hr: h, loc: l))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(hr)
                .environmentObject(loc)
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
