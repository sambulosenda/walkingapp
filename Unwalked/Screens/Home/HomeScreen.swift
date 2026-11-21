import MapKit
import SwiftUI

/// Home, First run and After dark from the v2 designs: one screen, three moods.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .automatic
    @State private var showMilestones = false

    private var firstRun: Bool { !model.library.hasWalked }

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(
                layers: MapLayers(walked: model.library.walkedPaths, home: model.home),
                position: $position
            )

            VStack {
                HStack {
                    // No home yet, no area to have walked a share of.
                    if model.library.homeArea != nil {
                        Button { showMilestones = true } label: {
                            CoveragePill(fraction: model.library.coverageFraction)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows your milestones")
                    }
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
                    BodyText(text: model.library.homeArea == nil
                             ? "Your first loop starts from where you are now."
                             : "Pick a time. Your first loop starts at your door.").padding(.top, 4)
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
                if model.locationRefused {
                    BodyText(text: "Unwalked needs your location to plan a loop from your door.").padding(.top, 12)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 8)
                }
                Button(model.isLocating ? "Finding where you are…" : (firstRun ? "Find my first loop" : "Find loops")) { model.findLoops() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isLocating)
                    .padding(.top, 20)
            }
        }
        .sheet(isPresented: $showMilestones) { MilestonesSheet().environment(model) }
        .onAppear { frame() }
        .onChange(of: model.home) { _, _ in frame() }
    }

    private func frame() {
        if let home = model.home {
            position = .home(home, radius: model.library.homeArea?.radius ?? 700, sheetFraction: 0.42)
        } else {
            // Before the walker has said where they are, show Britain rather than whatever the map picks.
            position = .userLocation(fallback: .region(MKCoordinateRegion(
                center: .init(latitude: 54.2, longitude: -2.6),
                span: .init(latitudeDelta: 11, longitudeDelta: 11))))
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

/// The big minutes readout with − and +, and the usual times beneath it.
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

            // The times people actually have, one tap each. − and + reach everything between.
            HStack(spacing: 8) {
                ForEach([20, 40, 60, 90], id: \.self) { minutes in
                    let isOn = model.minutes == minutes
                    Button("\(minutes)") { withAnimation(.snappy) { model.minutes = minutes } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOn ? Theme.onPrimary : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(isOn ? Theme.primary : Theme.chip))
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(minutes) minutes")
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .sensoryFeedback(.selection, trigger: model.minutes)
    }

    private func step(_ delta: Int) {
        withAnimation(.snappy) { model.stepMinutes(by: delta) }
    }
}
