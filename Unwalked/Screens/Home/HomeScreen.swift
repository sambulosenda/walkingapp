import MapKit
import SwiftUI

/// Home, First run and After dark from the v2 designs: one screen, three moods.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .automatic

    private var firstRun: Bool { !model.library.hasWalked }

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(
                layers: MapLayers(walked: model.library.walks.map(\.path), home: model.home),
                position: $position
            )

            VStack {
                HStack {
                    CoveragePill(fraction: model.library.coverageFraction)
                    Spacer()
                    GlassIconButton(systemName: "slider.horizontal.3", label: "Settings") { model.showSettings = true }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                Spacer()
            }

            BottomSheet {
                if firstRun {
                    SheetTitle(text: "Every street here is unwalked").padding(.top, 16)
                    BodyText(text: "Pick a time. Your first loop starts at your door.").padding(.top, 4)
                } else {
                    SheetTitle(text: "How long have you got?").padding(.top, 16)
                }
                MinutePicker().padding(.top, 12)
                if model.isAfterDark, model.preferences.lit {
                    Label {
                        Text("After dark, loops prefer well-lit streets")
                    } icon: {
                        Image(systemName: "moon").font(.system(size: 14, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 10)
                } else if !firstRun {
                    Text("About \(model.estimatedKm, specifier: "%.1f") km at your pace")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .contentTransition(.numericText())
                        .padding(.top, 10)
                }
                Button(firstRun ? "Find my first loop" : "Find loops") { model.findLoops() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 20)
            }
        }
        .onAppear { frame() }
        .onChange(of: model.home) { _, _ in frame() }
    }

    private func frame() {
        if let home = model.home {
            position = .home(home, radius: model.library.homeArea?.radius ?? 700, sheetFraction: 0.42)
        } else {
            position = .userLocation(fallback: .automatic)
        }
    }
}

struct CoveragePill: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.percent(fraction))
                .font(.rounded(.title2))
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
            Text("of your area walked")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .glass(radius: 22)
        .floatingChipTextSize()
        .accessibilityElement(children: .combine)
    }
}

/// The big minutes readout with − and + and the tick ruler beneath it.
struct MinutePicker: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(model.minutes)")
                        .font(.rounded(min(numeralSize, 96)))
                        .tracking(-1.3)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText(value: Double(model.minutes)))
                    Text("min")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Walk time")
                .accessibilityValue("\(model.minutes) minutes")
                .accessibilityAdjustableAction { direction in
                    step(direction == .increment ? 5 : -5)
                }

                RoundIconButton(systemName: "minus", label: "Five minutes less") { step(-5) }
                    .disabled(model.minutes <= AppModel.minuteRange.lowerBound)
                RoundIconButton(systemName: "plus", label: "Five minutes more") { step(5) }
                    .disabled(model.minutes >= AppModel.minuteRange.upperBound)
            }

            TickRuler(value: model.minutes) { picked in
                withAnimation(.snappy) { model.minutes = picked }
            }
        }
        .sensoryFeedback(.selection, trigger: model.minutes)
    }

    private func step(_ delta: Int) {
        withAnimation(.snappy) { model.stepMinutes(by: delta) }
    }
}

/// The ruler under the minutes. Drag along it to scrub the time.
struct TickRuler: View {
    let value: Int
    var onScrub: ((Int) -> Void)?

    var body: some View {
        GeometryReader { geo in
            ticks
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = min(1, max(0, drag.location.x / geo.size.width))
                    let range = AppModel.minuteRange
                    let raw = Double(range.lowerBound) + f * Double(range.upperBound - range.lowerBound)
                    let snapped = Int((raw / 5).rounded()) * 5
                    if snapped != value { onScrub?(snapped) }
                })
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    private var ticks: some View {
        HStack(alignment: .bottom) {
            ForEach(Array(stride(from: 15, through: 120, by: 5)), id: \.self) { m in
                Capsule()
                    .fill(m <= value ? Theme.text : Theme.tickIdle)
                    .frame(width: 3, height: m % 15 == 0 ? 20 : 11)
                if m < 120 { Spacer(minLength: 0) }
            }
        }
        .frame(height: 20)
    }
}
