import CoreLocation
import Foundation

/// Tracks which bits of street the walker has covered as a set of ~20 m grid cells.
///
/// This is a stand-in for real street matching: it does not know where streets are,
/// so coverage is walked cells over an estimate of street cells in the home area.
/// Swap `estimatedStreetCells` for a count from OpenStreetMap once street data is wired in.
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

    /// About 15 km of street per km², at one cell per 20 m.
    static func estimatedStreetCells(in area: HomeArea) -> Int {
        max(1, Int(area.areaKm2 * 15_000 / 20))
    }

    func fraction(in area: HomeArea) -> Double {
        min(1, Double(walkedCells(in: area)) / Double(Self.estimatedStreetCells(in: area)))
    }
}
