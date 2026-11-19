import CoreLocation
import MapKit

/// Plans walking loops from the door with Apple's walking directions.
///
/// Each loop is home → A → B → home, with A and B placed so the triangle's length
/// roughly matches the time the walker has, then scaled once to tighten the fit.
struct LoopPlanner {
    var coverage: Coverage
    var reports: [StreetReport]
    var metresPerSecond: Double

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

    func loops(from home: Coord, minutes: Int, rotation: Double = 0) async throws -> [PlannedLoop] {
        let target = Double(minutes) * 60 * metresPerSecond
        let bearings = [90.0, 0, 270].map { ($0 + rotation).truncatingRemainder(dividingBy: 360) }

        let found = await withTaskGroup(of: PlannedLoop?.self) { group in
            for bearing in bearings {
                group.addTask { try? await self.loop(from: home, bearing: bearing, target: target) }
            }
            var out: [PlannedLoop] = []
            for await loop in group { if let loop { out.append(loop) } }
            return out
        }
        guard !found.isEmpty else { throw PlanError.noRoutes }
        return found.sorted { $0.newFraction > $1.newFraction }
    }

    private func loop(from home: Coord, bearing: Double, target: CLLocationDistance) async throws -> PlannedLoop? {
        let spread = 35.0
        var radius = target / ((2 + 2 * sin(spread * .pi / 180)) * Self.detour)
        var best: PlannedLoop?
        var bestMiss = Double.infinity
        for _ in 0..<Self.fitPasses {
            let a = Geo.destination(from: home, bearing: bearing - spread, distance: radius)
            let b = Geo.destination(from: home, bearing: bearing + spread, distance: radius)
            guard let loop = try await build(home: home, through: [a, b], bearing: bearing) else { return best }
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
        let name = via.map { "\(direction), via \($0)" } ?? "\(direction) loop"
        return PlannedLoop(name: name, home: home, waypoints: waypoints, path: path, steps: steps,
                           segments: segments, distance: distance, duration: distance / metresPerSecond)
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
        let points = reports.flatMap(\.path)
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
