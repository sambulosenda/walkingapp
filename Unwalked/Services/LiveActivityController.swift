import ActivityKit
import Foundation

/// Starts, updates and ends the walk's Live Activity. Call it from the main thread.
final class LiveActivityController {
    /// Something worth lighting the screen for: the Dynamic Island opens and the watch taps.
    struct Alert {
        var title: String
        var body: String
    }

    private var activity: Activity<WalkActivityAttributes>?
    private var shown: WalkActivityAttributes.ContentState?
    /// The newest state not yet sent. Updates go out one at a time and in order, always with the latest.
    private var waiting: (state: WalkActivityAttributes.ContentState, alert: Alert?)?
    private var isSending = false

    /// A walk left running when the app was closed leaves its Live Activity on the Lock Screen. Clear those.
    static func endLeftovers() {
        for old in Activity<WalkActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(loopName: String, state: WalkActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        activity = try? Activity.request(
            attributes: WalkActivityAttributes(loopName: loopName),
            content: content(state)
        )
        shown = state
    }

    func update(_ state: WalkActivityAttributes.ContentState, alert: Alert? = nil) {
        guard activity != nil, alert != nil || state != shown else { return }
        shown = state
        // An alert must not be lost to a plain update that arrives just after it.
        waiting = (state, alert ?? waiting?.alert)
        guard !isSending else { return }
        isSending = true
        Task { @MainActor in
            while let next = waiting, let activity {
                waiting = nil
                let alert = next.alert.map {
                    AlertConfiguration(title: "\($0.title)", body: "\($0.body)", sound: .default)
                }
                await activity.update(content(next.state), alertConfiguration: alert)
            }
            isSending = false
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        waiting = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Goes stale after two minutes without news, which is when the widget says the walk has paused.
    private func content(_ state: WalkActivityAttributes.ContentState) -> ActivityContent<WalkActivityAttributes.ContentState> {
        .init(state: state, staleDate: .now.addingTimeInterval(120))
    }
}
