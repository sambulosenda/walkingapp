#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity for a walk in progress: Lock Screen and Dynamic Island.
struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// SF Symbol for the next turn.
        var symbol: String
        /// "Right in 110 m"
        var headline: String
        /// "onto Mill Lane"
        var detail: String
        /// "110 m", for the compact island.
        var shortDistance: String
        var minutesLeft: Int
        /// 0...1 of the loop walked.
        var progress: Double
        /// "On time", "3 min late"
        var status: String
    }

    var loopName: String
}
#endif
