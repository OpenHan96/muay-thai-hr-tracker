import Foundation
import CoreLocation

/// GPS distance / pace / route for Running sessions. Degrades gracefully if
/// permission is denied (distance stays 0; HR-only session still works).
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var distanceMeters: Double = 0
    @Published var paceSecPerKm: Double = 0      // 0 = unknown
    @Published var authorized = false
    @Published var route: [CLLocationCoordinate2D] = []

    private let mgr = CLLocationManager()
    private var last: CLLocation?
    private var tracking = false

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        mgr.activityType = .fitness
        mgr.distanceFilter = 5            // meters between updates
    }

    func requestAuth() { mgr.requestWhenInUseAuthorization() }

    func start() {
        distanceMeters = 0; paceSecPerKm = 0; route = []; last = nil
        tracking = true
        requestAuth()
        mgr.startUpdatingLocation()
    }

    func stop() {
        tracking = false
        mgr.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        authorized = (m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways)
        if authorized, tracking { mgr.startUpdatingLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard tracking else { return }
        for loc in locs {
            // ignore poor fixes
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 30 else { continue }
            if let prev = last {
                let d = loc.distance(from: prev)
                if d >= 1 {              // filter GPS jitter while standing
                    distanceMeters += d
                    route.append(loc.coordinate)
                    // pace from this segment's speed (smoothed)
                    if loc.speed > 0.3 {
                        let inst = 1000.0 / loc.speed       // sec per km
                        paceSecPerKm = paceSecPerKm == 0 ? inst : paceSecPerKm * 0.7 + inst * 0.3
                    }
                    last = loc
                }
            } else {
                last = loc
                route.append(loc.coordinate)
            }
        }
    }
}
