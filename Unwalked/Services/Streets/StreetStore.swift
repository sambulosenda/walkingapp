import CoreLocation
import Foundation

/// Downloads the streets around home from OpenStreetMap and keeps them on the phone.
///
/// Loops are then planned on the device, so walk history never leaves it. The download asks
/// the Overpass service for streets near a point rounded to about 100 m, not the exact door.
actor StreetStore {
    private struct Meta: Codable {
        var center: Coord
        var radius: CLLocationDistance
        var fetched: Date
    }

    private var graph: StreetGraph?
    private var loading: (center: Coord, radius: CLLocationDistance, task: Task<StreetGraph?, Never>)?

    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    /// Streets change slowly; refresh the saved copy after this long.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    /// How far from home streets are needed for a loop of this length.
    static func reach(minutes: Int, metresPerSecond: Double) -> CLLocationDistance {
        min(4000, max(600, Double(minutes) * 60 * metresPerSecond * 0.34))
    }

    /// How long a caller will wait for a download.
    enum Patience {
        /// The walker is watching a spinner: give up quickly and let the caller fall back.
        case brief
        /// Nobody is waiting: take as long as the server needs.
        case patient

        var seconds: TimeInterval { self == .brief ? 8 : 90 }
    }

    /// The streets within `radius` of `center`, from memory, disk or the network, in that order.
    /// Falls back to a smaller saved copy when the network fails, and to nil when there is none.
    func graph(around center: Coord, radius: CLLocationDistance, patience: Patience = .patient) async -> StreetGraph? {
        if let graph, graph.covers(center, radius: radius) { return graph }
        if let loading, loading.center.distance(to: center) + radius <= loading.radius + 1 {
            // A download is already running. Only wait for it if the caller has the time.
            if patience == .patient { return await loading.task.value }
            if let graph, graph.center.distance(to: center) < graph.radius * 0.5 { return graph }
            return nil
        }
        // Round the centre so the request does not pinpoint the walker's door.
        let rounded = Coord(lat: (center.lat * 1000).rounded() / 1000, lon: (center.lon * 1000).rounded() / 1000)
        let wanted = (radius / 500).rounded(.up) * 500 + 150
        let task = Task { await self.load(center: rounded, radius: wanted, patience: patience) }
        loading = (rounded, wanted, task)
        let loaded = await task.value
        loading = nil
        if let loaded { graph = loaded }
        if let graph, graph.center.distance(to: center) < graph.radius * 0.5 { return graph }
        return nil
    }

    private func load(center: Coord, radius: CLLocationDistance, patience: Patience) async -> StreetGraph? {
        if let meta = try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: Self.metaURL)),
           meta.center.distance(to: center) + radius <= meta.radius + 1,
           Date().timeIntervalSince(meta.fetched) < Self.maxAge,
           let raw = try? Data(contentsOf: Self.dataURL),
           let saved = StreetGraph(overpass: raw, center: meta.center, radius: meta.radius) {
            return saved
        }
        if let raw = await Self.download(center: center, radius: radius, within: patience.seconds),
           let fresh = StreetGraph(overpass: raw, center: center, radius: radius) {
            try? raw.write(to: Self.dataURL, options: .atomic)
            try? JSONEncoder().encode(Meta(center: center, radius: radius, fetched: .now)).write(to: Self.metaURL, options: .atomic)
            return fresh
        }
        // No network: an older or smaller saved copy is better than nothing.
        if let meta = try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: Self.metaURL)),
           let raw = try? Data(contentsOf: Self.dataURL) {
            return StreetGraph(overpass: raw, center: meta.center, radius: meta.radius)
        }
        return nil
    }

    private static func download(center: Coord, radius: CLLocationDistance, within seconds: TimeInterval) async -> Data? {
        let query = "[out:json][timeout:25];way[\"highway\"](around:\(Int(radius)),\(center.lat),\(center.lon));out body;>;out skel qt;"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = seconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint, timeoutInterval: seconds)
        request.httpMethod = "POST"
        request.httpBody = Data("data=\(encoded)".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Unwalked/0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var dataURL: URL { directory.appendingPathComponent("streets.json") }
    private static var metaURL: URL { directory.appendingPathComponent("streets-meta.json") }
}
