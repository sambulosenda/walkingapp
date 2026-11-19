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

    /// The streets around home, once downloaded. Not saved here; `StreetStore` keeps its own copy.
    @ObservationIgnored var streets: StreetGraph? { didSet { measureCoverage() } }
    /// Walked street length over all street length in the home area, when street data is in.
    private var streetCoverage: Double?
    /// Named streets in the home area, when street data is in.
    private(set) var streetCount: Int?

    private func measureCoverage() {
        guard let streets, let area = data.homeArea else { streetCoverage = nil; streetCount = nil; return }
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

    /// Learned walking speed in km/h, from the last five walks of ten minutes or more.
    /// Falls back to the pace picked in onboarding.
    var speedKmh: Double {
        let recent = data.walks.suffix(5).filter { $0.duration >= 600 && $0.distance > 300 }
        guard recent.count >= 2 else { return data.pace.kmPerHour }
        let km = recent.reduce(0) { $0 + $1.distance } / 1000
        let hours = recent.reduce(0) { $0 + $1.duration } / 3600
        return min(7, max(3, km / hours))
    }

    var metresPerSecond: Double { speedKmh / 3.6 }

    // MARK: Reports

    var reports: [StreetReport] { data.reports }

    func report(_ report: StreetReport) {
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
        save()
        measureCoverage()
    }
}
