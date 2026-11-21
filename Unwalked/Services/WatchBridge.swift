import Foundation
import HealthKit
import WatchConnectivity

/// Sends walk state to the Unwalked watch app.
final class WatchBridge: NSObject, WCSessionDelegate {
    private var session: WCSession? { WCSession.isSupported() ? .default : nil }
    private var last: WatchMessage?

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// True when the watch app is up and listening, so it can tap the wrist and the phone need not.
    var isReady: Bool {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled
        else { return false }
        return session.isReachable
    }

    /// Wakes the watch app at the start of a walk. It starts a workout session, which keeps it running
    /// with the wrist down, so turn taps still arrive. Nothing is saved to Health by it.
    func wakeWatch() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor
        HKHealthStore().startWatchApp(with: configuration) { _, error in
            if let error { NSLog("Unwalked: could not wake the watch: %@", String(describing: error)) }
        }
    }

    func send(_ message: WatchMessage) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        // Skip repeats that only differ by a few metres, unless they carry a cue.
        if message.cue == nil, let last, last.instruction == message.instruction,
           last.distance == message.distance, last.minutesLeft == message.minutesLeft {
            return
        }
        last = message
        let payload = message.encoded()
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        }
        try? session.updateApplicationContext(payload)
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
