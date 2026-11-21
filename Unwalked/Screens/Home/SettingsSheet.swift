import SwiftUI

/// Not in the v2 designs: a plain settings list behind the Home screen's sliders button.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editingArea = false
    @State private var confirmReset = false

    /// Everything walked so far as a picture (F17).
    private var mapImage: Image {
        ShareCard.image(
            walked: model.library.walkedPaths, home: model.home,
            headline: "\(Format.percent(model.library.coverageFraction)) walked",
            detail: "\(model.library.walks.count) \(model.library.walks.count == 1 ? "walk" : "walks") round my area"
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Your pace") {
                    ForEach(Pace.allCases) { pace in
                        Button {
                            model.library.setPace(pace)
                        } label: {
                            HStack {
                                TitleSubtitle(title: pace.label, subtitle: pace.detail)
                                if model.library.pace == pace {
                                    Image(systemName: "checkmark").fontWeight(.semibold).accessibilityHidden(true)
                                }
                            }
                        }
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(model.library.pace == pace ? .isSelected : [])
                    }
                    if model.library.walks.count >= 2 {
                        Text("Learned from your walks: \(model.library.speedKmh, specifier: "%.1f") km/h")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    } else if let health = model.library.healthSpeedKmh {
                        Text("From Apple Health: \(health, specifier: "%.1f") km/h, until your own walks take over")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    } else if HealthLink.isAvailable {
                        Button("Use my walking speed from Apple Health") {
                            Task { await model.health.refreshWalkingSpeed() }
                        }
                    }
                }

                Section("Home area") {
                    Button("Change home area") { editingArea = true }
                    if let area = model.library.homeArea {
                        LabeledContent("Radius", value: Format.distance(area.radius))
                    }
                }

                if HealthLink.isAvailable {
                    Section {
                        Toggle("Save walks to Apple Health", isOn: Binding(
                            get: { model.health.savesWorkouts },
                            set: { on in Task { await model.health.setSavesWorkouts(on) } }
                        ))
                        Button {
                            // Bringing past walks in is part of Plus.
                            if model.purchases.hasPlus {
                                Task { await model.health.importWalks(into: model.library) }
                            } else {
                                dismiss()
                                model.showPaywall = true
                            }
                        } label: {
                            HStack {
                                Text("Bring in past walks")
                                Spacer()
                                if model.health.isImporting { ProgressView() }
                            }
                        }
                        .disabled(model.health.isImporting)
                    } header: {
                        Text("Apple Health")
                    } footer: {
                        Text(model.health.message ?? "Walks recorded with other apps or a watch colour your map. They stay on this phone.")
                    }
                }

                Section("Unwalked Plus") {
                    if model.purchases.hasPlus {
                        Label("Plus is on. Fresh loops whenever you want.", systemImage: "checkmark.seal")
                    } else {
                        LabeledContent("Free loops left this week", value: "\(model.library.freeLoopsLeft)")
                        Button("Get Unwalked Plus") {
                            dismiss()
                            model.showPaywall = true
                        }
                    }
                    Button("Restore purchases") { Task { await model.purchases.restore() } }
                }

                if model.library.hasWalked {
                    Section {
                        ShareLink(item: mapImage, preview: SharePreview("My Unwalked map", image: mapImage)) {
                            Label("Share a picture of my map", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        Text("Streets only, with the streets round your home left off.")
                    }
                }

                Section {
                    Button("Delete all walks", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Your walks stay on this phone.")
                }

                Section {
                    Link("Street data © OpenStreetMap contributors",
                         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fullScreenCover(isPresented: $editingArea) {
                HomeAreaStep(onDone: { editingArea = false })
                    .environment(model)
            }
            .confirmationDialog("Delete all walks?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete all walks", role: .destructive) {
                    model.library.reset()
                    dismiss()
                    model.screen = .onboarding
                    model.onboardingStep = 1
                }
            } message: {
                Text("This clears your map, coverage and reports. It can't be undone.")
            }
        }
    }
}
