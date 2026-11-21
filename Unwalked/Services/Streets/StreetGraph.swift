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
    /// Extra cost after dark: 1 when lit, more when known to be dark or likely to be.
    var darkFactor: Double = 1
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
    /// For each segment, the segments that run alongside it: the two pavements of one road, or a road
    /// and the path beside it. Walking out on one and back on the other is doubling back.
    let twins: [[Int]]
    /// Junction positions in flat metres from the centre, for quick distances.
    private let flat: [(x: Double, y: Double)]
    /// The direction of travel, in radians, at the `from` end and at the `to` end of each segment.
    private let startHeading: [Double]
    private let endHeading: [Double]
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

    /// One square of street data from Unwalked's own server: see `server/src/tiles.js`.
    private struct Tile: Decodable {
        struct Way: Decodable {
            var id: Int64
            /// Positions in `ids`, `lat` and `lon`.
            var nodes: [Int]
            var tags: [String: String]
        }
        var ids: [Int64]
        var lat: [Double]
        var lon: [Double]
        var ways: [Way]
    }

    /// A street as OpenStreetMap has it, before it is cut into segments.
    private struct RawWay {
        var nodes: [Int64]
        var tags: [String: String]
    }

    /// Streets from one Overpass answer.
    convenience init?(overpass data: Data, center: Coord, radius: CLLocationDistance) {
        guard let decoded = try? JSONDecoder().decode(Overpass.self, from: data) else { return nil }
        var coords: [Int64: Coord] = [:]
        var ways: [RawWay] = []
        for element in decoded.elements {
            if element.type == "node", let lat = element.lat, let lon = element.lon {
                coords[element.id] = Coord(lat: lat, lon: lon)
            } else if element.type == "way", let ids = element.nodes, let tags = element.tags {
                ways.append(RawWay(nodes: ids, tags: tags))
            }
        }
        self.init(coords: coords, ways: ways, center: center, radius: radius)
    }

    /// Streets from the tiles that cover the circle. A street that crosses tiles is in each of them, and is used once.
    convenience init?(tiles: [Data], center: Coord, radius: CLLocationDistance) {
        var coords: [Int64: Coord] = [:]
        var ways: [RawWay] = []
        var seen = Set<Int64>()
        // Tiles are square and the area is round: leave out streets that never come near it.
        let reach = radius + 200
        for data in tiles {
            guard let tile = try? JSONDecoder().decode(Tile.self, from: data),
                  tile.lat.count == tile.ids.count, tile.lon.count == tile.ids.count else { return nil }
            let perLat = 111_320.0, perLon = 111_320.0 * cos(center.lat * .pi / 180)
            let near = tile.ids.indices.map { i in
                let x = (tile.lon[i] - center.lon) * perLon, y = (tile.lat[i] - center.lat) * perLat
                return x * x + y * y <= reach * reach
            }
            for way in tile.ways where !seen.contains(way.id) {
                guard way.nodes.allSatisfy(tile.ids.indices.contains), way.nodes.contains(where: { near[$0] }) else { continue }
                seen.insert(way.id)
                for i in way.nodes { coords[tile.ids[i]] = Coord(lat: tile.lat[i], lon: tile.lon[i]) }
                ways.append(RawWay(nodes: way.nodes.map { tile.ids[$0] }, tags: way.tags))
            }
        }
        self.init(coords: coords, ways: ways, center: center, radius: radius)
    }

    private init?(coords: [Int64: Coord], ways raw: [RawWay], center: Coord, radius: CLLocationDistance) {
        var ways: [(nodes: [Int64], name: String?, rule: WayRule)] = []
        // Big roads, walkable or not, kept to find the paths that run beside them.
        var bigRoads: [(nodes: [Int64], reach: Double, factor: Double)] = []
        for way in raw where way.nodes.count > 1 {
            if let big = WayRule.bigRoad(tags: way.tags) { bigRoads.append((way.nodes, big.reach, big.factor)) }
            if let rule = WayRule(tags: way.tags) { ways.append((way.nodes, way.tags["name"] ?? way.tags["ref"], rule)) }
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
                                                  name: way.name, factor: way.rule.factor, isMain: way.rule.isMain,
                                                  darkFactor: way.rule.darkFactor))
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

        self.twins = Self.twins(of: segments, around: center)

        let perLat = 111_320.0, perLon = 111_320.0 * cos(center.lat * .pi / 180)
        func metres(_ c: Coord) -> (x: Double, y: Double) { ((c.lon - center.lon) * perLon, (c.lat - center.lat) * perLat) }
        flat = nodes.map(metres)
        // Headings are taken over the first and last 15 m, so a kink right at a junction does not mislead.
        func heading(along path: [Coord]) -> Double {
            let start = metres(path[0])
            var end = start, walked = 0.0, last = start
            for c in path.dropFirst() {
                let p = metres(c)
                walked += ((p.x - last.x) * (p.x - last.x) + (p.y - last.y) * (p.y - last.y)).squareRoot()
                end = p
                last = p
                if walked >= 15 { break }
            }
            return atan2(end.y - start.y, end.x - start.x)
        }
        startHeading = segments.map { heading(along: $0.path) }
        endHeading = segments.map { heading(along: Array($0.path.reversed())) + .pi }

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

    /// Pairs up segments that run side by side within 30 m, pointing the same or opposite way.
    private static func twins(of segments: [StreetSegment], around center: Coord) -> [[Int]] {
        let perLat = 111_320.0, perLon = 111_320.0 * cos(center.lat * .pi / 180)
        let reach = 30.0, cell = 30.0
        func bucket(_ x: Double, _ y: Double) -> Int64 {
            key(x: Int64((x / cell).rounded(.down)), y: Int64((y / cell).rounded(.down)))
        }
        // A point every 15 m along each segment long enough to be a stretch of street, not a crossing.
        var samples = [[(x: Double, y: Double)]](repeating: [], count: segments.count)
        var heading = [Double](repeating: 0, count: segments.count)
        var grid: [Int64: [(x: Double, y: Double, segment: Int)]] = [:]
        for (i, s) in segments.enumerated() where s.length >= 25 {
            let flat = s.path.map { (x: ($0.lon - center.lon) * perLon, y: ($0.lat - center.lat) * perLat) }
            heading[i] = atan2(flat[flat.count - 1].y - flat[0].y, flat[flat.count - 1].x - flat[0].x)
            var along = 0.0, next = 0.0
            for (p, q) in zip(flat, flat.dropFirst()) {
                let length = ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)).squareRoot()
                while next <= along + length, length > 0 {
                    let t = (next - along) / length
                    let point = (x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
                    samples[i].append(point)
                    grid[bucket(point.x, point.y), default: []].append((point.x, point.y, i))
                    next += 15
                }
                along += length
            }
        }
        var twins = [[Int]](repeating: [], count: segments.count)
        for i in segments.indices where !samples[i].isEmpty {
            var hits: [Int: Int] = [:]
            for p in samples[i] {
                var seen = Set<Int>()
                for dx in [-cell, 0, cell] {
                    for dy in [-cell, 0, cell] {
                        for other in grid[bucket(p.x + dx, p.y + dy)] ?? [] where other.segment != i && !seen.contains(other.segment) {
                            let ex = p.x - other.x, ey = p.y - other.y
                            if ex * ex + ey * ey <= reach * reach { seen.insert(other.segment) }
                        }
                    }
                }
                for s in seen { hits[s, default: 0] += 1 }
            }
            for (other, count) in hits where Double(count) >= Double(samples[i].count) * 0.6 {
                // Side by side means parallel: within 25 degrees, either direction.
                var turn = abs(heading[i] - heading[other]).truncatingRemainder(dividingBy: .pi)
                if turn > .pi / 2 { turn = .pi - turn }
                // Segments that join end to end are the same street carrying on, not a twin.
                let joined = segments[i].from == segments[other].from || segments[i].from == segments[other].to
                    || segments[i].to == segments[other].from || segments[i].to == segments[other].to
                if turn < 25 * .pi / 180, !joined { twins[i].append(other) }
            }
        }
        return twins
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

    /// Metres added to a route for turning from one stretch onto the next. Nothing for carrying
    /// straight on or following a bend; more the sharper the turn, most for doubling straight back.
    func turnCost(from a: Hop, to b: Hop, at node: Int) -> Double {
        if a.segment == b.segment { return 150 }
        guard links[node].count >= 3 else { return 0 }
        let leaving = a.forward ? endHeading[a.segment] : startHeading[a.segment] + .pi
        let entering = b.forward ? startHeading[b.segment] : endHeading[b.segment] + .pi
        var turn = abs(entering - leaving).truncatingRemainder(dividingBy: 2 * .pi)
        if turn > .pi { turn = 2 * .pi - turn }
        let degrees = turn * 180 / .pi
        if degrees < 30 { return 0 }
        if degrees < 60 { return 15 }
        if degrees < 150 { return 40 }
        return 150
    }

    /// The cheapest way from one junction to another, counting the turns as well as the streets.
    /// `cost` returns infinity for a segment that must not be used. `arriving` is the stretch the walker
    /// comes in on, so the first turn is counted too.
    func shortest(from source: Int, to target: Int, arriving: Hop? = nil, cost: (Int) -> Double) -> [Hop]? {
        if source == target { return [] }
        // The search runs over stretches-with-a-direction, so each step knows which way it arrived.
        // Straight-line distance to the target steers it: no route can be shorter than that.
        let goal = flat[target]
        func remaining(_ node: Int) -> Double {
            let dx = flat[node].x - goal.x, dy = flat[node].y - goal.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var best = [Double](repeating: .infinity, count: segments.count * 2)
        var cameFrom = [Int32](repeating: -1, count: segments.count * 2)
        var heap = MinHeap()
        for link in links[source] {
            let c = cost(link.segment)
            guard c.isFinite else { continue }
            let hop = Hop(segment: link.segment, forward: link.forward)
            let d = c + (arriving.map { turnCost(from: $0, to: hop, at: source) } ?? 0)
            let state = link.segment * 2 + (link.forward ? 0 : 1)
            if d < best[state] {
                best[state] = d
                heap.push(d + remaining(link.node), state)
            }
        }
        var arrived = -1
        while let (priority, state) = heap.pop() {
            let segment = state / 2, forward = state % 2 == 0
            let node = forward ? segments[segment].to : segments[segment].from
            let d = best[state]
            if priority > d + remaining(node) + 0.001 { continue }
            if node == target { arrived = state; break }
            let here = Hop(segment: segment, forward: forward)
            for link in links[node] {
                let c = cost(link.segment)
                guard c.isFinite else { continue }
                let next = link.segment * 2 + (link.forward ? 0 : 1)
                let total = d + c + turnCost(from: here, to: Hop(segment: link.segment, forward: link.forward), at: node)
                if total < best[next] {
                    best[next] = total
                    cameFrom[next] = Int32(state)
                    heap.push(total + remaining(link.node), next)
                }
            }
        }
        guard arrived >= 0 else { return nil }
        var hops: [Hop] = []
        var state = arrived
        while state >= 0 {
            hops.append(Hop(segment: state / 2, forward: state % 2 == 0))
            state = Int(cameFrom[state])
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

    /// The stretches of street a walk covered that had not been walked before.
    func newlyWalked(by trail: [Coord], before: Coverage) -> [LoopSegment] {
        guard let first = trail.first else { return [] }
        var today = Coverage()
        today.mark(trail)
        // Only streets inside the box the walk fits in can have been covered.
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for c in trail {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let margin = 0.0005
        var out: [LoopSegment] = []
        // The far pavement of a street just counted is the same street, not another new one.
        var counted = Set<Int>()
        for (i, s) in segments.enumerated() where !twins[i].contains(where: counted.contains) {
            let middle = s.path[s.path.count / 2]
            guard middle.lat > minLat - margin, middle.lat < maxLat + margin,
                  middle.lon > minLon - margin, middle.lon < maxLon + margin else { continue }
            if today.walkedFraction(of: s.path) >= Self.walkedShare, before.walkedFraction(of: s.path) < Self.walkedShare {
                out.append(LoopSegment(path: s.path, street: s.name, isNew: true, length: s.length))
                counted.insert(i)
            }
        }
        return out
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
    /// Extra cost after dark, from OpenStreetMap's `lit` tag.
    var darkFactor: Double

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
        darkFactor = Self.darkFactor(kind: kind, lit: tags["lit"])
    }

    /// Tagged unlit: used after dark only when there is no other way through.
    /// Untagged paths: often unlit (parks, alleys), so mildly avoided. Untagged streets: nearly all lit in the UK.
    static func darkFactor(kind: String, lit: String?) -> Double {
        switch lit {
        case "no", "disused": return 3
        case .some(let value) where !value.isEmpty: return 1
        default:
            return ["footway", "path", "cycleway", "steps", "track", "bridleway"].contains(kind) ? 1.5 : 1
        }
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
