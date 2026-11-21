import MapKit
import SwiftUI

/// Picks a stop for the loop to pass on the way: a café, a post box, a shop (F16).
///
/// The search is Apple's. What is typed, and the area searched, go to Apple and nowhere else.
struct ViaSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ViaPoint] = []
    @State private var searching = false
    @State private var searched = false

    private static let quick = ["Café", "Post box", "Shop", "Bakery", "Pharmacy"]

    var body: some View {
        NavigationStack {
            List {
                if !searched {
                    Section("Pass one on the way") {
                        ForEach(Self.quick, id: \.self) { word in
                            Button(word) { query = word; Task { await search() } }
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
                if searching {
                    ProgressView().frame(maxWidth: .infinity)
                } else if searched, results.isEmpty {
                    Text("Nothing by that name near enough to walk past.")
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(results) { place in
                        Button {
                            model.setVia(place)
                            dismiss()
                        } label: {
                            TitleSubtitle(title: place.name, subtitle: subtitle(for: place))
                        }
                        .foregroundStyle(Theme.text)
                    }
                }
            }
            .navigationTitle("Add a stop")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Café, post box, shop…")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func subtitle(for place: ViaPoint) -> String {
        guard let home = model.home else { return "" }
        return "\(Format.distance(home.distance(to: place.coord))) from your door"
    }

    /// How far out a stop can be and still leave a loop: a little under half the walk, as the crow flies.
    private var reach: CLLocationDistance {
        Double(model.minutes) * 60 * model.library.metresPerSecond * 0.4
    }

    @MainActor
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let home = model.home else { return }
        searching = true
        defer { searching = false; searched = true }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = Geo.region(around: home, radius: reach)
        request.resultTypes = .pointOfInterest
        let found = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        results = found
            .compactMap { item -> ViaPoint? in
                guard let name = item.name else { return nil }
                return ViaPoint(name: name, coord: Coord(item.placemark.coordinate))
            }
            .filter { $0.coord.distance(to: home) <= reach }
            .sorted { $0.coord.distance(to: home) < $1.coord.distance(to: home) }
    }
}
