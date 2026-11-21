import CoreLocation
import MapKit

/// Plans walking loops from the door.
///
/// With street data on the phone, loops are planned on the street graph (see `StreetRouter`).
/// Without it, for example on a first run with no signal, it falls back to Apple's walking directions:
/// home → A → B → home, with A and B placed so the triangle's length roughly matches the time
/// the walker has, then scaled to tighten the fit.
struct LoopPlanner {
    var coverage: Coverage
    var reports: [StreetReport]
    var metresPerSecond: Double
    /// The streets around home, when they have been downloaded.
    var streets: StreetGraph?
    /// What the walker would rather their loops were like. Apple's directions fallback ignores it.
    var preferences = RoutePreferences.none

    /// Runs street-graph work off the main thread.
    private func onStreets<T: Sendable>(_ work: @escaping @Sendable (StreetRouter) -> T) async -> T? {
        guard let streets else { return nil }
        let coverage = coverage, reports = reports, speed = metresPerSecond, preferences = preferences
        return await Task.detached(priority: .userInitiated) {
            work(StreetRouter(graph: streets, coverage: coverage, reports: reports, metresPerSecond: speed, preferences: preferences))
        }.value
    }

    enum PlanError: LocalizedError {
        case noRoutes
        var errorDescription: String? { "Couldn't find a walking loop from here. Try a different time." }
    }

    /// Ratio of street distance to straight-line distance in a typical town.
    private static let detour = 1.25
    /// A loop is close enough when its length is within this share of the time asked for.
    static let fitTolerance = 0.05
    /// Attempts at resizing a loop to fit. Each costs three directions requests, which Apple rate-limits.
    private static let fitPasses = 3

    enum ViaError: LocalizedError {
        case tooFar(String, Int)
        var errorDescription: String? {
            switch self {
            case .tooFar(let name, let minutes): "\(name) is too far for a \(minutes)-minute loop. Pick a nearer stop or a longer walk."
            }
        }
    }

    func loops(from home: Coord, minutes: Int, rotation: Double = 0, via: ViaPoint? = nil) async throws -> [PlannedLoop] {
        let stop = via?.coord
        if let planned = await onStreets({ $0.loops(from: home, minutes: minutes, rotation: rotation, via: stop) }), !planned.isEmpty {
            // The loop still has to close in the time asked for (F16): a stop that makes every loop run
            // well over is refused, not quietly turned into a longer walk.
            if let via, planned.allSatisfy({ abs(Double($0.minutes) / Double(minutes) - 1) > 0.15 }) {
                throw ViaError.tooFar(via.name, minutes)
            }
            return planned
        }
        let target = Double(minutes) * 60 * metresPerSecond
        let bearings = [90.0, 0, 270].map { ($0 + rotation).truncatingRemainder(dividingBy: 360) }

        let found = await withTaskGroup(of: PlannedLoop?.self) { group in
            for bearing in bearings {
                group.addTask { try? await self.loop(from: home, bearing: bearing, target: target, via: stop) }
            }
            var out: [PlannedLoop] = []
            for await loop in group { if let loop { out.append(loop) } }
            return out
        }
        guard !found.isEmpty else { throw PlanError.noRoutes }
        return found.sorted { $0.newFraction > $1.newFraction }
    }

    private func loop(from home: Coord, bearing: Double, target: CLLocationDistance, via: Coord? = nil) async throws -> PlannedLoop? {
        let spread = 35.0
        var radius = target / ((2 + 2 * sin(spread * .pi / 180)) * Self.detour)
        var best: PlannedLoop?
        var bestMiss = Double.infinity
        for _ in 0..<Self.fitPasses {
            let a = Geo.destination(from: home, bearing: bearing - spread, distance: radius)
            let b = Geo.destination(from: home, bearing: bearing + spread, distance: radius)
            guard let loop = try await build(home: home, through: via.map { [$0, b] } ?? [a, b], bearing: bearing) else { return best }
            if crossesReport(loop.path) { return best }
            let error = loop.distance / target
            let miss = abs(error - 1)
            if miss < bestMiss { best = loop; bestMiss = miss }
            if miss < Self.fitTolerance { break }
            radius /= error
        }
        return best
    }

