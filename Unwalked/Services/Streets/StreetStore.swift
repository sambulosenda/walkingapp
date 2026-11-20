import CoreLocation
import Foundation

/// One square of street data, about 1.5 km across in Britain: a standard map tile at zoom 14.
struct StreetTile: Hashable {
    static let zoom = 14

    var x: Int
    var y: Int

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// The tile a point falls in.
    init(containing c: Coord) {
        let n = pow(2.0, Double(Self.zoom))
        let rad = c.lat * .pi / 180
        x = min(Int(n) - 1, max(0, Int(((c.lon + 180) / 360 * n).rounded(.down))))
        y = min(Int(n) - 1, max(0, Int(((1 - asinh(tan(rad)) / .pi) / 2 * n).rounded(.down))))
    }

    var path: String { "v1/\(Self.zoom)/\(x)/\(y).json" }

    private var north: Double { Self.latitude(row: Double(y)) }
    private var south: Double { Self.latitude(row: Double(y + 1)) }
    private var west: Double { Double(x) / pow(2.0, Double(Self.zoom)) * 360 - 180 }
    private var east: Double { Double(x + 1) / pow(2.0, Double(Self.zoom)) * 360 - 180 }

    private static func latitude(row: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * row / pow(2.0, Double(zoom))))) * 180 / .pi
    }

    /// Every tile that touches the circle.
    static func covering(center: Coord, radius: CLLocationDistance) -> [StreetTile] {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * cos(center.lat * .pi / 180))
        let a = StreetTile(containing: Coord(lat: center.lat + dLat, lon: center.lon - dLon))
        let b = StreetTile(containing: Coord(lat: center.lat - dLat, lon: center.lon + dLon))
        var out: [StreetTile] = []
        for x in a.x...b.x {
            for y in a.y...b.y {
                let tile = StreetTile(x: x, y: y)
                // The corner tiles of the square round a circle often miss the circle itself.
                let nearest = Coord(lat: min(tile.north, max(tile.south, center.lat)),
                                    lon: min(tile.east, max(tile.west, center.lon)))
                if nearest.distance(to: center) <= radius { out.append(tile) }
            }
        }
        return out
    }
}

/// Downloads the streets around home from OpenStreetMap and keeps them on the phone.
///
/// Loops are then planned on the device, so walk history never leaves it. Streets come as map tiles
/// from Unwalked's own server, which only learns which 1.5 km squares were asked for. Where that server
/// has no answer, the download asks the Overpass service for streets near a point rounded to about
/// 100 m, not the exact door.
actor StreetStore {
    private struct Meta: Codable {
        var center: Coord
        var radius: CLLocationDistance
        var fetched: Date
    }

    private var graph: StreetGraph?
    private var loading: (center: Coord, radius: CLLocationDistance, task: Task<StreetGraph?, Never>)?

    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    /// Where street tiles are served from: `StreetTilesURL` in Info.plist. Nil until one is set,
    /// and then streets come from Overpass alone.
    static let tileHost: URL? = {
        #if DEBUG
        // Launch with `-streetTilesURL http://localhost:8787` to try a server running on this Mac.
        if let local = UserDefaults.standard.string(forKey: "streetTilesURL"), let url = URL(string: local) { return url }
        #endif
        guard let set = Bundle.main.object(forInfoDictionaryKey: "StreetTilesURL") as? String, !set.isEmpty else { return nil }
        return URL(string: set)
    }()
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
        if let host = Self.tileHost,
           let tiles = await Self.tiles(covering: center, radius: radius, from: host, within: patience.seconds),
           let fresh = StreetGraph(tiles: tiles, center: center, radius: radius) {
            return fresh
        }
        // With a walker watching a spinner there is no time to try Overpass as well.
        if Self.tileHost == nil || patience == .patient,
           let raw = await Self.download(center: center, radius: radius, within: patience.seconds),
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

    /// The tiles covering the circle, from the phone where a copy is recent enough and from `host` otherwise.
    /// Nil unless every tile is there: a map with a square missing would plan loops round a hole.
    private static func tiles(covering center: Coord, radius: CLLocationDistance, from host: URL,
                              within seconds: TimeInterval) async -> [Data]? {
        let needed = StreetTile.covering(center: center, radius: radius)
        var found: [StreetTile: Data] = [:]
        var missing: [StreetTile] = []
        for tile in needed {
            let file = tileURL(tile)
            if let saved = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(saved) < maxAge, let data = try? Data(contentsOf: file) {
                found[tile] = data
            } else {
                missing.append(tile)
            }
        }
        if !missing.isEmpty {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = seconds
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            await withTaskGroup(of: (StreetTile, Data?).self) { group in
                for tile in missing {
                    group.addTask {
                        var request = URLRequest(url: host.appendingPathComponent(tile.path), timeoutInterval: seconds)
                        request.setValue("Unwalked/0.1", forHTTPHeaderField: "User-Agent")
                        guard let (data, response) = try? await session.data(for: request),
                              (response as? HTTPURLResponse)?.statusCode == 200, data.first == UInt8(ascii: "{") else { return (tile, nil) }
                        return (tile, data)
                    }
                }
                for await (tile, data) in group {
                    guard let data else { continue }
                    found[tile] = data
                    try? FileManager.default.createDirectory(at: tileURL(tile).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: tileURL(tile), options: .atomic)
                }
            }
        }
        // No network: an older copy of a tile is better than nothing.
        for tile in needed where found[tile] == nil {
            guard let stale = try? Data(contentsOf: tileURL(tile)) else { return nil }
            found[tile] = stale
        }
        return needed.compactMap { found[$0] }
    }

    private static func tileURL(_ tile: StreetTile) -> URL {
        directory.appendingPathComponent("street-tiles/\(StreetTile.zoom)-\(tile.x)-\(tile.y).json")
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
