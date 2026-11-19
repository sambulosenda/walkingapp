import CoreLocation
import Foundation

/// One stretch of street between two junctions.
struct StreetSegment {
    var from: Int
    var to: Int
    var path: [Coord]
    var length: CLLocationDistance
    var name: String?
    /// Cost multiplier from the kind of way: 1 for a quiet street or path, more for roads that are poor on foot.
    var factor: Double
    /// A main road, with or without a pavement.
    var isMain: Bool
    /// A path or pavement that runs right beside a big road, so it is as loud as walking the road.
    var besideBigRoad = false
}

/// The walkable streets around home, from OpenStreetMap, as junctions joined by segments.
///
/// Only ways that are legal and sensible on foot are kept: nothing private or closed to walkers,
/// no motorways and no driveways. Main roads without a pavement stay in, at a heavy cost.
final class StreetGraph: @unchecked Sendable {
    struct Link {
        var node: Int
        var segment: Int
        /// True when walking the segment from its `from` end.
        var forward: Bool
    }

    struct Hop {
        var segment: Int
        var forward: Bool
    }

    let center: Coord
    let radius: CLLocationDistance
    let nodes: [Coord]
    let segments: [StreetSegment]
    let links: [[Link]]
    /// Junctions in the largest connected piece, keyed by grid cell, for finding the nearest one.
    private let grid: [Int64: [Int]]

    private static let latCell = 0.001
    private static let lonCell = 0.0016

    // MARK: Building from OpenStreetMap

    private struct Overpass: Decodable {
        struct Element: Decodable {
            var type: String
            var id: Int64
            var lat: Double?
            var lon: Double?
            var nodes: [Int64]?
            var tags: [String: String]?
        }
        var elements: [Element]
    }

