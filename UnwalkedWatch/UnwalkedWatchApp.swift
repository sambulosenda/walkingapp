import SwiftUI

@main
struct UnwalkedWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
        }
    }
}

struct WatchRootView: View {
    let model: WatchModel

    var body: some View {
        let m = model.message
        Group {
            if !m.active {
                IdleView()
            } else if m.metresToTurn <= 150 {
                TurnView(message: m)
            } else {
                GlanceView(message: m)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: m.metresToTurn <= 150)
    }
}

struct IdleView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.walk").font(.system(size: 36, weight: .semibold))
            Text("Start a loop on your iPhone")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.watchMuted)
        }
    }
}

/// "Watch: turn" board. Shown from 150 m before a turn.
struct TurnView: View {
    let message: WatchMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Loop").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.watchMuted)
            VStack(spacing: 4) {
                Image(systemName: message.symbol)
                    .font(.system(size: 60, weight: .bold))
                    .accessibilityHidden(true)
                Text(message.distance)
                    .font(.rounded(40))
                    .tracking(-0.8)
                    .minimumScaleFactor(0.7)
                Text(message.instruction)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.watchMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Watch: between turns" board: time left in a progress ring.
struct GlanceView: View {
    let message: WatchMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Loop").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.watchMuted)
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Palette.islandTrack, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: message.progress)
                        .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(message.minutesLeft)").font(.rounded(44)).tracking(-0.9)
                        Text("min left").font(.system(size: 13)).foregroundStyle(Palette.watchMuted)
                    }
                }
                .frame(width: 120, height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(message.minutesLeft) minutes left, \(Int(message.progress * 100))% walked")

                if message.newStreets > 0 {
                    Text("\(message.newStreets) new street\(message.newStreets == 1 ? "" : "s") so far")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.watchFresh)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
