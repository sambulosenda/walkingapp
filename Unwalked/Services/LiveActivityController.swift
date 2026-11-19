import ActivityKit
import Foundation

/// Starts, updates and ends the walk's Live Activity.
final class LiveActivityController {
    private var activity: Activity<WalkActivityAttributes>?

    func start(loopName: String, state: WalkActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        activity = try? Activity.request(
            attributes: WalkActivityAttributes(loopName: loopName),
            content: .init(state: state, staleDate: .now.addingTimeInterval(120))
        )
    }

    func update(_ state: WalkActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: state, staleDate: .now.addingTimeInterval(120))) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
