import CoreLocation
import Foundation

/// Plans loops on the street graph: several candidates in different directions, scored for
/// how new they are to the walker and how pleasant they are on foot.
struct StreetRouter: Sendable {
    let graph: StreetGraph
    let walked: [Bool]
    let blocked: [Bool]
    let metresPerSecond: Double
    /// What the walker would rather their loops were like, already settled for the hour and their plan.
    let preferences: RoutePreferences

    /// Longest stretch a loop may walk out and back along.
    static let longestSpur: CLLocationDistance = 150
    /// A loop fits when its length is within this share of the time asked for.
    static let fitTolerance = 0.05
    /// Metres added to every stretch when choosing a route.
    static let hopCost = 12.0

    init(graph: StreetGraph, coverage: Coverage, reports: [StreetReport], metresPerSecond: Double,
         preferences: RoutePreferences = .none) {
        self.graph = graph
        walked = graph.walked(in: coverage)
        blocked = graph.blocked(by: reports)
        self.metresPerSecond = metresPerSecond
        self.preferences = preferences
    }

    struct Candidate {
        var loop: PlannedLoop
        var used: Set<Int>
        /// Longest out-and-back stretch, in metres.
        var spur: CLLocationDistance
        var repeatShare: Double
        /// Share of the loop on a main road, or on a path right beside a big one.
        var mainShare: Double
        /// After dark only: share of the loop on ways tagged as unlit. Zero by day.
        var unlitShare = 0.0
        /// Share of the loop through parks, gardens, commons and woods.
        var greenShare = 0.0
        /// How hard main roads count against a loop: more when the walker asked for quiet.
        var mainWeight = 1.5
        /// How much green space counts for a loop: nothing unless the walker asked for it.
        var greenWeight = 0.0
        /// How far the length is from the target, as a share of it.
        var miss = 0.0
        var bearing: Double?

        /// Share of the loop that runs close beside another part of itself: hairpins and knots.
        var doubledShare = 0.0
        /// Times the loop turns straight back on itself.
        var reversals = 0

        var fits: Bool { miss <= StreetRouter.fitTolerance && spur <= StreetRouter.longestSpur }
        var score: Double {
            loop.newFraction - mainWeight * mainShare + greenWeight * greenShare - 1.5 * unlitShare - 2 * repeatShare - 2 * miss - doubledShare - 0.05 * Double(reversals)
                - 0.03 * turnsPerKm
        }
        /// Turns per kilometre: a loop that turns every hundred metres is tiring to follow.
        var turnsPerKm: Double { loop.distance > 0 ? Double(loop.steps.count) / (loop.distance / 1000) : 0 }
    }

    // MARK: Loops

