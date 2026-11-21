import HealthKit
import Observation
import WatchConnectivity
import WatchKit

@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    private(set) var message: WatchMessage = .idle
    /// Held for the length of a walk: it keeps the app running with the wrist down, so the turn taps
    /// still land. It saves nothing to Health; the phone does that if the walker has asked it to.
    private var workout: HKWorkoutSession?
    private let store = HKHealthStore()

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func receive(_ dict: [String: Any]) {
        guard let new = WatchMessage.decode(dict) else { return }
        DispatchQueue.main.async {
            self.message = new
            if new.active { self.startWorkout() } else { self.endWorkout() }
            if let cue = new.cue { Haptics.play(cue) }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if !session.receivedApplicationContext.isEmpty { receive(session.receivedApplicationContext) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receive(message) }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Application context repeats the last live message; don't buzz twice for it.
        guard var new = WatchMessage.decode(applicationContext) else { return }
        new.cue = nil
        DispatchQueue.main.async {
            self.message = new
            if !new.active { self.endWorkout() }
        }
    }

    // MARK: Workout session

    /// Asks once for the permission a workout session needs. Called on launch, not mid-walk.
    func requestAccess() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { _, error in
            if let error { NSLog("Unwalked watch: Health access failed: %@", String(describing: error)) }
        }
    }

    func startWorkout(_ configuration: HKWorkoutConfiguration? = nil) {
        guard workout == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let config = configuration ?? {
            let c = HKWorkoutConfiguration()
            c.activityType = .walking
            c.locationType = .outdoor
            return c
        }()
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            session.startActivity(with: .now)
            workout = session
        } catch {
            NSLog("Unwalked watch: no workout session: %@", String(describing: error))
        }
    }

    func endWorkout() {
        workout?.end()
        workout = nil
    }
}

/// Taps on the wrist, from the "Turn cues" board.
enum Haptics {
    static func play(_ cue: WatchMessage.Cue) {
        switch cue {
        case .left: taps(2, type: .directionDown)
        case .right: taps(3, type: .directionUp)
        case .offLoop: WKInterfaceDevice.current().play(.failure)
        case .late:
            WKInterfaceDevice.current().play(.click)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WKInterfaceDevice.current().play(.retry) }
        }
    }

    private static func taps(_ count: Int, type: WKHapticType) {
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { WKInterfaceDevice.current().play(type) }
        }
    }
}
