import CoreLocation
import Foundation

/// Plans loops on the street graph: several candidates in different directions, scored for
/// how new they are to the walker and how pleasant they are on foot.
struct StreetRouter: Sendable {
    let graph: StreetGraph
    let walked: [Bool]
    let blocked: [Bool]
    let metresPerSecond: Double

    /// Longest stretch a loop may walk out and back along.
    static let longestSpur: CLLocationDistance = 150
    /// A loop fits when its length is within this share of the time asked for.
    static let fitTolerance = 0.05
    /// Metres added to every stretch when choosing a route.
    static let hopCost = 12.0

    init(graph: StreetGraph, coverage: Coverage, reports: [StreetReport], metresPerSecond: Double) {
        self.graph = graph
        walked = graph.walked(in: coverage)
        blocked = graph.blocked(by: reports)
        self.metresPerSecond = metresPerSecond
    }

    struct Candidate {
        var loop: PlannedLoop
        var used: Set<Int>
        /// Longest out-and-back stretch, in metres.
        var spur: CLLocationDistance
        var repeatShare: Double
        var mainShare: Double
        /// How far the length is from the target, as a share of it.
        var miss = 0.0
        var bearing: Double?

        var fits: Bool { miss <= StreetRouter.fitTolerance && spur <= StreetRouter.longestSpur }
        var score: Double { loop.newFraction - mainShare - 2 * repeatShare - 2 * miss }
    }

    // MARK: Loops

    /// Up to three loops of about `minutes`, the one with the most new streets first.
    func loops(from home: Coord, minutes: Int, rotation: Double) -> [PlannedLoop] {
        let target = Double(minutes) * 60 * metresPerSecond
        var candidates: [Candidate] = []
        // Twelve directions, each as a narrow and a wide triangle. Planning is quick, so try plenty.
        for k in 0..<12 {
            let bearing = (Double(k) * 30 + rotation).truncatingRemainder(dividingBy: 360)
            for spread in [25.0, 45.0] {
                // Home and two turning points make a triangle; streets wander about 1.3 times the straight line.
                var radius = target / ((2 + 2 * sin(spread * .pi / 180)) * 1.3)
                var best: Candidate?
                for _ in 0..<8 {
                    let a = Geo.destination(from: home, bearing: bearing - spread, distance: radius)
                    let b = Geo.destination(from: home, bearing: bearing + spread, distance: radius)
                    guard var candidate = route(home: home, through: [a, b], bearing: bearing) else { break }
                    let ratio = candidate.loop.distance / target
                    candidate.miss = abs(ratio - 1)
                    if candidate.miss < (best?.miss ?? .infinity) { best = candidate }
                    if candidate.miss < 0.02 { break }
                    // Move part of the way, so turning points snapping to junctions do not overshoot.
                    radius /= 1 + (ratio - 1) * 0.8
                }
                if let best { candidates.append(best) }
            }
        }

        // Loops that fit the time and have no long spur come first, then the best scores.
        candidates.sort { a, b in a.fits != b.fits ? a.fits : a.score > b.score }
        var picked: [Candidate] = []
        for candidate in candidates where picked.count < 3 {
            let tooSimilar = picked.contains { other in
                let shared = candidate.used.intersection(other.used).count
                return Double(shared) / Double(max(1, min(candidate.used.count, other.used.count))) > 0.7
            }
            if !tooSimilar { picked.append(candidate) }
        }
        picked.sort { $0.loop.newFraction > $1.loop.newFraction }

        // Name each loop after a street the others do not use, so the three rows read differently.
        var taken = Set<String>()
        return picked.map { candidate in
            var loop = candidate.loop
            var lengths: [String: Double] = [:]
            for segment in loop.segments {
                guard let street = segment.street else { continue }
                lengths[street, default: 0] += segment.length * (segment.isNew ? 2 : 1)
            }
            let streets = lengths.sorted { $0.value > $1.value }.map(\.key)
            let direction = candidate.bearing.map(LoopPlanner.compass) ?? "Back"
            if let via = streets.first(where: { !taken.contains($0) }) ?? streets.first {
                taken.insert(via)
                loop.name = "\(direction), via \(via)"
            }
            return loop
        }
    }

    // MARK: Routes

    private func cost(_ segment: Int, used: Set<Int>) -> Double {
        if blocked[segment] { return .infinity }
        let s = graph.segments[segment]
        // A few metres per stretch, so the route prefers staying on a street to weaving between short ones.
        var c = (s.length + Self.hopCost) * s.factor
        if walked[segment] { c *= 1.6 }
        // Coming back along a street already in this loop is a last resort.
        if used.contains(segment) { c *= 6 }
        return c
    }

