import Foundation
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