    init?(overpass data: Data, center: Coord, radius: CLLocationDistance) {
        guard let decoded = try? JSONDecoder().decode(Overpass.self, from: data) else { return nil }
        var coords: [Int64: Coord] = [:]
        var ways: [(nodes: [Int64], name: String?, rule: WayRule)] = []
        // Big roads, walkable or not, kept to find the paths that run beside them.
        var bigRoads: [(nodes: [Int64], reach: Double, factor: Double)] = []
        for element in decoded.elements {
            if element.type == "node", let lat = element.lat, let lon = element.lon {
                coords[element.id] = Coord(lat: lat, lon: lon)
            } else if element.type == "way", let ids = element.nodes, ids.count > 1, let tags = element.tags {
                if let big = WayRule.bigRoad(tags: tags) { bigRoads.append((ids, big.reach, big.factor)) }
                if let rule = WayRule(tags: tags) { ways.append((ids, tags["name"] ?? tags["ref"], rule)) }
            }
        }

        // A node is a junction when more than one way uses it, or a way starts or ends there.
        var uses: [Int64: Int] = [:]
        for way in ways {
            for id in way.nodes { uses[id, default: 0] += 1 }
            uses[way.nodes[0], default: 0] += 1
            uses[way.nodes[way.nodes.count - 1], default: 0] += 1
        }

        var index: [Int64: Int] = [:]
        var nodes: [Coord] = []
        var segments: [StreetSegment] = []
        func node(_ id: Int64, _ c: Coord) -> Int {
            if let i = index[id] { return i }
            index[id] = nodes.count
            nodes.append(c)
            return nodes.count - 1
        }

        for way in ways {
            var startID: Int64?
            var path: [Coord] = []
            for id in way.nodes {
                guard let c = coords[id] else { continue }
                path.append(c)
                guard let from = startID else { startID = id; continue }
                guard (uses[id] ?? 0) > 1 else { continue }
                let length = Geo.length(of: path)
                if length > 0.5, let a = coords[from] {
                    segments.append(StreetSegment(from: node(from, a), to: node(id, c), path: path, length: length,
                                                  name: way.name, factor: way.rule.factor, isMain: way.rule.isMain))
                }
                startID = id
                path = [c]
            }
        }
        guard !segments.isEmpty else { return nil }

        // Mark quiet-looking paths that hug a big road: a cycle path along a dual carriageway is no quieter than the road.
        if !bigRoads.isEmpty {
            let perLat = 111_320.0, perLon = 111_320.0 * cos(center.lat * .pi / 180)
            func flat(_ c: Coord) -> (x: Double, y: Double) { ((c.lon - center.lon) * perLon, (c.lat - center.lat) * perLat) }
            func samples(_ path: [Coord], every spacing: Double) -> [(x: Double, y: Double)] {
                var out: [(x: Double, y: Double)] = []
                var along = 0.0, next = 0.0
                for (a, b) in zip(path, path.dropFirst()) {
                    let p = flat(a), q = flat(b)
                    let length = ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)).squareRoot()
                    while next <= along + length, length > 0 {
                        let t = (next - along) / length
                        out.append((p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t))
                        next += spacing
                    }
                    along += length
                }
                if out.isEmpty, let first = path.first { out.append(flat(first)) }
                return out
            }
            let cell = 50.0
            func bucket(_ x: Double, _ y: Double) -> Int64 {
                Self.key(x: Int64((x / cell).rounded(.down)), y: Int64((y / cell).rounded(.down)))
            }
            var near: [Int64: [(x: Double, y: Double, reach: Double, factor: Double)]] = [:]
            for road in bigRoads {
                for p in samples(road.nodes.compactMap { coords[$0] }, every: 15) {
                    near[bucket(p.x, p.y), default: []].append((p.x, p.y, road.reach, road.factor))
                }
            }
            for i in segments.indices where !segments[i].isMain {
                let points = samples(segments[i].path, every: 20)
                var close = 0
                var worst = 1.0
                for p in points {
                    var hit = 0.0
                    for dx in [-cell, 0, cell] {
                        for dy in [-cell, 0, cell] {
                            for road in near[bucket(p.x + dx, p.y + dy)] ?? [] {
                                let ex = p.x - road.x, ey = p.y - road.y
                                if ex * ex + ey * ey <= road.reach * road.reach { hit = max(hit, road.factor) }
                            }
                        }
                    }
                    if hit > 0 { close += 1; worst = max(worst, hit) }
                }
                if Double(close) >= Double(points.count) * 0.5 {
                    segments[i].besideBigRoad = true
                    segments[i].factor *= worst
                }
            }
        }

        var links = [[Link]](repeating: [], count: nodes.count)
        for (i, s) in segments.enumerated() {
            links[s.from].append(Link(node: s.to, segment: i, forward: true))
            links[s.to].append(Link(node: s.from, segment: i, forward: false))
        }

        // Keep junction lookups to the largest connected piece, so a walk never starts on an island.
        var piece = [Int](repeating: -1, count: nodes.count)
        var sizes: [Int] = []
        for start in nodes.indices where piece[start] < 0 {
            var stack = [start]
            piece[start] = sizes.count
            var size = 0
            while let n = stack.popLast() {
                size += 1
                for link in links[n] where piece[link.node] < 0 {
                    piece[link.node] = sizes.count
                    stack.append(link.node)
                }
            }
            sizes.append(size)
        }
        let largest = sizes.indices.max { sizes[$0] < sizes[$1] } ?? 0
        var grid: [Int64: [Int]] = [:]
        for i in nodes.indices where piece[i] == largest {
            grid[Self.key(for: nodes[i]), default: []].append(i)
        }

        self.center = center
        self.radius = radius
        self.nodes = nodes
        self.segments = segments
        self.links = links
        self.grid = grid
    }

    // MARK: Lookups

    private static func cell(for c: Coord) -> (x: Int64, y: Int64) {
        (Int64((c.lon / lonCell).rounded(.down)), Int64((c.lat / latCell).rounded(.down)))
    }

    private static func key(x: Int64, y: Int64) -> Int64 { (y << 32) ^ (x & 0xFFFF_FFFF) }
    private static func key(for c: Coord) -> Int64 { let k = cell(for: c); return key(x: k.x, y: k.y) }

    /// The closest junction with at least `minLinks` streets meeting at it.
    func nearestNode(to c: Coord, minLinks: Int = 1) -> Int? {
        let home = Self.cell(for: c)
        var best: (node: Int, distance: CLLocationDistance)?
        for ring in 0...8 {
            let r = Int64(ring)
            for dx in -r...r {
                for dy in -r...r where max(abs(dx), abs(dy)) == r {
                    for n in grid[Self.key(x: home.x + dx, y: home.y + dy)] ?? [] where links[n].count >= minLinks {
                        let d = nodes[n].distance(to: c)
                        if d < (best?.distance ?? .infinity) { best = (n, d) }
                    }
                }
            }
            // Cells are about 100 m across, so nothing in a further ring can be closer than this.
            if let best, best.distance <= Double(ring) * 100 { break }
        }
        return best?.node
    }

    /// The closest few junctions with at least `minLinks` streets meeting, nearest first, within `reach` metres.
    func nearestNodes(to c: Coord, count: Int, minLinks: Int, within reach: CLLocationDistance) -> [Int] {
        let home = Self.cell(for: c)
        let rings = Int64((reach / 100).rounded(.up)) + 1
        var found: [(node: Int, distance: CLLocationDistance)] = []
        for dx in -rings...rings {
            for dy in -rings...rings {
                for n in grid[Self.key(x: home.x + dx, y: home.y + dy)] ?? [] where links[n].count >= minLinks {
                    let d = nodes[n].distance(to: c)
                    if d <= reach { found.append((n, d)) }
                }
            }
        }
        return found.sorted { $0.distance < $1.distance }.prefix(count).map(\.node)
    }

    /// True when the graph holds the streets within `radius` of `center`.
    func covers(_ center: Coord, radius: CLLocationDistance) -> Bool {
        self.center.distance(to: center) + radius <= self.radius + 1
    }

    // MARK: Shortest path

    /// The cheapest way from one junction to another. `cost` returns infinity for a segment that must not be used.
    func shortest(from source: Int, to target: Int, cost: (Int) -> Double) -> [Hop]? {
        if source == target { return [] }
        var best = [Double](repeating: .infinity, count: nodes.count)
        var arrivedBy = [Hop?](repeating: nil, count: nodes.count)
        var heap = MinHeap()
        best[source] = 0
        heap.push(0, source)
        while let (d, u) = heap.pop() {
            if d > best[u] { continue }
            if u == target { break }
            for link in links[u] {
                let c = cost(link.segment)
                guard c.isFinite else { continue }
                let next = d + c
                if next < best[link.node] {
                    best[link.node] = next
                    arrivedBy[link.node] = Hop(segment: link.segment, forward: link.forward)
                    heap.push(next, link.node)
                }
            }
        }
        guard best[target].isFinite else { return nil }
        var hops: [Hop] = []
        var n = target
        while n != source, let hop = arrivedBy[n] {
            hops.append(hop)
            n = hop.forward ? segments[hop.segment].from : segments[hop.segment].to
        }
        return hops.reversed()
    }

    // MARK: Walked and reported streets

    /// Share of a segment that must be covered before it counts as walked.
    static let walkedShare = 0.9

    /// Which segments the walker has covered, in segment order.
    func walked(in coverage: Coverage) -> [Bool] {
        segments.map { coverage.walkedFraction(of: $0.path) >= Self.walkedShare }
    }

    /// Which segments run along a reported stretch. A street that only crosses one is left alone.
    func blocked(by reports: [StreetReport]) -> [Bool] {
        var out = [Bool](repeating: false, count: segments.count)
        for report in reports where report.path.count > 1 {
            let reach = Geo.length(of: report.path) + 200
            for (i, s) in segments.enumerated() where !out[i] {
                guard let first = s.path.first, first.distance(to: report.path[0]) < reach + s.length else { continue }
                let points = Geo.densify(s.path, spacing: 10)
                let close = points.filter { Geo.nearest(to: $0, on: report.path).distance < 15 }.count
                if Double(close) / Double(points.count) >= 0.5 || Double(close) * 10 >= 40 { out[i] = true }
            }
        }
        return out
    }

    /// Walked street length over all street length inside the home area.
    func coverage(of coverage: Coverage, in area: HomeArea) -> Double? {
        var total = 0.0, done = 0.0
        for s in segments {
            let middle = s.path[s.path.count / 2]
            guard middle.distance(to: area.center) <= area.radius else { continue }
            total += s.length
            if coverage.walkedFraction(of: s.path) >= Self.walkedShare { done += s.length }
        }
        return total > 0 ? done / total : nil
    }

    /// Named streets inside the home area.
    func streetCount(in area: HomeArea) -> Int {
        var names = Set<String>()
        for s in segments {
            guard let name = s.name, s.path[s.path.count / 2].distance(to: area.center) <= area.radius else { continue }
            names.insert(name)
        }
        return names.count
    }
}

