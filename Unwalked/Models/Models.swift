import CoreLocation
import Foundation

/// Codable stand-in for `CLLocationCoordinate2D`.
struct Coord: Codable, Hashable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    init(_ c: CLLocationCoordinate2D) { lat = c.latitude; lon = c.longitude }

    var cl: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var location: CLLocation { .init(latitude: lat, longitude: lon) }

    func distance(to other: Coord) -> CLLocationDistance { location.distance(from: other.location) }
}

enum Pace: String, Codable, CaseIterable, Identifiable {
    case easy, normal, brisk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .easy: "Easy"
        case .normal: "Normal"
        case .brisk: "Brisk"
        }
    }

    var detail: String {
        switch self {
        case .easy: "A stroll, about 4 km/h"
        case .normal: "Steady, about 4.8 km/h"
        case .brisk: "Purposeful, about 5.6 km/h"
        }
    }

    var kmPerHour: Double {
        switch self {
        case .easy: 4.0
        case .normal: 4.8
        case .brisk: 5.6
        }
    }
}

struct HomeArea: Codable, Equatable {
    var center: Coord
    /// Radius of the home-area circle in metres.
    var radius: CLLocationDistance = 900

    static let minRadius: CLLocationDistance = 400
    static let maxRadius: CLLocationDistance = 3000

    var areaKm2: Double { .pi * pow(radius / 1000, 2) }

    /// Rough street count for the onboarding copy, until real street data is wired in.
    /// Assumes about 15 km of street per km² and 150 m per street, typical for UK towns.
    var estimatedStreetCount: Int { max(1, Int((areaKm2 * 15_000 / 150).rounded())) }
}

enum TurnKind: String, Codable {
    case left, right, slightLeft, slightRight, straight, uTurn, arrive

    var symbol: String {
        switch self {
        case .left: "arrow.turn.up.left"
        case .right: "arrow.turn.up.right"
        case .slightLeft: "arrow.up.left"
        case .slightRight: "arrow.up.right"
        case .straight: "arrow.up"
        case .uTurn: "arrow.uturn.down"
        case .arrive: "house.fill"
        }
    }

    var verb: String {
        switch self {
        case .left, .slightLeft: "Left"
        case .right, .slightRight: "Right"
        case .straight: "Straight on"
        case .uTurn: "Turn round"
        case .arrive: "Home"
        }
    }

    /// Guesses the turn from Apple's step instruction text ("Turn right onto Mill Lane").
    static func from(instructions: String) -> TurnKind {
        let s = instructions.lowercased()
        if s.contains("arrive") || s.contains("destination") { return .arrive }
        if s.contains("u-turn") || s.contains("turn around") { return .uTurn }
        if s.contains("slight left") || s.contains("bear left") || s.contains("keep left") { return .slightLeft }
        if s.contains("slight right") || s.contains("bear right") || s.contains("keep right") { return .slightRight }
        if s.contains("left") { return .left }
        if s.contains("right") { return .right }
        return .straight
    }
}

struct TurnStep: Codable, Hashable {
    var kind: TurnKind
    /// Street the walker turns onto, if known.
    var street: String?
    /// Where the turn happens.
    var at: Coord
    /// Index into the loop's `path` of the turn point.
    var pathIndex: Int
}

/// One stretch of the loop between two turns, flagged new if the walker has not walked it before.
struct LoopSegment: Codable, Hashable {
    var path: [Coord]
    var street: String?
    var isNew: Bool
    var length: CLLocationDistance
}

struct PlannedLoop: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Start and end of the loop.
    var home: Coord
    /// The turning points the loop was planned through, in order.
    var waypoints: [Coord]
    var path: [Coord]
    var steps: [TurnStep]
    var segments: [LoopSegment]
    var distance: CLLocationDistance
    /// Planned duration at the walker's pace, in seconds.
    var duration: TimeInterval

    var newDistance: CLLocationDistance { segments.filter(\.isNew).reduce(0) { $0 + $1.length } }
    var newFraction: Double { distance > 0 ? newDistance / distance : 0 }
    var newStreetCount: Int { Set(segments.filter(\.isNew).compactMap(\.street)).count }

    var minutes: Int { Int((duration / 60).rounded()) }
    var metaLine: String { "\(minutes) min · \(Format.km(distance))" }
}

enum ReportReason: String, Codable, CaseIterable, Identifiable {
    case blocked, privateWay, unsafe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blocked: "Blocked or closed"
        case .privateWay: "Private, no way through"
        case .unsafe: "Feels unsafe"
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "nosign"
        case .privateWay: "lock"
        case .unsafe: "exclamationmark.triangle"
        }
    }
}

struct StreetReport: Codable, Hashable {
    var path: [Coord]
    var reason: ReportReason
    var date: Date = .now
}

/// The walker's verdict on a finished loop.
enum LoopRating: String, Codable {
    case good, bad
}

struct WalkRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var duration: TimeInterval
    var distance: CLLocationDistance
    var path: [Coord]
    var newStreets: Int
    var newFraction: Double
    /// Minutes the walker asked for, to check loops fit the time.
    var plannedMinutes: Int?
    var rating: LoopRating?
}

/// What the Walk complete screen shows.
struct WalkSummary: Hashable {
    var record: WalkRecord
    var newSegments: [[Coord]]
    var coverageBefore: Double
    var coverageAfter: Double
}

enum Format {
    static func km(_ metres: CLLocationDistance) -> String {
        String(format: "%.1f km", metres / 1000)
    }

    /// "110 m", rounded to 10 m, or "1.2 km" past a kilometre.
    static func distance(_ metres: CLLocationDistance) -> String {
        if metres >= 1000 { return km(metres) }
        return "\(max(10, Int((metres / 10).rounded()) * 10)) m"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
