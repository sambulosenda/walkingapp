import CoreLocation
import Foundation
import Observation

/// Sends street reports for review, and keeps the ones it could not send.
///
/// F8 asks that a reported street is both excluded from that walker's loops at once and queued
/// for review. The exclusion is `WalkLibrary.report`, on the phone. This is the queue.
///
/// A report says which street, in which tile, and why. The tile is the same 1.5 km square the
/// app already asks for street data in, so a report tells the server nothing more precise about
/// anyone than fetching the streets already did. There is no identifier, no device id and no
/// time of day — only the date, because a blockage may be temporary.
///
/// Reports are kept in their own file rather than in `WalkLibrary.Snapshot`: that snapshot is
/// decoded with `try?` and falls back to an empty one, so a new non-optional field in it would
/// quietly throw away every walk someone had recorded.
@Observable
final class ReportOutbox {
    struct Pending: Codable, Hashable, Identifiable {
        var id = UUID()
        var reason: ReportReason
        var street: String?
        var x: Int
        var y: Int
        var metres: Int
        var day: String

        enum CodingKeys: String, CodingKey { case id, reason, street, x, y, metres, day }

        /// What goes over the wire: the id stays on the phone.
        var body: [String: Any] {
            var out: [String: Any] = ["reason": reason.rawValue, "x": x, "y": y, "metres": metres, "day": day]
            if let street, !street.isEmpty { out["street"] = street }
            return out
        }
    }

    /// `ReportsURL` in Info.plist. Nil when no server is set, and then reports only ever stay
    /// on the phone: the walker's own loops avoid the street, but nobody reviews it.
    static let host: URL? = {
        guard let set = Bundle.main.object(forInfoDictionaryKey: "ReportsURL") as? String, !set.isEmpty
        else { return nil }
        return URL(string: set)
    }()

    private(set) var pending: [Pending] = []
    private let url: URL
    private var sending = false

    init(filename: String = "unwalked-reports.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)
        if let raw = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Pending].self, from: raw) {
            pending = saved
        }
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(pending) else { return }
        try? raw.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Describes a reported stretch by the street it runs along and the tile it sits in.
    static func describe(stretch: [Coord], on loop: PlannedLoop?, reason: ReportReason) -> Pending? {
        guard let first = stretch.first else { return nil }
        let tile = StreetTile(containing: first)
        var metres: CLLocationDistance = 0
        for i in stretch.indices.dropFirst() { metres += stretch[i - 1].distance(to: stretch[i]) }

        // The name of whichever planned segment runs closest to where the walker is standing.
        let street = loop?.segments
            .compactMap { segment -> (String, CLLocationDistance)? in
                guard let name = segment.street,
                      let nearest = segment.path.map({ $0.distance(to: first) }).min()
                else { return nil }
                return (name, nearest)
            }
            .min { $0.1 < $1.1 }
            .flatMap { $0.1 <= 40 ? $0.0 : nil }

        return Pending(reason: reason, street: street, x: tile.x, y: tile.y,
                       metres: Int(metres.rounded()), day: Self.today())
    }

    static func today(_ date: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @MainActor
    func add(_ report: Pending) {
        pending.append(report)
        save()
    }

    /// Sends everything waiting. Anything that does not go stays for the next try.
    @MainActor
    func flush() async {
        guard let host = Self.host, !pending.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for report in pending {
            guard let body = try? JSONSerialization.data(withJSONObject: report.body) else {
                pending.removeAll { $0.id == report.id }
                continue
            }
            var request = URLRequest(url: host)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { break } // No network: keep this and everything after it for later.

            // 4xx means this report will never be accepted, so stop carrying it around.
            if (200..<300).contains(http.statusCode) || (400..<500).contains(http.statusCode) {
                pending.removeAll { $0.id == report.id }
            } else {
                break
            }
        }
        save()
    }
}
