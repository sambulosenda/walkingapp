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
    @State private var failure: String?

    /// Kinds of place to pass, each with the map categories it means.
    private static var quick: [(label: String, categories: [MKPointOfInterestCategory])] {
        var postBox: [MKPointOfInterestCategory] = [.postOffice]
        if #available(iOS 18.0, *) { postBox.insert(.mailbox, at: 0) }
        return [("Café", [.cafe]), ("Post box", postBox), ("Shop", [.store, .foodMarket]),
                ("Bakery", [.bakery]), ("Pharmacy", [.pharmacy])]
    }

    var body: some View {
        NavigationStack {
            List {
                if !searched {
                    Section("Pass one on the way") {
                        ForEach(Self.quick, id: \.label) { kind in
                            Button(kind.label) { Task { await search(categories: kind.categories) } }
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
                if searching {
                    ProgressView().frame(maxWidth: .infinity)
                } else if searched, results.isEmpty {
                    Text(failure ?? "Nothing by that name near enough to walk past.")
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

    /// With `categories`, looks for that kind of place inside the reach and nowhere else. Without,
    /// searches for what was typed: Apple treats the area as a hint for free text, and will happily
    /// answer "café" with one 40 km away, so the answers are cut down to the reach afterwards.
    @MainActor
    private func search(categories: [MKPointOfInterestCategory]? = nil) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home = model.home, categories != nil || !text.isEmpty else { return }
        searching = true
        defer { searching = false; searched = true }
        let search: MKLocalSearch
        if let categories {
            let request = MKLocalPointsOfInterestRequest(center: home.cl, radius: reach)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
            search = MKLocalSearch(request: request)
        } else {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.region = Geo.region(around: home, radius: reach)
            request.resultTypes = .pointOfInterest
            if #available(iOS 18.0, *) { request.regionPriority = .required }
            search = MKLocalSearch(request: request)
        }
        let found: [MKMapItem]
        do {
            found = try await search.start().mapItems
            failure = nil
        } catch {
            // A search that failed is not the same as one that found nothing, and should not say so.
            NSLog("Unwalked via search failed: %@", String(describing: error))
            failure = "Search isn't available right now. Check your connection and try again."
            found = []
        }
        NSLog("Unwalked via search: %d found, nearest %.0f m, reach %.0f m", found.count,
              found.map { Coord($0.placemark.coordinate).distance(to: home) }.min() ?? -1, reach)
        results = found
            .compactMap { item -> ViaPoint? in
                guard let name = item.name else { return nil }
                return ViaPoint(name: name, coord: Coord(item.placemark.coordinate))
            }
            .filter { $0.coord.distance(to: home) <= reach }
            .sorted { $0.coord.distance(to: home) < $1.coord.distance(to: home) }
    }
}
