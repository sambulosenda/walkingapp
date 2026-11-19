import SwiftUI

/// Not in the v2 designs: a plain settings list behind the Home screen's sliders button.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editingArea = false
    @State private var confirmReset = false

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
                                if model.library.pace == pace { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }
                        }
                        .foregroundStyle(Theme.text)
                    }
                    if model.library.walks.count >= 2 {
                        Text("Learned from your walks: \(model.library.speedKmh, specifier: "%.1f") km/h")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                }

                Section("Home area") {
                    Button("Change home area") { editingArea = true }
                    if let area = model.library.homeArea {
                        LabeledContent("Radius", value: Format.distance(area.radius))
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
