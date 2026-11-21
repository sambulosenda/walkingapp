import MapKit
import SwiftUI

// MARK: - Home area
//
// There is no onboarding flow any more: location is asked for at the first loop, and home starts
// where the walker is standing. This is the screen Settings opens to move or resize it.

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

            BottomSheet(collapsible: false) {
                SheetTitle(text: "This is your home area").padding(.top, 16)
                if let area {
                    BodyText(text: "Your coverage counts the streets, about \(area.estimatedStreetCount), inside the circle. Drag its edge to make it bigger or smaller.")
                        .padding(.top, 8)
                        .contentTransition(.numericText())
                    Button("Looks right") {
                        model.library.setHomeArea(area)
                        onDone?()
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
