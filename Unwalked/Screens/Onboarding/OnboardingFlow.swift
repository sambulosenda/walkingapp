import MapKit
import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.onboardingStep {
        case 1: LocationStep()
        case 2: PaceStep()
        default: HomeAreaStep()
        }
    }
}

// MARK: - Step 1: location

struct LocationStep: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var asked = false

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(layers: MapLayers(showsUser: model.location.isAuthorized), position: $position, interactive: false)
            BottomSheet(bottomPadding: 22) {
                StepLabel(step: 1, of: 3).padding(.top, 16)
                SheetTitle(text: "Walks that start at your door").padding(.top, 4)
                BodyText(text: "Unwalked uses your location while you walk, to guide you and fill in your map. Your walks stay on this phone.")
                    .padding(.top, 8)
                Button("Allow location") {
                    asked = true
                    model.location.requestPermission()
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 20)
                Button("Not now") { model.onboardingStep = 2 }
                    .buttonStyle(TextButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .onChange(of: model.location.authorization) { _, status in
            guard asked, status != .notDetermined else { return }
            model.onboardingStep = 2
        }
    }
}

// MARK: - Step 2: pace

struct PaceStep: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var picked: Pace = .normal

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(layers: MapLayers(showsUser: model.location.isAuthorized), position: $position, interactive: false)
            BottomSheet {
                StepLabel(step: 2, of: 3).padding(.top, 16)
                SheetTitle(text: "How do you usually walk?").padding(.top, 4)
                VStack(spacing: 8) {
                    ForEach(Pace.allCases) { pace in
                        ChoiceRow(isSelected: picked == pace, action: { picked = pace }) {
                            TitleSubtitle(title: pace.label, subtitle: pace.detail)
                        } trailing: {
                            RadioDot(isOn: picked == pace)
                        }
                    }
                }
                .padding(.top, 16)
                Text("Unwalked learns your real pace from your first few walks.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 12)
                Button("Continue") {
                    model.library.setPace(picked)
                    model.onboardingStep = 3
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 16)
            }
        }
        .onAppear { picked = model.library.pace }
    }
}

// MARK: - Step 3: home area

struct HomeAreaStep: View {
    @Environment(AppModel.self) private var model
    /// Set when the step is reopened from Settings, so "Looks right" just closes it.
    var onDone: (() -> Void)?

    @State private var area: HomeArea?
    @State private var position: MapCameraPosition = .automatic
    @State private var dragging = false
    private static let space = "homeAreaMap"

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                UnwalkedMap(layers: MapLayers(home: area?.center, homeArea: area), position: $position, interactive: false)
                    .overlay {
                        if let area, let handle = proxy.convert(edge(of: area).cl, to: .named(Self.space)) {
                            Circle()
                                .fill(.white)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Palette.ink, lineWidth: 3.5))
                                .scaleEffect(dragging ? 1.25 : 1)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                                .position(handle)
                                .gesture(resize(proxy: proxy))
                                .accessibilityElement()
                                .accessibilityLabel("Home area edge")
                                .accessibilityValue(Format.distance(area.radius))
                                .accessibilityAdjustableAction { direction in
                                    let step: Double = direction == .increment ? 100 : -100
                                    self.area?.radius = clamp(area.radius + step)
                                }
                        }
                    }
                    .coordinateSpace(.named(Self.space))
            }

            BottomSheet {
                if onDone == nil { StepLabel(step: 3, of: 3).padding(.top, 16) }
                SheetTitle(text: "This is your home area").padding(.top, onDone == nil ? 4 : 16)
                if let area {
                    BodyText(text: "Your coverage counts the \(area.estimatedStreetCount) streets inside the circle. Drag its edge to make it bigger or smaller.")
                        .padding(.top, 8)
                        .contentTransition(.numericText())
                    Button("Looks right") {
                        if let onDone {
                            model.library.setHomeArea(area)
                            onDone()
                        } else {
                            model.finishOnboarding(area: area)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 20)
                } else if model.location.isAuthorized || model.location.authorization == .notDetermined {
                    BodyText(text: "Finding where you are…").padding(.top, 8)
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                } else {
                    BodyText(text: "Unwalked needs your location to find your home area and plan loops from your door.")
                        .padding(.top, 8)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 20)
                }
            }
        }
        .task { await locate() }
        .onChange(of: model.location.authorization) { _, _ in Task { await locate() } }
    }

    private func locate() async {
        if let existing = model.library.homeArea, area == nil {
            area = existing
        } else if area == nil, let fix = await model.location.currentLocation() {
            area = HomeArea(center: Coord(fix.coordinate))
        }
        if let area { position = .home(area.center, radius: area.radius * 1.15, sheetFraction: 0.32) }
    }

    private func edge(of area: HomeArea) -> Coord {
        Geo.destination(from: area.center, bearing: 90, distance: area.radius)
    }

    private func clamp(_ r: Double) -> Double { min(HomeArea.maxRadius, max(HomeArea.minRadius, r)) }

    private func resize(proxy: MapProxy) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                dragging = true
                guard let area, let c = proxy.convert(value.location, from: .named(Self.space)) else { return }
                self.area?.radius = clamp(area.center.distance(to: Coord(c)))
            }
            .onEnded { _ in
                dragging = false
                if let area { withAnimation { position = .home(area.center, radius: area.radius * 1.15, sheetFraction: 0.32) } }
            }
    }
}
