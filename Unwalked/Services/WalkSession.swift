import CoreLocation
import Foundation
import Observation

/// Follows the walker round a planned loop: turn guidance, off-route and running-late checks,
/// and the cues, watch and Live Activity that go with them.
@Observable
final class WalkSession {
    struct OffRoute: Equatable {
        /// The street they should have turned onto.
        var street: String
        var metresBehind: CLLocationDistance
        var minutesLate: Int
    }

    struct LateOffer: Equatable {
        var minutesLate: Int
        var shortcut: PlannedLoop
        /// True when the shortcut goes through a park or path, as in the design copy.
        var summary: String
    }

    /// The loop as planned, used for new-street counts at the end.
    let plannedLoop: PlannedLoop
    /// The route being followed now. Changes on a shortcut, heading home or a reroute.
    private(set) var route: PlannedLoop
    let plannedMinutes: Int
    let startDate = Date()

    private(set) var trail: [Coord] = []
    private(set) var walkedDistance: CLLocationDistance = 0
    private(set) var here: Coord?

    private(set) var progressIndex = 0
    private(set) var stepIndex = 0
    private(set) var metresToTurn: CLLocationDistance = 0
    private(set) var remainingDistance: CLLocationDistance
    private(set) var offRoute: OffRoute?
    private(set) var lateOffer: LateOffer?
    private(set) var isHeadingHome = false
    private(set) var isRerouting = false

    private let library: WalkLibrary
    private let cues = CuePlayer()
    private let watch: WatchBridge
    private let activity = LiveActivityController()
    private var offRouteStrikes = 0
    private var cuedSteps: Set<Int> = []
    private var lateDismissedAt: Int?
    private var lastFixDate = Date()
    private var isFindingShortcut = false

    init(loop: PlannedLoop, plannedMinutes: Int, library: WalkLibrary, watch: WatchBridge) {
        plannedLoop = loop
        route = loop
        self.plannedMinutes = plannedMinutes
        self.library = library
        self.watch = watch
        remainingDistance = loop.distance
        stepIndex = loop.steps.firstIndex { $0.pathIndex > 0 } ?? 0
        metresToTurn = alongPath(from: 0, to: nextStep?.pathIndex ?? 0)
    }

    // MARK: Derived

    var nextStep: TurnStep? { route.steps.indices.contains(stepIndex) ? route.steps[stepIndex] : nil }

    /// Walking speed: the learned pace, nudged towards today's pace once there's enough to go on.
    var metresPerSecond: Double {
        let learned = library.metresPerSecond
        let elapsed = Date().timeIntervalSince(startDate)
        guard walkedDistance > 400, elapsed > 300 else { return learned }
        let today = walkedDistance / elapsed
        return (learned + today) / 2
    }

    var minutesLeft: Int { max(0, Int((remainingDistance / metresPerSecond / 60).rounded())) }

    /// Positive when the walker will be home after the time they asked for.
    var minutesLate: Int {
        let plannedEnd = startDate.addingTimeInterval(Double(plannedMinutes) * 60)
        let projected = Date().addingTimeInterval(remainingDistance / metresPerSecond)
        return Int((projected.timeIntervalSince(plannedEnd) / 60).rounded())
    }

    var progress: Double {
        guard route.distance > 0 else { return 0 }
        return min(1, max(0, 1 - remainingDistance / route.distance))
    }

    var statusLine: String {
        if let offRoute { return "\(offRoute.minutesLate) min late" }
        let late = minutesLate
        if late >= 2 { return lateOffer != nil ? "\(late) min late at this pace" : "\(late) min late" }
        if late <= -3 { return "\(-late) min early" }
        return "On time"
    }

    var headline: String {
        if offRoute != nil { return "Turn round" }
        guard let step = nextStep else { return "Nearly home" }
        if step.kind == .arrive { return "Home in \(Format.distance(metresToTurn))" }
        if step.kind == .straight { return "Straight on for \(Format.distance(metresToTurn))" }
        return "\(step.kind.verb) in \(Format.distance(metresToTurn))"
    }

    var detail: String {
        if let offRoute { return "\(offRoute.street) is \(Format.distance(offRoute.metresBehind)) behind you" }
        guard let step = nextStep else { return "back to your door" }
        if step.kind == .arrive { return "back to your door" }
        return step.street.map { "onto \($0)" } ?? "at the next corner"
    }

    var symbol: String { offRoute != nil ? TurnKind.uTurn.symbol : (nextStep?.kind.symbol ?? TurnKind.arrive.symbol) }

    /// Rest of the route still to walk.
    var pathAhead: [Coord] {
        guard !route.path.isEmpty else { return [] }
        let i = min(progressIndex, route.path.count - 1)
        return (here.map { [$0] } ?? []) + route.path[(i + 1)...]
    }

