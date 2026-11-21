import CoreLocation
import Foundation
import Observation

@Observable
final class AppModel {
    enum Screen: Equatable {
        case onboarding
        case home
        case loops
        case walking
        case complete(WalkSummary)
    }

    let library: WalkLibrary
    let location: LocationService
    let purchases: Purchases
    let watch = WatchBridge()
    let streets = StreetStore()

    var screen: Screen
    var onboardingStep = 1

    /// "How long have you got?"
    var minutes = 40
    static let minuteRange = 15...120

    var loops: [PlannedLoop] = []
    var selectedLoopID: PlannedLoop.ID?
    var isPlanning = false
    var planError: String?
    private var rotation = 0.0

    private(set) var session: WalkSession?
    var showPaywall = false
    var showSettings = false
    var showReport = false

    /// The DEBUG walk simulator, when running with `-simulateWalk`.
    @ObservationIgnored private var simulator: AnyObject?

    init(library: WalkLibrary = WalkLibrary(), location: LocationService = LocationService(), purchases: Purchases = Purchases()) {
        self.library = library
        self.location = location
        self.purchases = purchases
        screen = library.onboarded && library.homeArea != nil ? .home : .onboarding
        LiveActivityController.endLeftovers()
        Task { await loadStreets() }
    }

    // MARK: Streets

    /// Fetches the streets needed for a loop of the chosen length, or reads them from the phone.
    @MainActor
    @discardableResult
    func loadStreets(patience: StreetStore.Patience = .patient) async -> StreetGraph? {
        guard let area = library.homeArea else { return nil }
        let reach = StreetStore.reach(minutes: minutes, metresPerSecond: library.metresPerSecond)
        let graph = await streets.graph(around: area.center, radius: max(reach, area.radius), patience: patience)
        if let graph, library.streets !== graph { library.streets = graph }
        return graph
    }

    // MARK: Derived

    var selectedLoop: PlannedLoop? { loops.first { $0.id == selectedLoopID } ?? loops.first }

    /// Distance the walker covers in the chosen time at their pace.
    var estimatedKm: Double { Double(minutes) / 60 * library.speedKmh }

    var home: Coord? { library.homeArea?.center ?? location.location.map { Coord($0.coordinate) } }

    var isAfterDark: Bool {
        guard let c = home else { return false }
        return SunClock.isDark(lat: c.lat, lon: c.lon)
    }

    var canStartLoop: Bool {
        #if DEBUG
        // UI tests walk more loops in a week than the free plan allows.
        if ProcessInfo.processInfo.arguments.contains("-unlimitedLoops") { return true }
        #endif
        return purchases.hasPlus || library.freeLoopsLeft > 0
    }

    // MARK: Onboarding

    func finishOnboarding(area: HomeArea) {
        library.setHomeArea(area)
        library.finishOnboarding()
        screen = .home
        Task { await loadStreets() }
    }

    // MARK: Time

    func stepMinutes(by delta: Int) {
        minutes = min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, minutes + delta))
    }

    // MARK: Loops

    func findLoops() {
        guard canStartLoop else { showPaywall = true; return }
        screen = .loops
        Task { await planLoops() }
    }

    /// The refresh button on Loop options: three more loops in other directions.
    func shuffleLoops() {
        rotation += 45
        Task { await planLoops() }
    }

    @MainActor
    func planLoops() async {
        guard let home else { planError = "Turn on location to plan a loop from your door."; return }
        isPlanning = true
        planError = nil
        defer { isPlanning = false }
        // Loops start from the home area's centre, so the same streets serve every plan.
        // If the streets are not on the phone within a few seconds, plan this one with Apple's directions
        // and keep downloading for next time.
        let graph = library.homeArea?.center == home ? await loadStreets(patience: .brief) : nil
        if graph == nil { Task { await loadStreets() } }
        let planner = LoopPlanner(coverage: library.coverage, reports: library.reports,
                                  metresPerSecond: library.metresPerSecond, streets: graph, prefersLit: isAfterDark)
        do {
            loops = try await planner.loops(from: home, minutes: minutes, rotation: rotation)
            selectedLoopID = loops.first?.id
        } catch {
            loops = []
            planError = error.localizedDescription
        }
    }

    // MARK: Walking

    func startWalk() {
        guard let loop = selectedLoop else { return }
        guard canStartLoop else { showPaywall = true; return }
        if !purchases.hasPlus { library.useFreeLoop() }

        let session = WalkSession(loop: loop, plannedMinutes: minutes, library: library, watch: watch)
        self.session = session
        location.onUpdate = { [weak session] fix in session?.update(with: fix) }
        location.startWalking()
        session.begin()
        screen = .walking

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-simulateWalk") {
            let sim = WalkSimulator(session: session)
            sim.start()
            simulator = sim
        }
        #endif
    }

    func endWalk() {
        guard let session else { return }
        #if DEBUG
        (simulator as? WalkSimulator)?.stop()
        #endif
        simulator = nil
        location.onUpdate = nil
        location.stopWalking()
        let summary = session.finish()
        self.session = nil
        loops = []
        screen = .complete(summary)
    }

    func done() {
        screen = .home
    }
}

#if DEBUG
/// Walks the route at 5x speed, for trying the app in the Simulator. Launch with `-simulateWalk`.
final class WalkSimulator {
    private weak var session: WalkSession?
    private var timer: Timer?
    private var travelled: CLLocationDistance = 0
    private var routeID: UUID?

    init(session: WalkSession) { self.session = session }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() { timer?.invalidate() }

    private func tick() {
        guard let session else { return stop() }
        if routeID != session.route.id { routeID = session.route.id; travelled = 0 }
        travelled += session.metresPerSecond * 5
        let path = session.route.path
        var acc: CLLocationDistance = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let d = a.distance(to: b)
            if acc + d >= travelled {
                let t = d > 0 ? (travelled - acc) / d : 0
                let c = CLLocationCoordinate2D(latitude: a.lat + (b.lat - a.lat) * t, longitude: a.lon + (b.lon - a.lon) * t)
                session.update(with: CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now))
                return
            }
            acc += d
        }
        stop()
    }
}
#endif