    /// Routes from `start` (or home) through `waypoints` and back to `home`.
    func route(home: Coord, from start: Coord? = nil, through waypoints: [Coord], bearing: Double? = nil) -> Candidate? {
        guard let homeNode = graph.nearestNode(to: home) else { return nil }
        var stops: [Int]
        if let start {
            guard let n = graph.nearestNode(to: start) else { return nil }
            stops = [n]
        } else {
            stops = [homeNode]
        }
        for waypoint in waypoints {
            // Turn at a real junction, not at the end of a cul-de-sac.
            guard let n = graph.nearestNode(to: waypoint, minLinks: 3) ?? graph.nearestNode(to: waypoint) else { return nil }
            if n != stops.last { stops.append(n) }
        }
        stops.append(homeNode)

        var hops: [StreetGraph.Hop] = []
        var used = Set<Int>()
        for (a, b) in zip(stops, stops.dropFirst()) {
            guard let leg = graph.shortest(from: a, to: b, cost: { cost($0, used: used) }) else { return nil }
            hops += leg
            for hop in leg { used.insert(hop.segment) }
        }
        guard !hops.isEmpty else { return nil }

        var path: [Coord] = []
        var steps: [TurnStep] = []
        var segments: [LoopSegment] = []
        let origin = start ?? home
        if origin.distance(to: graph.nodes[stops[0]]) > 3 { path.append(origin) }

        var seen = Set<Int>()
        var spur = 0.0, run = 0.0, repeated = 0.0, main = 0.0, total = 0.0
        var previous: [Coord]?
        for hop in hops {
            let s = graph.segments[hop.segment]
            let oriented = hop.forward ? s.path : Array(s.path.reversed())
            let junction = hop.forward ? s.from : s.to
            if let previous, let kind = Self.turn(from: previous, to: oriented, streets: graph.links[junction].count) {
                steps.append(TurnStep(kind: kind, street: s.name, at: oriented[0], pathIndex: max(0, path.count - 1)))
            }
            path.append(contentsOf: path.last == oriented[0] ? Array(oriented.dropFirst()) : oriented)

            let again = !seen.insert(hop.segment).inserted
            if again {
                run += s.length
                repeated += s.length
                spur = max(spur, run)
            } else {
                run = 0
            }
            if s.isMain { main += s.length }
            total += s.length
            segments.append(LoopSegment(path: oriented, street: s.name, isNew: !again && !walked[hop.segment], length: s.length))
            previous = oriented
        }
        if let last = path.last, last.distance(to: home) > 3 { path.append(home) }
        steps = Self.calmed(steps, on: path)
        steps.append(TurnStep(kind: .arrive, street: nil, at: path[path.count - 1], pathIndex: path.count - 1))

        let distance = Geo.length(of: path)
        let direction = bearing.map(LoopPlanner.compass) ?? "Back"
        let via = segments.first { $0.isNew && $0.street != nil }?.street ?? segments.compactMap(\.street).first
        let name = via.map { "\(direction), via \($0)" } ?? "\(direction) loop"
        let loop = PlannedLoop(name: name, home: home, waypoints: waypoints, path: path, steps: steps,
                               segments: segments, distance: distance, duration: distance / metresPerSecond)
        return Candidate(loop: loop, used: used, spur: spur,
                         repeatShare: total > 0 ? repeated / total : 0, mainShare: total > 0 ? main / total : 0,
                         bearing: bearing)
    }

    // MARK: Turns

    /// The turn a walker makes going from one stretch to the next, or nil when they carry straight on.
    /// `streets` is how many streets meet at the junction: a bend in a single road is not a turn.
    static func turn(from previous: [Coord], to next: [Coord], streets: Int) -> TurnKind? {
        guard previous.count > 1, next.count > 1 else { return nil }
        let incoming = bearing(from: point(along: Array(previous.reversed()), after: 15), to: previous[previous.count - 1])
        let outgoing = bearing(from: next[0], to: point(along: next, after: 15))
        var angle = (outgoing - incoming).truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        let size = abs(angle)
        if size >= 150 { return .uTurn }
        guard streets >= 3, size >= 30 else { return nil }
        if size < 55 { return angle < 0 ? .slightLeft : .slightRight }
        return angle < 0 ? .left : .right
    }

    /// Drops pairs of opposite turns a few metres apart, such as stepping across a road at a crossing:
    /// the walker carries on the way they were going, and two cues in a row would only confuse.
    static func calmed(_ steps: [TurnStep], on path: [Coord]) -> [TurnStep] {
        func side(_ kind: TurnKind) -> Int {
            switch kind {
            case .left, .slightLeft: -1
            case .right, .slightRight: 1
            default: 0
            }
        }
        var out: [TurnStep] = []
        for step in steps {
            if let last = out.last, side(last.kind) != 0, side(last.kind) == -side(step.kind),
               Geo.length(of: Array(path[last.pathIndex...step.pathIndex])) < 20 {
                out.removeLast()
                continue
            }
            out.append(step)
        }
        return out
    }

    /// The first point at least `distance` metres along a path.
    private static func point(along path: [Coord], after distance: CLLocationDistance) -> Coord {
        var walked = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            walked += a.distance(to: b)
            if walked >= distance { return b }
        }
        return path[path.count - 1]
    }

    static func bearing(from a: Coord, to b: Coord) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let Δλ = (b.lon - a.lon) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return atan2(y, x) * 180 / .pi
    }
}
