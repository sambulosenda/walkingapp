import Observation
import WatchConnectivity
import WatchKit

@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    private(set) var message: WatchMessage = .idle

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
        DispatchQueue.main.async { self.message = new }
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
