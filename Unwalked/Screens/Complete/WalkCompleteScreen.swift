import MapKit
import SwiftUI

/// Walk complete: the new streets draw in one by one while the count ticks up,
/// then the coverage bar grows by what today added.
struct WalkCompleteScreen: View {
    @Environment(AppModel.self) private var model
    let summary: WalkSummary

    @State private var position: MapCameraPosition = .automatic
    @State private var shown = 0
    @State private var grown = false
    @State private var reveal: Task<Void, Never>?

    private var record: WalkRecord { summary.record }
    private var total: Int { summary.newSegments.count }

    /// Count shown in the headline, scaled so it lands on the real number of new streets.
    private var count: Int {
        guard total > 0 else { return record.newStreets }
        return Int((Double(shown) / Double(total) * Double(record.newStreets)).rounded())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(
                layers: MapLayers(
                    walked: model.library.walks.dropLast().map(\.path) + [record.path],
                    fresh: Array(summary.newSegments.prefix(shown)),
                    home: model.home
                ),
                position: $position
            )

            VStack {
                HStack {
                    Spacer()
                    GlassIconButton(systemName: "arrow.counterclockwise", label: "Replay the reveal") { play() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                Spacer()
            }

            BottomSheet {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(count)")
                        .font(.rounded(64))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                    Text(record.newStreets == 1 ? "new street" : "new streets")
                        .font(.system(size: 22, weight: .bold))
                }
                .foregroundStyle(Theme.text)
                .tracking(-0.22)
                .padding(.top, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(record.newStreets) new streets")

                Text(metaLine)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)

                HStack {
                    Text("Your area")
                    Spacer()
                    Text("\(Format.percent(grown ? summary.coverageAfter : summary.coverageBefore)) walked")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 20)

                CoverageBar(before: summary.coverageBefore,
                            added: grown ? max(0, summary.coverageAfter - summary.coverageBefore) : 0)
                    .padding(.top, 10)

                Button("Done") { model.done() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 20)
            }
        }
        .onAppear {
            position = .fitting(record.path, sheetFraction: 0.42)
            play()
        }
        .onDisappear { reveal?.cancel() }
    }

    private var metaLine: String {
        let minutes = Int((record.duration / 60).rounded())
        return "\(minutes) min · \(Format.km(record.distance)) · \(Format.percent(record.newFraction)) new to you"
    }

    private func play() {
        reveal?.cancel()
        shown = 0
        grown = false
        reveal = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            for i in 0..<total {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.28)) { shown = i + 1 }
                try? await Task.sleep(for: .milliseconds(280))
            }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.7)) { grown = true }
        }
    }
}

struct CoverageBar: View {
    let before: Double
    let added: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Theme.text).frame(width: geo.size.width * before)
                Rectangle().fill(Palette.fresh).frame(width: geo.size.width * added)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Theme.chip)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Coverage bar: \(Format.percent(before)) walked before, \(Format.percent(added)) added today")
    }
}