    /// Up to three loops of about `minutes`, the one with the most new streets first.
    ///
    /// With `via`, every loop goes out through that place first and one turning point after it, so
    /// the stop is on the way rather than a detour bolted on (F16).
    func loops(from home: Coord, minutes: Int, rotation: Double, via: Coord? = nil) -> [PlannedLoop] {
        let target = Double(minutes) * 60 * metresPerSecond
        var candidates: [Candidate] = []
        // Twelve directions, each as a narrow and a wide triangle. Planning is quick, so try plenty.
        for k in 0..<12 {
            let bearing = (Double(k) * 30 + rotation).truncatingRemainder(dividingBy: 360)
            for spread in [25.0, 45.0] {
                // Home and two turning points make a triangle; streets wander about 1.3 times the straight line.
                var radius = target / ((2 + 2 * sin(spread * .pi / 180)) * 1.3)
                // The second spread would only repeat the first: with a stop there is one turning point, not two.
                if via != nil, spread != 25 { continue }
                var best: Candidate?
                // The largest radius known to give too short a loop, and the smallest known to give too long a one.
                var tooShort: Double?, tooLong: Double?
                for _ in 0..<10 {
                    let a = Geo.destination(from: home, bearing: bearing - spread, distance: radius)
                    let b = Geo.destination(from: home, bearing: bearing + spread, distance: radius)
                    let through = via.map { [$0, Geo.destination(from: home, bearing: bearing, distance: radius)] } ?? [a, b]
                    guard var candidate = route(home: home, through: through, bearing: bearing) else { break }
                    let ratio = candidate.loop.distance / target
                    candidate.miss = abs(ratio - 1)
                    if candidate.miss < (best?.miss ?? .infinity) { best = candidate }
                    if candidate.miss < 0.02 { break }
                    if ratio < 1 { tooShort = max(tooShort ?? radius, radius) } else { tooLong = min(tooLong ?? radius, radius) }
                    if let tooShort, let tooLong, tooShort < tooLong {
                        // The right size lies between the two: halve the gap.
                        radius = (tooShort + tooLong) / 2
                    } else {
                        // Move part of the way, so turning points snapping to junctions do not overshoot.
                        radius /= 1 + (ratio - 1) * 0.8
                    }
                }
                if let best { candidates.append(best) }
            }
        }

        // Loops that fit the time and have no long spur come first, then the best scores.
        candidates.sort { a, b in a.fits != b.fits ? a.fits : a.score > b.score }

        // Polish the most promising: let each turning point slide to a nearby junction when that
        // gives a cleaner loop of the same length.
        for i in candidates.indices.prefix(8) {
            candidates[i] = polished(candidates[i], home: home, target: target, keepsFirst: via != nil)
        }
        candidates.sort { a, b in a.fits != b.fits ? a.fits : a.score > b.score }
        var picked: [Candidate] = []
        // A long out-and-back stretch rules a loop out, unless every loop has one: then show the best rather than none.
        let noLongSpur = candidates.filter { $0.spur <= Self.longestSpur }
        for candidate in (noLongSpur.isEmpty ? Array(candidates.prefix(1)) : noLongSpur) where picked.count < 3 {
            // Fewer loops is better than one that is well off the time asked for.
            if !picked.isEmpty, candidate.miss > 2 * Self.fitTolerance { continue }
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
            if let via = streets.first(where: { !taken.contains($0) }) ?? streets.first {
                taken.insert(via)
                loop.name = via
            }
            return loop
        }
    }

    /// Tries the junctions around each of a loop's two turning points and keeps the best-scoring loop.
    /// With `keepsFirst`, the first turning point is a stop the walker chose, and stays where it is.
    private func polished(_ candidate: Candidate, home: Coord, target: CLLocationDistance, keepsFirst: Bool = false) -> Candidate {
        guard candidate.loop.waypoints.count == 2, let homeNode = graph.nearestNode(to: home) else { return candidate }
        var options = candidate.loop.waypoints.map { graph.nearestNodes(to: $0, count: 4, minLinks: 3, within: 220) }
        if keepsFirst {
            guard let stop = graph.nearestNode(to: candidate.loop.waypoints[0]) else { return candidate }
            options[0] = [stop]
        }
        var best = candidate
        for a in options[0] {
            for b in options[1] where a != b {
                guard var other = assemble(home: home, origin: home, stops: [homeNode, a, b, homeNode],
                                           waypoints: [graph.nodes[a], graph.nodes[b]], bearing: candidate.bearing) else { continue }
                other.miss = abs(other.loop.distance / target - 1)
                let better = other.fits != best.fits ? other.fits : other.score > best.score
                if better { best = other }
            }
        }
        return best
    }

    // MARK: Routes

    private func cost(_ segment: Int, used: Set<Int>) -> Double {
        let s = graph.segments[segment]
        // Step-free is a hard rule: for a pram or a wheelchair, one flight of steps ends the walk.
        if preferences.stepFree, s.isSteps { return .infinity }
        // A few metres per stretch, so the route prefers staying on a street to weaving between short ones.
        var c = (s.length + Self.hopCost) * s.factor
        if preferences.lit { c *= s.darkFactor }
        if preferences.quiet, s.isMain || s.besideBigRoad { c *= 2.5 }
        if preferences.green, s.isGreen { c *= 0.55 }
        if walked[segment] { c *= 1.6 }
        // Coming back along a street already in this loop is a last resort.
        if used.contains(segment) { c *= 6 }
        // A reported street is avoided at almost any price, but not at every price: if it is the only
        // way out of home, a loop that has to use it beats no loop at all, for ever.
        if blocked[segment] { c = c * 50 + 5000 }
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
        return assemble(home: home, origin: start ?? home, stops: stops, waypoints: waypoints, bearing: bearing)
    }

