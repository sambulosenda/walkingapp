import CoreLocation
import Foundation

/// Tracks which bits of street the walker has covered as a set of ~20 m grid cells.
///
/// The grid is the record of where someone has walked, kept apart from the streets so it
/// survives the street data changing underneath it.
///
/// It does not know where streets are, so `fraction(in:)` can only divide by an estimate.
/// That is a fallback, used until the streets have downloaded: the percentage the app shows
/// comes from `StreetGraph.coverage(of:in:)`, which is walked street length over real street
/// length. See `WalkLibrary.coverageFraction`.
struct Coverage: Codable, Equatable {
    private(set) var cells: Set<Cell> = []

    struct Cell: Codable, Hashable {
        var x: Int32
        var y: Int32
    }

    static let latStep = 0.00018 // about 20 m
    static let lonStep = 0.00028 // about 20 m at UK latitudes

    static func cell(for c: Coord) -> Cell {
        Cell(x: Int32((c.lon / lonStep).rounded(.down)), y: Int32((c.lat / latStep).rounded(.down)))
    }

    static func center(of cell: Cell) -> Coord {
        Coord(lat: (Double(cell.y) + 0.5) * latStep, lon: (Double(cell.x) + 0.5) * lonStep)
    }

    /// True if this point, or a cell next to it, has been walked.
    func isWalked(_ c: Coord) -> Bool {
        let k = Self.cell(for: c)
        for dx in -1...1 {
            for dy in -1...1 where cells.contains(Cell(x: k.x + Int32(dx), y: k.y + Int32(dy))) {
                return true
            }
        }
        return false
    }

    /// Fraction of a path, by length, that has been walked before.
    func walkedFraction(of path: [Coord]) -> Double {
        let dense = Geo.densify(path, spacing: 10)
        guard !dense.isEmpty else { return 0 }
        return Double(dense.filter(isWalked).count) / Double(dense.count)
    }

    mutating func mark(_ path: [Coord]) {
        for c in Geo.densify(path, spacing: 10) { cells.insert(Self.cell(for: c)) }
    }

    func walkedCells(in area: HomeArea) -> Int {
        cells.lazy.filter { Self.center(of: $0).distance(to: area.center) <= area.radius }.count
    }

    /// About 15 km of street per km², at one cell per 20 m. Only for `fraction(in:)`.
    static func estimatedStreetCells(in area: HomeArea) -> Int {
        max(1, Int(area.areaKm2 * 15_000 / 20))
    }

    /// A rough coverage figure for before the streets are in. `WalkLibrary.coverageFraction`
    /// prefers the real one and only falls back to this.
    func fraction(in area: HomeArea) -> Double {
        min(1, Double(walkedCells(in: area)) / Double(Self.estimatedStreetCells(in: area)))
    }
}