    /// New-to-you parts of the route still ahead.
    var newAhead: [[Coord]] {
        route.segments.filter(\.isNew).compactMap { seg in
            let remaining = seg.path.filter { c in
                Geo.nearest(to: c, on: route.path, from: progressIndex).distance < 5
            }
            return remaining.count > 1 ? remaining : nil
        }
    }

    // MARK: Lifecycle

    func begin() {
        activity.start(loopName: route.name, state: activityState)
        publish(cue: nil)
    }

    func update(with location: CLLocation) {
        let point = Coord(location.coordinate)
        if let last = trail.last {
            let step = last.distance(to: point)
            guard step >= 4 else { return }
            walkedDistance += step
        }
        trail.append(point)
        here = point
        lastFixDate = .now

        // Look ahead along the route only, so a loop that ends at its start doesn't jump to the finish.
        let window = Array(route.path.prefix(min(route.path.count, progressIndex + 200)))
        let near = Geo.nearest(to: point, on: window, from: max(0, progressIndex - 3))

        if near.distance > 35 {
            offRouteStrikes += 1
            if offRouteStrikes >= 2 {
                let firstTime = offRoute == nil
                let extra = (near.distance * 2) / metresPerSecond / 60
                offRoute = OffRoute(street: nextStep?.street ?? "Your loop",
                                    metresBehind: near.distance,
                                    minutesLate: max(1, Int(extra.rounded())))
                if firstTime { publish(cue: .offLoop); cues.play(.offLoop); return }
            }
        } else {
            offRouteStrikes = 0
            offRoute = nil
            progressIndex = max(progressIndex, near.index)
        }

        advanceStep()
        let next = min(progressIndex + 1, route.path.count - 1)
        remainingDistance = point.distance(to: route.path[next]) + alongPath(from: next, to: route.path.count - 1)
        if let step = nextStep {
            metresToTurn = point.distance(to: route.path[next]) + alongPath(from: next, to: max(next, step.pathIndex))
        }

        var cue: WatchMessage.Cue?
        if let step = nextStep, metresToTurn <= 28, !cuedSteps.contains(stepIndex) {
            cuedSteps.insert(stepIndex)
            switch step.kind {
            case .left, .slightLeft: cue = .left
            case .right, .slightRight: cue = .right
            default: break
            }
        }
        checkLate()
        if let cue { cues.play(cue) }
        publish(cue: cue)
    }

    private func advanceStep() {
        while let step = nextStep, step.pathIndex <= progressIndex, stepIndex < route.steps.count - 1 {
            stepIndex += 1
        }
    }

    // MARK: Running late

    /// Offers a shortcut once the walker is 5 minutes behind, and again for each 5 more.
    private func checkLate() {
        let late = minutesLate
        guard late >= 5, lateOffer == nil, !isHeadingHome, offRoute == nil, !isFindingShortcut else { return }
        if let dismissed = lateDismissedAt, late < dismissed + 5 { return }
        guard let here else { return }
        isFindingShortcut = true
        Task { @MainActor in
            defer { isFindingShortcut = false }
            let planner = LoopPlanner(coverage: library.coverage, reports: library.reports, metresPerSecond: metresPerSecond)
            guard let shortcut = try? await planner.shortcutHome(from: here, home: route.home),
                  shortcut.distance < remainingDistance * 0.85 else { return }
            let via = shortcut.segments.compactMap(\.street).first
            lateOffer = LateOffer(
                minutesLate: late,
                shortcut: shortcut,
                summary: via.map { "Going back along \($0) gets you home on time." } ?? "A shorter way home gets you back on time."
            )
            cues.play(.late)
            publish(cue: .late)
        }
    }

    func takeShortcut() {
        guard let offer = lateOffer else { return }
        switchRoute(to: offer.shortcut)
        lateOffer = nil
        isHeadingHome = true
    }

    func keepLoop() {
        lateDismissedAt = lateOffer?.minutesLate
        lateOffer = nil
    }

    /// The house button: go straight home by the shortest way.
    func headHome() async {
        guard let here, !isHeadingHome else { return }
        isRerouting = true
        defer { isRerouting = false }
        let planner = LoopPlanner(coverage: library.coverage, reports: library.reports, metresPerSecond: metresPerSecond)
        if let shortcut = try? await planner.shortcutHome(from: here, home: route.home) {
            switchRoute(to: shortcut)
            isHeadingHome = true
            lateOffer = nil
        }
    }

    // MARK: Reports

