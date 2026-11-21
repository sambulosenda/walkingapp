import Foundation

/// What a walker would rather their loops were like (F12).
///
/// Each one is a lean, not a promise: OpenStreetMap does not record every lamp or every flight of
/// steps, so loops prefer what it knows about and say what they found.
struct RoutePreferences: Codable, Equatable, Sendable {
    /// Keep off main roads, and off the paths that run right beside big ones.
    var quiet = false
    /// Go through parks, gardens, commons and woods where there are any.
    var green = false
    /// After dark, keep to streets known to be lit. On for everyone unless they turn it off.
    var lit = true
    /// Never use a flight of steps.
    var stepFree = false

    /// No leaning at all: plain shortest-and-newest routing.
    static let none = RoutePreferences(quiet: false, green: false, lit: false, stepFree: false)

    /// The preferences as the router should apply them right now. Lighting only matters after dark,
    /// and quiet, green and step-free belong to Unwalked Plus.
    func applied(afterDark: Bool, hasPlus: Bool) -> RoutePreferences {
        RoutePreferences(quiet: quiet && hasPlus, green: green && hasPlus,
                         lit: lit && afterDark, stepFree: stepFree && hasPlus)
    }

    private static let key = "routePreferences"

    static func load() -> RoutePreferences {
        guard let raw = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(RoutePreferences.self, from: raw) else { return RoutePreferences() }
        return saved
    }

    func save() {
        if let raw = try? JSONEncoder().encode(self) { UserDefaults.standard.set(raw, forKey: Self.key) }
    }
}
