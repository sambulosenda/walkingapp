import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen Live Activity and Dynamic Island, from the "Pocket guidance" boards.
struct WalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            LockScreenView(state: context.isStale ? context.state.paused : context.state)
                .activityBackgroundTint(Palette.activityCard)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.isStale ? context.state.paused : context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurnTile(symbol: s.symbol, size: 48, radius: 15)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.headline)
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(s.detail)
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.activityMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ProgressTrack(progress: s.progress, track: Palette.islandTrack)
                        HStack {
                            Text("\(s.minutesLeft) min left")
                            Spacer()
                            Text(s.status)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.activityMuted)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                }
            } compactLeading: {
                Image(systemName: s.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityLabel(s.headline)
            } compactTrailing: {
                Text(s.shortDistance)
                    .font(.rounded(15))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: s.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityLabel(s.headline)
            }
            .keylineTint(.white)
        }
    }
}

extension WalkActivityAttributes.ContentState {
    /// What to show when the app has stopped sending news: a turn from minutes ago would mislead.
    var paused: Self {
        var s = self
        s.symbol = "pause.fill"
        s.headline = "Walk paused"
        s.detail = "Open Unwalked to carry on"
        s.shortDistance = ""
        s.status = "Paused"
        return s
    }
}

struct LockScreenView: View {
    let state: WalkActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                TurnTile(symbol: state.symbol, size: 52, radius: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.headline)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.22)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(state.detail)
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.activityMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(state.minutesLeft) min").font(.rounded(22))
                    Text("left").font(.system(size: 15)).foregroundStyle(Palette.activityMuted)
                }
            }
            ProgressTrack(progress: state.progress, track: Palette.activityTrack)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

struct TurnTile: View {
    let symbol: String
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white))
            .accessibilityHidden(true)
    }
}

struct ProgressTrack: View {
    let progress: Double
    let track: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(.white).frame(width: geo.size.width * min(1, max(0, progress)))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Loop progress: \(Int(progress * 100))% walked")
    }
}
