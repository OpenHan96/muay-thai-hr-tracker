import SwiftUI
import Charts

func fmtTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// Distance in km with two decimals, e.g. "3.42".
func fmtKm(_ meters: Double) -> String { String(format: "%.2f", meters / 1000) }

/// Pace as m:ss per km, e.g. "5:30". 0 = unknown.
func fmtPace(_ secPerKm: Double) -> String {
    guard secPerKm > 0, secPerKm.isFinite else { return "--" }
    let s = Int(secPerKm.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Horizontal time-in-zones bars. Mirrors renderZoneBars.
struct ZoneBars: View {
    let zoneSec: [Double]
    var body: some View {
        let total = max(1, zoneSec.reduce(0, +))
        VStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(Theme.zoneNames[i].split(separator: " ").first.map(String.init) ?? "")
                        .font(.caption).bold()
                        .foregroundStyle(Theme.zoneColors[i])
                        .frame(width: 28, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.panel2)
                            Capsule().fill(Theme.zoneColors[i])
                                .frame(width: geo.size.width * zoneSec[i] / total)
                        }
                    }
                    .frame(height: 14)
                    Text(fmtTime(zoneSec[i]))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }
}

/// Thin stacked strip of zone proportions (history rows & summary).
struct ZoneStrip: View {
    let zoneSec: [Int]
    var height: CGFloat = 6
    var body: some View {
        let total = max(1, zoneSec.reduce(0, +))
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    Theme.zoneColors[i]
                        .frame(width: geo.size.width * CGFloat(zoneSec[i]) / CGFloat(total))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// Live HR line over zone bands. Mirrors drawHrChart.
struct HRChart: View {
    let samples: [(t: Int, hr: Int)]
    let profile: Profile
    var body: some View {
        let mx = Zones.maxHr(profile)
        let bounds = Zones.bounds(profile)
        let lo = 50, hi = mx + 10
        Chart {
            // zone bands
            ForEach(0..<5, id: \.self) { i in
                let top = i == 4 ? hi : bounds[i + 1]
                RectangleMark(
                    yStart: .value("lo", bounds[i]),
                    yEnd: .value("hi", top)
                )
                .foregroundStyle(Theme.zoneColors[i].opacity(0.15))
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("t", p.t), y: .value("hr", p.hr))
                    .foregroundStyle(.white)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .frame(height: 140)
    }
}

struct StatCell: View {
    let value: String, label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).bold().monospacedDigit().foregroundStyle(Theme.text)
            Text(label.uppercased()).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Share-sheet wrapper for CSV export.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
