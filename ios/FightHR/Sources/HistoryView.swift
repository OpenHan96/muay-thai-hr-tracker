import SwiftUI
import Charts

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var filter: Activity? = nil    // nil = All
    @State private var selected: Session?

    private var filtered: [Session] {
        let all = store.sessions.sorted { $0.ts > $1.ts }
        guard let filter else { return all }
        return all.filter { $0.activity == filter }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    filterPicker
                    Card("Last 8 Weeks") { trendChart }
                    totals
                    if filtered.isEmpty {
                        Card { Text("No sessions yet. Connect your monitor and record an activity.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity) }
                    } else {
                        ForEach(filtered) { s in sessionRow(s).onTapGesture { selected = s } }
                    }
                }
                .padding(14)
            }
            .background(Theme.bg)
            .navigationTitle("History")
            .sheet(item: $selected) { SummarySheet(session: $0) }
        }
    }

    private var filterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ActivityChip(icon: "◎", title: "All", isSelected: filter == nil) { filter = nil }
                    .frame(minWidth: 72)
                ForEach(Activity.allCases) { activity in
                    ActivityChip(
                        icon: activity.icon,
                        title: activity.label,
                        isSelected: filter == activity
                    ) {
                        filter = activity
                    }
                    .frame(minWidth: 100)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History activity filter")
    }

    private var totals: some View {
        let secs = filtered.reduce(0) { $0 + $1.durSec }
        return HStack(spacing: 8) {
            StatCell(value: "\(filtered.count)", label: "sessions")
            StatCell(value: String(format: "%.1fh", Double(secs) / 3600), label: "total time")
            StatCell(value: "\(filtered.reduce(0) { $0 + $1.kcal })", label: "total kcal")
            StatCell(value: filtered.isEmpty ? "--" : "\(filtered.reduce(0) { $0 + $1.avg } / filtered.count)", label: "avg hr")
        }
    }

    /// 8 weekly buckets of training minutes. Mirrors drawTrend.
    private var trendChart: some View {
        var mins = [Double](repeating: 0, count: 8)
        let now = Date(); let wk = 7.0 * 86400
        for s in filtered {
            let i = 7 - Int(now.timeIntervalSince(s.ts) / wk)
            if i >= 0 && i < 8 { mins[i] += Double(s.durSec) / 60 }
        }
        return Chart(Array(mins.enumerated()), id: \.offset) { idx, m in
            BarMark(x: .value("week", idx == 7 ? "now" : "\(7 - idx)w"),
                    y: .value("min", m))
            .foregroundStyle(idx == 7 ? Theme.accent : Color(hex: 0x475069))
        }
        .frame(height: 150)
    }

    private func sessionRow(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(s.activity.icon) \(s.activity.label) · \(s.ts.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .bold()
                Spacer()
                Text(s.ts.formatted(.dateTime.hour().minute())).foregroundStyle(Theme.muted)
            }.font(.subheadline)
            HStack(spacing: 14) {
                Text(fmtTime(Double(s.durSec))).bold()
                Text("\(s.kcal) kcal")
                Text("avg \(s.avg)")
                Text("max \(s.max)")
                if !s.rounds.isEmpty { Text("\(s.rounds.count) rds") }
            }.font(.caption).foregroundStyle(Theme.muted)
            ZoneStrip(zoneSec: s.zoneSec)
        }
        .padding(12)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
}
