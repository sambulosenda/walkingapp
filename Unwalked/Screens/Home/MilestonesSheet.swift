import SwiftUI

/// What the walker has reached so far, what is next, and the streets they have walked end to end.
struct MilestonesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let library = model.library
        let streets = library.completedStreets.sorted()
        NavigationStack {
            List {
                Section("So far") {
                    if library.milestones.isEmpty {
                        Text("Your first milestone comes with your first whole street.")
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(library.milestones.reversed()) { milestone in
                        Label(milestone.title, systemImage: milestone.symbol)
                    }
                }
                Section("Next") {
                    ForEach(library.nextMilestones, id: \.self) { line in
                        Text(line).foregroundStyle(Theme.muted)
                    }
                }
                if !streets.isEmpty {
                    Section("Streets walked end to end") {
                        ForEach(streets, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle("Milestones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