    /// A way home from `start` that is about `target` metres long: what is left of a walk after the
    /// walker asks, part-way round, for it to be shorter or longer (F13).
    ///
    /// Nothing is shorter than going straight home, so a target below that returns the direct way.
    /// Otherwise it tries one turning point in each of twelve directions, sliding each in or out
    /// until the way home through it is the right length, and keeps the best-scoring.
    func wayHome(home: Coord, from start: Coord, target: CLLocationDistance) -> Candidate? {
        guard var direct = route(home: home, from: start, through: []) else { return nil }
        direct.miss = target > 0 ? abs(direct.loop.distance / target - 1) : 0
        if target <= direct.loop.distance * (1 + Self.fitTolerance) { return direct }

        let middle = Coord(lat: (start.lat + home.lat) / 2, lon: (start.lon + home.lon) / 2)
        let apart = start.distance(to: home)
        var best = direct
        for k in 0..<12 {
            let bearing = Double(k) * 30
            // Start and home are the two ends; the turning point sits out to one side of the line between them.
            let straight = target / 1.3
            var reach = max(80, (max(0, straight * straight - apart * apart)).squareRoot() / 2)
            var tooShort: Double?, tooLong: Double?
            var found: Candidate?
            for _ in 0..<8 {
                let turning = Geo.destination(from: middle, bearing: bearing, distance: reach)
                guard var candidate = route(home: home, from: start, through: [turning]) else { break }
                let ratio = candidate.loop.distance / target
                candidate.miss = abs(ratio - 1)
                if candidate.miss < (found?.miss ?? .infinity) { found = candidate }
                if candidate.miss < 0.02 { break }
                if ratio < 1 { tooShort = max(tooShort ?? reach, reach) } else { tooLong = min(tooLong ?? reach, reach) }
                if let tooShort, let tooLong, tooShort < tooLong {
                    reach = (tooShort + tooLong) / 2
                } else {
                    reach /= 1 + (ratio - 1) * 0.8
                }
            }
            if let found, found.fits != best.fits ? found.fits : found.score > best.score { best = found }
        }
        return best
    }

