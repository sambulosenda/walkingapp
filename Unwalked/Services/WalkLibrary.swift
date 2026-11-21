import CoreLocation
import Foundation
import Observation

/// Everything Unwalked remembers. Saved as JSON on the phone; nothing leaves the device.
@Observable
final class WalkLibrary {
    struct Snapshot: Codable {
        var onboarded = false
        var pace: Pace = .normal
        var homeArea: HomeArea?
        var walks: [WalkRecord] = []
        var reports: [StreetReport] = []
        var coverage = Coverage()
        /// Free loops started, keyed by the Monday that starts their week.
        var freeLoopsByWeek: [String: Int] = [:]
    }

    private(set) var data: Snapshot
    private let url: URL

    /// Walks brought in from Apple Health (F14). In a file of their own: a new field in `Snapshot`
    /// would make every existing save fail to decode, and the fallback is an empty library.
    private(set) var imported: [ImportedWalk] = []
    private var importedURL: URL { url.deletingLastPathComponent().appendingPathComponent("unwalked-imported.json") }

    /// The streets around home, once downloaded. Not saved here; `StreetStore` keeps its own copy.
    @ObservationIgnored var streets: StreetGraph? { didSet { measureCoverage() } }
    /// Walked street length over all street length in the home area, when street data is in.
    private var streetCoverage: Double?
    /// Named streets in the home area, when street data is in.
    private(set) var streetCount: Int?
    /// Streets in the home area walked end to end, when street data is in.
    private(set) var completedStreets: Set<String> = []

    private func measureCoverage() {
        guard let streets, let area = data.homeArea else { streetCoverage = nil; streetCount = nil; completedStreets = []; return }
        completedStreets = streets.completedStreets(in: data.coverage, area: area)
        streetCoverage = streets.coverage(of: data.coverage, in: area)
        streetCount = streets.streetCount(in: area)
    }

    static let freeLoopsPerWeek = 2

    init(url: URL = WalkLibrary.defaultURL) {
        self.url = url
        if let raw = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(Snapshot.self, from: raw) {
            data = snap
        } else {
            data = Snapshot()
        }
        if let raw = try? Data(contentsOf: importedURL), let saved = try? JSONDecoder().decode([ImportedWalk].self, from: raw) {
            imported = saved
        }
    }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("unwalked.json")
    }

    private func save() {
        do {
            let raw = try JSONEncoder().encode(data)
            try raw.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            assertionFailure("Could not save walks: \(error)")
        }
    }

    // MARK: Settings

    var onboarded: Bool { data.onboarded }
    var pace: Pace { data.pace }
    var homeArea: HomeArea? { data.homeArea }

    func finishOnboarding() { data.onboarded = true; save() }
    func setPace(_ pace: Pace) { data.pace = pace; save() }
    func setHomeArea(_ area: HomeArea) { data.homeArea = area; save(); measureCoverage() }

    // MARK: Walks

    var walks: [WalkRecord] { data.walks }

    /// Every path to draw as walked: Unwalked's own walks, then those brought in from Apple Health.
    var walkedPaths: [[Coord]] { data.walks.map(\.path) + imported.map(\.path) }

    /// Adds walks from Apple Health: they colour the map and count towards coverage, but not towards
    /// the learned pace or the walk count, which are about walks made with Unwalked.
    func addImported(_ walks: [ImportedWalk]) {
        guard !walks.isEmpty else { return }
        imported += walks
        for walk in walks { data.coverage.mark(walk.path) }
        if let raw = try? JSONEncoder().encode(imported) {
            try? raw.write(to: importedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        save()
        measureCoverage()
    }
    var hasWalked: Bool { !data.walks.isEmpty }
    var coverage: Coverage { data.coverage }

    var coverageFraction: Double {
        guard let area = data.homeArea else { return 0 }
        // Real streets when they are in; an estimate of street length until then.
        return streetCoverage ?? data.coverage.fraction(in: area)
    }

    func record(_ walk: WalkRecord) {
        data.walks.append(walk)
        data.coverage.mark(walk.path)
        save()
        measureCoverage()
    }

    func rate(_ walkID: WalkRecord.ID, _ rating: LoopRating?) {
        guard let i = data.walks.firstIndex(where: { $0.id == walkID }) else { return }
        data.walks[i].rating = rating
        save()
    }

    /// Where Apple Health's walking speed is kept, in km/h. In defaults, not in `Snapshot`: a new field
    /// there would make every existing save fail to decode.
    static let healthSpeedKey = "healthWalkingSpeedKmh"

    /// Walking speed from Apple Health, when the walker has let Unwalked read it.
    var healthSpeedKmh: Double? {
        let saved = UserDefaults.standard.double(forKey: Self.healthSpeedKey)
        return saved > 0 ? saved : nil
    }

    /// Learned walking speed in km/h, from the last five walks of ten minutes or more.
    /// Until there are two, Apple Health's walking speed, and failing that the pace set in Settings.
    var speedKmh: Double {
        let recent = data.walks.suffix(5).filter { $0.duration >= 600 && $0.distance > 300 }
        guard recent.count >= 2 else { return healthSpeedKmh ?? data.pace.kmPerHour }
        let km = recent.reduce(0) { $0 + $1.distance } / 1000
        let hours = recent.reduce(0) { $0 + $1.duration } / 3600
        return min(7, max(3, km / hours))
    }

    var metresPerSecond: Double { speedKmh / 3.6 }

    // MARK: Milestones

    /// Kilometres walked with Unwalked.
    var totalKm: Double { data.walks.reduce(0) { $0 + $1.distance } / 1000 }

    var milestones: [Milestone] {
        Milestones.earned(streets: completedStreets.count, coverage: coverageFraction, km: totalKm)
    }

    var nextMilestones: [String] {
        Milestones.next(streets: completedStreets.count, coverage: coverageFraction, km: totalKm)
    }

    // MARK: Reports

    var reports: [StreetReport] { data.reports }

    func report(_ report: StreetReport) {
        // The same stretch reported twice in a few seconds is one report delivered twice.
        if let last = data.reports.last, last.reason == report.reason, last.path == report.path,
           report.date.timeIntervalSince(last.date) < 30 { return }
        data.reports.append(report)
        save()
    }

    // MARK: Free loops

    static func weekKey(for date: Date = .now) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let monday = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return ISO8601DateFormatter.string(from: monday, timeZone: .current, formatOptions: [.withFullDate])
    }

    var freeLoopsLeft: Int {
        max(0, Self.freeLoopsPerWeek - (data.freeLoopsByWeek[Self.weekKey()] ?? 0))
    }

    func useFreeLoop() {
        data.freeLoopsByWeek[Self.weekKey(), default: 0] += 1
        save()
    }

    func reset() {
        data = Snapshot()
        imported = []
        try? FileManager.default.removeItem(at: importedURL)
        save()
        measureCoverage()
    }
}
