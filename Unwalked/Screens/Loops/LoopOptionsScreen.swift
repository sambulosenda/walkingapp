import MapKit
import SwiftUI

struct LoopOptionsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .automatic
    @State private var showingOptions = false

    var body: some View {
        let selected = model.selectedLoop
        ZStack(alignment: .bottom) {
            UnwalkedMap(
                layers: MapLayers(
                    walked: model.library.walkedPaths,
                    loop: selected?.path,
                    others: model.loops.filter { $0.id != selected?.id }.map(\.path),
                    fresh: selected?.segments.filter(\.isNew).map(\.path) ?? [],
                    home: model.home,
                    via: model.via
                ),
                position: $position,
                onTap: pick
            )

            VStack {
                HStack {
                    GlassIconButton(systemName: "chevron.left", label: "Back") { model.screen = .home }
                    Spacer()
                    Legend()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                Spacer()
            }

            BottomSheet {
                HStack(spacing: 8) {
                    SheetTitle(text: title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RoundIconButton(systemName: "arrow.clockwise", label: "Show different loops", size: 44) {
                        model.shuffleLoops()
                    }
                    .disabled(model.isPlanning)
                }
                .padding(.top, 14)

                OptionsButton(showing: $showingOptions).padding(.top, 10)

                VStack(spacing: 8) {
                    if model.isPlanning && model.loops.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                                .fill(Theme.rowIdle)
                                .frame(height: 60)
                        }
                        .redacted(reason: .placeholder)
                    } else if let error = model.planError {
                        BodyText(text: error).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    } else {
                        ForEach(model.loops) { loop in
                            LoopRow(loop: loop, preferences: model.appliedPreferences, isSelected: loop.id == selected?.id) {
                                withAnimation(.snappy) { model.selectedLoopID = loop.id }
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .opacity(model.isPlanning && !model.loops.isEmpty ? 0.5 : 1)

                Button("Go") { model.startWalk() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityLabel("Start walk")
                    .disabled(selected == nil || model.isPlanning)
                    .padding(.top, 16)

                if model.library.streets != nil {
                    Text("Street data © OpenStreetMap contributors")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
        }
        .sheet(isPresented: $showingOptions) { LoopOptionsSheet().environment(model) }
        .sensoryFeedback(.selection, trigger: model.selectedLoopID)
        .onChange(of: model.selectedLoopID) { _, _ in frame() }
        .onChange(of: model.isPlanning) { _, planning in
            // Tell VoiceOver when the loops arrive; nothing else on screen says so aloud.
            if !planning { AccessibilityNotification.Announcement(model.planError ?? title).post() }
        }
        .onAppear { frame() }
    }

    private var title: String {
        if model.isPlanning && model.loops.isEmpty { return "Finding loops…" }
        let count = model.loops.count
        let word = [1: "One loop", 2: "Two loops", 3: "Three loops"][count] ?? "\(count) loops"
        return count == 0 ? "No loops yet" : "\(word), \(model.minutes) minutes"
    }

    /// Picks the loop that runs nearest a tap on the map, if one runs close by.
    private func pick(_ place: Coord) {
        let nearest = model.loops
            .map { (loop: $0, distance: Geo.nearest(to: place, on: $0.path).distance) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance < 80, nearest.loop.id != model.selectedLoopID else { return }
        withAnimation(.snappy) { model.selectedLoopID = nearest.loop.id }
    }

    private func frame() {
        if let loop = model.selectedLoop {
            withAnimation(.easeInOut(duration: 0.4)) { position = .fitting(loop.path, sheetFraction: 0.48) }
        } else if let home = model.home {
            position = .home(home, sheetFraction: 0.48)
        }
    }
}

struct LoopRow: View {
    let loop: PlannedLoop
    var preferences = RoutePreferences.none
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        ChoiceRow(isSelected: isSelected, height: 60, action: action) {
            // One fact per row: how much of it is new. The rest shows on the loop that is picked.
            TitleSubtitle(title: loop.name, subtitle: isSelected ? loop.metaLine(for: preferences) : "\(loop.minutes) min")
        } trailing: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.distance(loop.newDistance))
                    .font(.rounded(.title2))
                    .foregroundStyle(Theme.text)
                Text("new")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityLabel("\(loop.name), \(loop.metaLine(for: preferences)), \(Format.distance(loop.newDistance)) new to you")
    }
}

/// One button for everything that shapes a loop: route preferences (F12) and a stop on the way (F16).
/// It says what is switched on, so the sheet need not be opened to know.
struct OptionsButton: View {
    @Environment(AppModel.self) private var model
    @Binding var showing: Bool

    private var summary: String {
        let applied = model.appliedPreferences
        var parts: [String] = []
        if applied.quiet { parts.append("Quiet") }
        if applied.green { parts.append("Green") }
        if model.preferences.lit { parts.append("Well lit") }
        if applied.stepFree { parts.append("Step-free") }
        if let via = model.via { parts.append("via \(via.name)") }
        return parts.isEmpty ? "Options" : parts.joined(separator: " · ")
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(Theme.chip))
        }
        .buttonStyle(.plain)
        .disabled(model.isPlanning)
        .accessibilityLabel("Options")
        .accessibilityValue(summary == "Options" ? "None set" : summary)
    }
}

/// Route preferences and the stop on the way. Each change plans the loops again behind the sheet.
struct LoopOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingStop = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    toggle("Quiet", "Keeps off main roads", symbol: "speaker.slash", \.quiet)
                    toggle("Green", "Goes through parks where it can", symbol: "leaf", \.green)
                    toggle("Well lit", "After dark, keeps to lit streets", symbol: "lightbulb", \.lit)
                    toggle("Step-free", "Never uses steps", symbol: "figure.roll", \.stepFree)
                } header: {
                    Text("Prefer")
                } footer: {
                    if !model.purchases.hasPlus { Text("Quiet, green and step-free are part of Unwalked Plus.") }
                }
                Section("On the way") {
                    Button { addingStop = true } label: {
                        Label(model.via.map { "Via \($0.name)" } ?? "Add a stop", systemImage: "mappin.and.ellipse")
                    }
                    .foregroundStyle(Theme.text)
                    if model.via != nil {
                        Button("Remove the stop", role: .destructive) { model.setVia(nil) }
                    }
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $addingStop) { ViaSearchSheet().environment(model) }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ title: String, _ detail: String, symbol: String,
                        _ preference: WritableKeyPath<RoutePreferences, Bool>) -> some View {
        let locked = preference != \.lit && !model.purchases.hasPlus
        return Toggle(isOn: Binding(
            get: { !locked && model.preferences[keyPath: preference] },
            set: { _ in
                // The paywall cannot open over this sheet, so step out of the way first.
                if locked { dismiss() }
                model.togglePreference(preference)
            }
        )) {
            Label {
                TitleSubtitle(title: title, subtitle: locked ? "Part of Unwalked Plus" : detail)
            } icon: {
                Image(systemName: locked ? "lock" : symbol)
            }
        }
    }
}

struct Legend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            item(color: Theme.fresh, label: "New to you")
            item(color: Theme.walked, label: "Walked")
        }
        .font(.footnote)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .glass(radius: 22)
        .floatingChipTextSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Map key: orange streets are new to you, \(colorScheme == .dark ? "white" : "dark") streets are walked")
    }

    private func item(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 5).accessibilityHidden(true)
            Text(label)
        }
    }
}