    /// Joins the junctions in `stops` by the cheapest streets and describes the result.
    private func assemble(home: Coord, origin: Coord, stops: [Int], waypoints: [Coord], bearing: Double?) -> Candidate? {
        var hops: [StreetGraph.Hop] = []
        var used = Set<Int>()
        for (a, b) in zip(stops, stops.dropFirst()) {
            guard let leg = graph.shortest(from: a, to: b, arriving: hops.last, cost: { cost($0, used: used) }) else { return nil }
            hops += leg
            for hop in leg {
                used.insert(hop.segment)
                // The other pavement of the same road counts as used too.
                used.formUnion(graph.twins[hop.segment])
            }
        }
        guard !hops.isEmpty else { return nil }

        var path: [Coord] = []
        var turns: [TurnStep] = []
        var segments: [LoopSegment] = []
        if origin.distance(to: graph.nodes[stops[0]]) > 3 { path.append(origin) }

        var seen = Set<Int>()
        var spur = 0.0, run = 0.0, repeated = 0.0, main = 0.0, unlit = 0.0, green = 0.0, steps = 0.0, total = 0.0
        var previous: [Coord]?
        var previousSegment: Int?
        var sharpTurns = 0
        for hop in hops {
            let s = graph.segments[hop.segment]
            let oriented = hop.forward ? s.path : Array(s.path.reversed())
            let junction = hop.forward ? s.from : s.to
            // Turning round means walking back along the same stretch. A hairpin bend on a path is not that.
            let kind: TurnKind? = previousSegment == hop.segment ? .uTurn
                : previous.flatMap { Self.turn(from: $0, to: oriented, streets: graph.links[junction].count) }
            if let previous, Self.isSharp(from: previous, to: oriented) { sharpTurns += 1 }
            if let kind {
                turns.append(TurnStep(kind: kind, street: s.name, at: oriented[0], pathIndex: max(0, path.count - 1)))
            }
            previousSegment = hop.segment
            path.append(contentsOf: path.last == oriented[0] ? Array(oriented.dropFirst()) : oriented)

            let again = seen.contains(hop.segment)
            seen.insert(hop.segment)
            seen.formUnion(graph.twins[hop.segment])
            if again {
                run += s.length
                repeated += s.length
                spur = max(spur, run)
            } else {
                run = 0
            }
            if s.isMain || s.besideBigRoad { main += s.length }
            if preferences.lit, s.darkFactor >= 3 { unlit += s.length }
            if s.isGreen { green += s.length }
            if s.isSteps { steps += s.length }
            total += s.length
            segments.append(LoopSegment(path: oriented, street: s.name, isNew: !again && !walked[hop.segment], length: s.length))
            previous = oriented
        }
        if let last = path.last, last.distance(to: home) > 3 { path.append(home) }
        turns = Self.calmed(turns, on: path)
        turns.append(TurnStep(kind: .arrive, street: nil, at: path[path.count - 1], pathIndex: path.count - 1))

        let distance = Geo.length(of: path)
        let direction = bearing.map(LoopPlanner.compass) ?? "Back"
        let via = segments.first { $0.isNew && $0.street != nil }?.street ?? segments.compactMap(\.street).first
        // A loop is called by its street: "Old Compton Street" says more than a compass point does.
        let name = via ?? "\(direction) loop"
        var loop = PlannedLoop(name: name, home: home, waypoints: waypoints, path: path, steps: turns,
                               segments: segments, distance: distance, duration: distance / metresPerSecond)
        loop.greenFraction = total > 0 ? green / total : 0
        loop.mainFraction = total > 0 ? main / total : 0
        loop.stepsMetres = steps
        return Candidate(loop: loop, used: used, spur: spur,
                         repeatShare: total > 0 ? repeated / total : 0, mainShare: total > 0 ? main / total : 0,
                         unlitShare: total > 0 ? unlit / total : 0,
                         greenShare: total > 0 ? green / total : 0,
                         mainWeight: preferences.quiet ? 3 : 1.5, greenWeight: preferences.green ? 0.8 : 0,
                         bearing: bearing, doubledShare: Self.doubledShare(of: path, home: home),
                         reversals: turns.filter { $0.kind == .uTurn }.count + sharpTurns)
    }

    /// Share of a path that runs within 60 m of a part of itself more than 250 m further along:
    /// going down one street and back up the next, or a knot round a turning point.
    /// The stretch near home is left out, since every loop leaves and returns there.
    static func doubledShare(of path: [Coord], home: Coord) -> Double {
        // Work in flat metres around home: this runs for every candidate, so it has to be quick.
        let perLat = 111_320.0, perLon = 111_320.0 * cos(home.lat * .pi / 180)
        func flat(_ c: Coord) -> (x: Double, y: Double) { ((c.lon - home.lon) * perLon, (c.lat - home.lat) * perLat) }
        // One sample every 25 m, with how far along the path it is.
        var samples: [(x: Double, y: Double, along: Double)] = []
        var along = 0.0, next = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            let p = flat(a), q = flat(b)
            let length = ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)).squareRoot()
            while next <= along + length, length > 0 {
                let t = (next - along) / length
                samples.append((p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t, next))
                next += 25
            }
            along += length
        }
        guard samples.count > 20 else { return 0 }
        var close = 0, counted = 0
        for a in samples where a.x * a.x + a.y * a.y > 150 * 150 {
            counted += 1
            for b in samples where abs(a.along - b.along) > 250 {
                let dx = a.x - b.x, dy = a.y - b.y
                if dx * dx + dy * dy < 60 * 60 {
                    close += 1
                    break
                }
            }
        }
        return counted > 0 ? Double(close) / Double(counted) : 0
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

    /// True when the walker all but reverses direction between two stretches.
    static func isSharp(from previous: [Coord], to next: [Coord]) -> Bool {
        guard previous.count > 1, next.count > 1 else { return false }
        let incoming = bearing(from: point(along: Array(previous.reversed()), after: 15), to: previous[previous.count - 1])
        let outgoing = bearing(from: next[0], to: point(along: next, after: 15))
        var angle = abs(outgoing - incoming).truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle = 360 - angle }
        return angle >= 150
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