    /// Routes from `start` through `waypoints` and back to `home`.
    func build(home: Coord, from start: Coord? = nil, through waypoints: [Coord], bearing: Double? = nil) async throws -> PlannedLoop? {
        if let planned = await onStreets({ $0.route(home: home, from: start, through: waypoints, bearing: bearing)?.loop }),
           let loop = planned {
            return loop
        }
        let stops = [start ?? home] + waypoints + [home]
        var path: [Coord] = []
        var steps: [TurnStep] = []
        var segments: [LoopSegment] = []

        for (from, to) in zip(stops, stops.dropFirst()) {
            guard let route = try await walkingRoute(from: from, to: to) else { return nil }
            for step in route.steps {
                let stepPath = Geo.path(of: step.polyline)
                guard stepPath.count > 1 else { continue }
                let startIndex = max(0, path.count - 1)
                path.append(contentsOf: path.isEmpty ? stepPath : Array(stepPath.dropFirst()))
                let street = Self.street(in: step.instructions)
                if !step.instructions.isEmpty {
                    steps.append(TurnStep(kind: TurnKind.from(instructions: step.instructions),
                                          street: street, at: stepPath[0], pathIndex: startIndex))
                }
                segments.append(LoopSegment(path: stepPath, street: street,
                                            isNew: coverage.walkedFraction(of: stepPath) < 0.5,
                                            length: step.distance))
            }
        }
        // The last instruction is the arrival home.
        if let last = path.last {
            steps.append(TurnStep(kind: .arrive, street: nil, at: last, pathIndex: path.count - 1))
        }

        let distance = Geo.length(of: path)
        let direction = bearing.map(Self.compass) ?? "Back"
        let via = segments.first(where: \.isNew)?.street ?? segments.compactMap(\.street).first
        let name = via ?? "\(direction) loop"
        return PlannedLoop(name: name, home: home, waypoints: waypoints, path: path, steps: steps,
                           segments: segments, distance: distance, duration: distance / metresPerSecond)
    }

    /// A way home from where the walker is now that takes about `target` metres (F13).
    /// Needs the street graph: Apple's directions cannot be asked for a walk of a given length.
    func wayHome(from here: Coord, home: Coord, target: CLLocationDistance) async -> PlannedLoop? {
        guard let planned = await onStreets({ $0.wayHome(home: home, from: here, target: target)?.loop }) else { return nil }
        return planned
    }

    /// The shortest walk home from where the walker is now.
    func shortcutHome(from here: Coord, home: Coord) async throws -> PlannedLoop? {
        try await build(home: home, from: here, through: [])
    }

    private func walkingRoute(from: Coord, to: Coord) async throws -> MKRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.cl))
        request.transportType = .walking
        request.requestsAlternateRoutes = !reports.isEmpty
        let response = try await MKDirections(request: request).calculate()
        return response.routes.first { !crossesReport(Geo.path(of: $0.polyline)) } ?? response.routes.first
    }

    func crossesReport(_ path: [Coord]) -> Bool {
        guard !reports.isEmpty else { return false }
        // Every loop leaves home and comes back to it: a report right outside the door would rule out
        // every loop there is, so the first and last stretch do not count.
        let ends = [path.first, path.last].compactMap { $0 }
        let points = reports.flatMap(\.path).filter { p in ends.allSatisfy { p.distance(to: $0) > 60 } }
        return Geo.densify(path, spacing: 15).contains { c in points.contains { $0.distance(to: c) < 20 } }
    }

    /// Pulls the street out of "Turn right onto Mill Lane".
    static func street(in instructions: String) -> String? {
        for marker in [" onto ", " on ", " along "] {
            if let range = instructions.range(of: marker, options: .caseInsensitive) {
                let name = instructions[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    static func compass(_ bearing: Double) -> String {
        let names = ["North", "North-east", "East", "South-east", "South", "South-west", "West", "North-west"]
        let i = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8
        return names[i]
    }
}
