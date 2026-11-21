import CoreLocation
import Foundation
import Observation

@Observable
final class AppModel {
    /// The running app's model, for App Intents, which Siri and Shortcuts create outside SwiftUI.
    static weak var current: AppModel?

    enum Screen: Equatable {
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
    let reports = ReportOutbox()
    let health = HealthLink()

    var screen: Screen = .home
    /// True while the first loop waits for the walker's answer about location, and for a fix.
    private(set) var isLocating = false
    /// True once location has been refused, so Home can say what to do about it.
    private(set) var locationRefused = false

    /// "How long have you got?"
    var minutes = 40
    static let minuteRange = 15...120

    var loops: [PlannedLoop] = []
    var selectedLoopID: PlannedLoop.ID?
    var isPlanning = false
    var planError: String?
    private var rotation = 0.0

    /// Route preferences as the walker set them (F12). What the router applies also depends on the
    /// hour and on their plan: see `appliedPreferences`.
    private(set) var preferences = RoutePreferences.load()

    /// A place the next loops should pass on the way (F16). Cleared when the walk starts.
    private(set) var via: ViaPoint?

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
        LiveActivityController.endLeftovers()
        Task { await loadStreets() }
        Self.current = self
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

    var appliedPreferences: RoutePreferences {
        preferences.applied(afterDark: isAfterDark, hasPlus: purchases.hasPlus)
    }

    /// Flips one preference and plans again, so the loops on screen change with it.
    /// Quiet, green and step-free belong to Plus; lighting is for everyone.
    func togglePreference(_ preference: WritableKeyPath<RoutePreferences, Bool>) {
        if preference != \.lit, !purchases.hasPlus { showPaywall = true; return }
        preferences[keyPath: preference].toggle()
        preferences.save()
        if screen == .loops { Task { await planLoops() } }
    }

    func setVia(_ place: ViaPoint?) {
        via = place
        if screen == .loops { Task { await planLoops() } }
    }

    var canStartLoop: Bool {
        #if DEBUG
        // UI tests walk more loops in a week than the free plan allows.
        if ProcessInfo.processInfo.arguments.contains("-unlimitedLoops") { return true }
        #endif
        return purchases.hasPlus || library.freeLoopsLeft > 0
    }

    // MARK: Onboarding

    /// There is no onboarding. The first loop asks for location there and then, when the reason is on
    /// screen, and where the walker is standing becomes home. It can be moved in Settings.
    @MainActor
    func ensureHome() async -> Bool {
        if library.homeArea != nil { return true }
        isLocating = true
        defer { isLocating = false }
        if location.authorization == .notDetermined {
            location.requestPermission()
            // Wait for the answer to the system's question, a minute at most.
            for _ in 0..<600 where location.authorization == .notDetermined {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard location.isAuthorized, let fix = await location.currentLocation() else {
            locationRefused = !location.isAuthorized
            return false
        }
        locationRefused = false
        library.setHomeArea(HomeArea(center: Coord(fix.coordinate)))
        library.finishOnboarding()
        return true
    }

    // MARK: Time

    func stepMinutes(by delta: Int) {
        minutes = min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, minutes + delta))
    }

    // MARK: Loops

    func findLoops() {
        guard canStartLoop else { showPaywall = true; return }
        Task { @MainActor in
            guard await ensureHome() else { return }
            screen = .loops
            await planLoops()
        }
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
                                  metresPerSecond: library.metresPerSecond, streets: graph, preferences: appliedPreferences)
        do {
            loops = try await planner.loops(from: home, minutes: minutes, rotation: rotation, via: via)
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

        let session = WalkSession(loop: loop, plannedMinutes: minutes, library: library, watch: watch,
                                  reports: reports, preferences: appliedPreferences)
        self.session = session
        via = nil
        location.onUpdate = { [weak session] fix in session?.update(with: fix) }
        location.startWalking()
        watch.wakeWatch()
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

    /// Plans a loop for `minutes` and starts the best one, for Siri and Shortcuts.
    /// Returns what to say back.
    @MainActor
    func startLoop(minutes asked: Int) async -> String {
        guard session == nil else { return "You're already on a walk." }
        guard await ensureHome() else { return "Unwalked needs your location to plan a loop. Open it and allow location." }
        guard canStartLoop else {
            showPaywall = true
            return "You've used this week's free loops."
        }
        minutes = min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, asked))
        screen = .loops
        await planLoops()
        guard let loop = loops.first else { return planError ?? "Couldn't find a loop from here." }
        selectedLoopID = loop.id
        startWalk()
        return "Starting \(loop.name). About \(loop.minutes) minutes."
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
        Task { await health.save(summary.record) }
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
        // Past the end: stand on the last point, or the walk stops a stride short of home and never arrives.
        if let last = path.last {
            session.update(with: CLLocation(coordinate: last.cl, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now))
        }
        stop()
    }
}
#endif
