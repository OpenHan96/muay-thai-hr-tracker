import SwiftUI
import MapKit

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
                    if let dist = session.distanceMeters {
                        HStack(spacing: 8) {
                            StatCell(value: fmtKm(dist), label: "km")
                            StatCell(value: session.durSec > 0 && dist > 0
                                ? fmtPace(Double(session.durSec) / (dist / 1000)) : "--", label: "pace /km")
                        }
                    }
                    if let route = session.route, route.count > 1 {
                        RouteMap(route: route).frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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
            .navigationTitle("\(session.activity.label) Complete \(session.activity.icon)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// A static map showing the running route as a polyline.
struct RouteMap: UIViewRepresentable {
    let route: [[Double]]   // [lat, lon] pairs

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = false
        map.delegate = context.coordinator
        let coords = route.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        guard coords.count > 1 else { return map }
        let line = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(line)
        map.setVisibleMapRect(line.boundingMapRect,
                              edgePadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24),
                              animated: false)
        return map
    }
    func updateUIView(_ uiView: MKMapView, context: Context) {}
    func makeCoordinator() -> Coord { Coord() }

    final class Coord: NSObject, MKMapViewDelegate {
        func mapView(_ m: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = UIColor(Theme.accent)
            r.lineWidth = 4
            return r
        }
    }
}
