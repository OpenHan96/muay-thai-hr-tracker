import SwiftUI

struct SummarySheet: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        StatCell(value: fmtTime(Double(session.durSec)), label: "time")
                        StatCell(value: "\(session.kcal)", label: "kcal")
                        StatCell(value: "\(session.avg)", label: "avg hr")
                        StatCell(value: "\(session.max)", label: "max hr")
                    }
                    ZoneStrip(zoneSec: session.zoneSec, height: 10)
                    ZoneBars(zoneSec: session.zoneSec.map(Double.init))
                    if !session.rounds.isEmpty {
                        Text("PER-ROUND").font(.caption).bold().foregroundStyle(Theme.muted)
                        VStack(spacing: 4) {
                            HStack { Text("Rd"); Spacer(); Text("Avg"); Text("Max"); Text("kcal"); Text("Recovery") }
                                .font(.caption2).foregroundStyle(Theme.muted)
                            ForEach(session.rounds) { r in
                                HStack {
                                    Text("R\(r.n)"); Spacer()
                                    Text("\(r.avg)").frame(width: 44, alignment: .trailing)
                                    Text("\(r.max)").frame(width: 44, alignment: .trailing)
                                    Text("\(Int(r.kcal))").frame(width: 44, alignment: .trailing)
                                    Text(r.recovery.map { "−\($0) bpm" } ?? "—").frame(width: 70, alignment: .trailing)
                                }.font(.caption).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Session Complete 🥊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
