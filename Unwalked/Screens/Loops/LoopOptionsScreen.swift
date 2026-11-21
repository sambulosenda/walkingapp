import MapKit
import SwiftUI

struct LoopOptionsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        let selected = model.selectedLoop
        ZStack(alignment: .bottom) {
            UnwalkedMap(
                layers: MapLayers(
                    walked: model.library.walks.map(\.path),
                    loop: selected?.path,
                    fresh: selected?.segments.filter(\.isNew).map(\.path) ?? [],
                    home: model.home
                ),
                position: $position
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
                            LoopRow(loop: loop, isSelected: loop.id == selected?.id) {
                                withAnimation(.snappy) { model.selectedLoopID = loop.id }
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .opacity(model.isPlanning && !model.loops.isEmpty ? 0.5 : 1)

                Button("Start walk") { model.startWalk() }
                    .buttonStyle(PrimaryButtonStyle())
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        ChoiceRow(isSelected: isSelected, height: 60, action: action) {
            TitleSubtitle(title: loop.name, subtitle: loop.metaLine)
        } trailing: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.percent(loop.newFraction))
                    .font(.rounded(.title2))
                    .foregroundStyle(Theme.text)
                Text("new")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityLabel("\(loop.name), \(loop.metaLine), \(Format.percent(loop.newFraction)) new")
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