/// Whether a way can be walked, and how much it should be avoided.
struct WayRule {
    var factor: Double
    var isMain: Bool

    /// For a big road: how close a path must run to count as beside it, in metres,
    /// and how much that path should be avoided. Nil for ordinary streets.
    static func bigRoad(tags: [String: String]) -> (reach: Double, factor: Double)? {
        switch tags["highway"] ?? "" {
        case "motorway", "motorway_link", "trunk", "trunk_link": (40, 4)
        case "primary", "primary_link": (25, 2)
        default: nil
        }
    }

    /// Nil for ways a walker must not or should not use.
    init?(tags: [String: String]) {
        guard let kind = tags["highway"] else { return nil }
        let foot = tags["foot"] ?? ""
        let allowed = ["yes", "designated", "permissive"].contains(foot)
        if ["no", "private", "use_sidepath", "discouraged"].contains(foot) { return nil }
        if !allowed, ["private", "no", "customers", "delivery", "military", "agricultural", "forestry"]
            .contains(tags["access"] ?? "") { return nil }
        if tags["area"] == "yes" { return nil }

        var factor: Double
        var isMain = false
        switch kind {
        case "footway", "pedestrian", "living_street", "residential", "unclassified", "road":
            factor = 1
        case "path":
            factor = 1.1
        case "cycleway", "steps", "track", "bridleway":
            factor = 1.2
        case "service":
            if !allowed, ["driveway", "parking_aisle", "drive-through", "emergency_access"]
                .contains(tags["service"] ?? "") { return nil }
            factor = 1.3
        case "tertiary", "tertiary_link":
            factor = 1.3
            isMain = true
        case "secondary", "secondary_link":
            factor = 1.8
            isMain = true
        case "primary", "primary_link":
            factor = 2.6
            isMain = true
        case "trunk", "trunk_link":
            // Legal on foot, but nobody's idea of a walk: used only when there is no other way through.
            factor = 6
            isMain = true
        default:
            // Motorways, roads being built, bus guideways and anything else not meant for walking.
            return nil
        }

        if isMain {
            let sides = [tags["sidewalk"], tags["sidewalk:both"], tags["sidewalk:left"], tags["sidewalk:right"]].compactMap { $0 }
            let hasPavement = sides.contains { ["both", "left", "right", "yes", "separate"].contains($0) }
            let noPavement = !hasPavement && sides.contains { ["no", "none"].contains($0) }
            let speed = tags["maxspeed"] ?? ""
            let fast = speed.contains("national") || ["50 mph", "60 mph", "70 mph"].contains(speed)
            if noPavement {
                factor *= 4
            } else if !hasPavement && fast {
                // No pavement recorded on a fast road: assume the worst.
                factor *= 3
            }
            // Big roundabouts and the one-way halves of dual carriageways are loud and slow to cross.
            if ["roundabout", "circular"].contains(tags["junction"] ?? "") { factor *= 2 }
            else if tags["oneway"] == "yes", kind != "tertiary", kind != "tertiary_link" { factor *= 1.5 }
        }
        self.factor = factor
        self.isMain = isMain
    }
}

/// A small binary heap of (cost, junction), cheapest first.
private struct MinHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ cost: Double, _ node: Int) {
        items.append((cost, node))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].0 < items[parent].0 else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        guard !items.isEmpty else { return top }
        items[0] = last
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count, items[l].0 < items[smallest].0 { smallest = l }
            if r < items.count, items[r].0 < items[smallest].0 { smallest = r }
            guard smallest != i else { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return top
    }
}
