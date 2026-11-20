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
    @State private var rating: LoopRating?
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                AdaptiveStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(count)")
                        .font(.rounded(min(numeralSize, 96)))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                    Text(record.newStreets == 1 ? "new street" : "new streets")
                        .font(.title2.weight(.bold))
                }
                .foregroundStyle(Theme.text)
                .tracking(-0.22)
                .padding(.top, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(record.newStreets) new \(record.newStreets == 1 ? "street" : "streets")")

                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                VStack(spacing: 10) {
                    AdaptiveStack {
                        Text("Your area").frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(Format.percent(grown ? summary.coverageAfter : summary.coverageBefore)) walked")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    CoverageBar(before: summary.coverageBefore,
                                added: grown ? max(0, summary.coverageAfter - summary.coverageBefore) : 0)
                }
                .padding(.top, 20)
                // One thing to VoiceOver: the bar on its own is a sliver nobody could find.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Your area: \(Format.percent(summary.coverageAfter)) walked, up from \(Format.percent(summary.coverageBefore))")

                HStack(spacing: 8) {
                    Text("How was this loop?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RatingButton(systemName: "hand.thumbsup", label: "Good loop", isOn: rating == .good) { rate(.good) }
                    RatingButton(systemName: "hand.thumbsdown", label: "Not a good loop", isOn: rating == .bad) { rate(.bad) }
                }
                .padding(.top, 16)

                Button("Done") { model.done() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 16)
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

    /// Tapping the picked thumb again clears it.
    private func rate(_ picked: LoopRating) {
        rating = rating == picked ? nil : picked
        model.library.rate(record.id, rating)
    }

    private func play() {
        reveal?.cancel()
        // With Reduce Motion on, show the finished map and count straight away.
        guard !reduceMotion else {
            shown = total
            grown = true
            return
        }
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

struct RatingButton: View {
    let systemName: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "\(systemName).fill" : systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOn ? Theme.onPrimary : Theme.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(isOn ? Theme.primary : Theme.chip))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct CoverageBar: View {
    let before: Double
    let added: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Theme.text).frame(width: geo.size.width * before)
                Rectangle().fill(Theme.fresh).frame(width: geo.size.width * added)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Theme.chip)
        .clipShape(Capsule())
    }
}
