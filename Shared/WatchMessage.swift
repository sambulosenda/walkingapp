import Foundation

/// What the phone tells the watch during a walk.
struct WatchMessage: Codable, Equatable {
    enum Cue: String, Codable {
        /// Two taps, low tone.
        case left
        /// Three taps, high tone.
        case right
        /// One long buzz, then the way back.
        case offLoop
        /// Tap and buzz, with a shortcut home.
        case late
    }

    var active: Bool
    var symbol: String
    /// "110 m"
    var distance: String
    /// Metres to the next turn, so the watch knows when to show the turn screen.
    var metresToTurn: Double
    /// "Right onto Mill Lane"
    var instruction: String
    var minutesLeft: Int
    var progress: Double
    var newStreets: Int
    var cue: Cue?

    static let idle = WatchMessage(active: false, symbol: "figure.walk", distance: "", metresToTurn: 9_999,
                                   instruction: "", minutesLeft: 0, progress: 0, newStreets: 0, cue: nil)

    static let key = "walk"

    func encoded() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.key: data]
    }

    static func decode(_ dict: [String: Any]) -> WatchMessage? {
        guard let data = dict[key] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchMessage.self, from: data)
    }
}
