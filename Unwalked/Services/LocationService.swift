import CoreLocation
import Observation

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?
    /// Direction of travel in degrees, from GPS course or the compass.
    private(set) var heading: CLLocationDirection = 0

    /// Called for every good fix while a walk is running.
    var onUpdate: ((CLLocation) -> Void)?

    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// One fresh fix, or nil if location is off.
    func currentLocation() async -> CLLocation? {
        if let location, location.timestamp.timeIntervalSinceNow > -30 { return location }
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            manager.requestLocation()
        }
    }

    /// Starts continuous updates that keep running with the phone in a pocket.
    func startWalking() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopWalking() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized { manager.requestLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0, last.horizontalAccuracy < 50 else { return }
        location = last
        if last.course >= 0, last.speed > 0.5 { heading = last.course }
        waiters.forEach { $0.resume(returning: last) }
        waiters.removeAll()
        onUpdate?(last)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if (location?.speed ?? 0) <= 0.5, newHeading.headingAccuracy >= 0 {
            heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        waiters.forEach { $0.resume(returning: nil) }
        waiters.removeAll()
    }
}