    /// The stretch just ahead: from here to the next turn, at most 150 m.
    var stretchAhead: [Coord] {
        guard !route.path.isEmpty else { return [] }
        let start = min(progressIndex, route.path.count - 1)
        let end = min(route.path.count - 1, max(start + 1, nextStep?.pathIndex ?? start + 1))
        var out: [Coord] = here.map { [$0] } ?? [route.path[start]]
        guard end > start else { return out + [route.path[end]] }
        var length: CLLocationDistance = 0
        for i in (start + 1)...end {
            length += out.last!.distance(to: route.path[i])
            out.append(route.path[i])
            if length > 150 { break }
        }
        return out
    }

    /// Saves the report and plans round it to the remaining turning points.
    func report(_ reason: ReportReason) async {
        let stretch = stretchAhead
        library.report(StreetReport(path: stretch, reason: reason))
        guard let here else { return }
        isRerouting = true
        defer { isRerouting = false }
        let remainingWaypoints = route.waypoints.filter { wp in
            Geo.nearest(to: wp, on: route.path).index > progressIndex
        }
        let planner = LoopPlanner(coverage: library.coverage, reports: library.reports, metresPerSecond: metresPerSecond)
        if let rerouted = try? await planner.build(home: route.home, from: here, through: remainingWaypoints) {
            switchRoute(to: rerouted)
        }
    }

    private func switchRoute(to new: PlannedLoop) {
        var new = new
        new.name = route.name
        route = new
        progressIndex = 0
        stepIndex = new.steps.firstIndex { $0.pathIndex > 0 } ?? 0
        cuedSteps = []
        offRoute = nil
        offRouteStrikes = 0
        remainingDistance = new.distance
        metresToTurn = alongPath(from: 0, to: nextStep?.pathIndex ?? 0)
        publish(cue: nil)
    }

    // MARK: Finish

    func finish() -> WalkSummary {
        activity.end()
        watch.send(.idle)
        let path = trail.count > 1 ? trail : Array(route.path.prefix(progressIndex + 1))
        var walkedToday = Coverage()
        walkedToday.mark(path)
        let newSegments = plannedLoop.segments.filter { $0.isNew && walkedToday.walkedFraction(of: $0.path) > 0.6 }
        let newStreets = Set(newSegments.enumerated().map { $0.element.street ?? "segment-\($0.offset)" }).count
        let distance = max(walkedDistance, Geo.length(of: path))
        let newDistance = newSegments.reduce(0) { $0 + $1.length }

        let before = library.coverageFraction
        let record = WalkRecord(date: startDate, duration: Date().timeIntervalSince(startDate), distance: distance,
                                path: path, newStreets: newStreets,
                                newFraction: distance > 0 ? min(1, newDistance / distance) : 0)
        library.record(record)
        return WalkSummary(record: record, newSegments: newSegments.map(\.path),
                           coverageBefore: before, coverageAfter: library.coverageFraction)
    }

    func cancel() {
        activity.end()
        watch.send(.idle)
    }

    // MARK: Output

    private var activityState: WalkActivityAttributes.ContentState {
        .init(symbol: symbol, headline: headline, detail: detail,
              shortDistance: offRoute.map { Format.distance($0.metresBehind) } ?? Format.distance(metresToTurn),
              minutesLeft: minutesLeft, progress: progress, status: statusLine)
    }

    private func publish(cue: WatchMessage.Cue?) {
        activity.update(activityState)
        let instruction: String
        if let offRoute {
            instruction = "Back to \(offRoute.street)"
        } else if let step = nextStep {
            instruction = [step.kind.verb, step.street.map { "onto \($0)" }].compactMap { $0 }.joined(separator: " ")
        } else {
            instruction = "Home"
        }
        watch.send(WatchMessage(
            active: true, symbol: symbol,
            distance: Format.distance(offRoute?.metresBehind ?? metresToTurn),
            metresToTurn: offRoute != nil ? 0 : metresToTurn,
            instruction: instruction, minutesLeft: minutesLeft, progress: progress,
            newStreets: newStreetsSoFar, cue: cue
        ))
    }

    /// New streets the walker has already passed along today.
    var newStreetsSoFar: Int {
        var count = 0
        var seen = Set<String>()
        for (i, seg) in plannedLoop.segments.enumerated() where seg.isNew {
            guard let end = seg.path.last else { continue }
            let key = seg.street ?? "segment-\(i)"
            if trail.contains(where: { $0.distance(to: end) < 20 }), !seen.contains(key) {
                seen.insert(key)
                count += 1
            }
        }
        return count
    }

    private func alongPath(from a: Int, to b: Int) -> CLLocationDistance {
        guard a < b, b < route.path.count else { return 0 }
        var total: CLLocationDistance = 0
        for i in a..<b { total += route.path[i].distance(to: route.path[i + 1]) }
        return total
    }
}
