import CoreLocation
import SwiftUI

/// A picture of a walk, or of the whole map, to share (F17).
///
/// Streets only: no base map, no place names, and nothing near home. It shows the shape of where
/// someone walked without showing where they live.
///
/// "Near home" is not a circle round the door: the middle of a round hole is easy to find. The
/// hidden patch is a circle of a size picked at random, pushed off to one side, with home somewhere
/// inside it. It is picked once and kept, because a different patch on every picture could be laid
/// over one another to narrow home down.
struct ShareCard: View {
    var walked: [[Coord]]
    var fresh: [[Coord]]
    var headline: String
    var detail: String

    static let size = CGSize(width: 360, height: 450)
    /// The patch left off every picture: home is inside it, at least 200 m from its edge, and not at its middle.
    struct HomeMask: Codable {
        /// The home this patch was picked for, so a new one is picked if home moves.
        var home: Coord
        var centre: Coord
        var radius: CLLocationDistance

        private static let key = "shareHomeMask"

        static func mask(for home: Coord) -> HomeMask {
            if let raw = UserDefaults.standard.data(forKey: key),
               let saved = try? JSONDecoder().decode(HomeMask.self, from: raw),
               saved.home.distance(to: home) < 50 {
                return saved
            }
            let offset = Double.random(in: 100...250)
            let made = HomeMask(home: home,
                                centre: Geo.destination(from: home, bearing: Double.random(in: 0..<360), distance: offset),
                                radius: offset + Double.random(in: 200...300))
            if let raw = try? JSONEncoder().encode(made) { UserDefaults.standard.set(raw, forKey: key) }
            return made
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Canvas { context, size in
                let all = walked + fresh
                let points = all.flatMap { $0 }
                guard let first = points.first else { return }
                // Flat metres round the first point, north up.
                let perLat = 111_320.0, perLon = 111_320.0 * cos(first.lat * .pi / 180)
                func flat(_ c: Coord) -> CGPoint { CGPoint(x: (c.lon - first.lon) * perLon, y: -(c.lat - first.lat) * perLat) }
                let flats = points.map(flat)
                let minX = flats.map(\.x).min() ?? 0, maxX = flats.map(\.x).max() ?? 1
                let minY = flats.map(\.y).min() ?? 0, maxY = flats.map(\.y).max() ?? 1
                let scale = min(size.width / max(1, maxX - minX), size.height / max(1, maxY - minY))
                let dx = (size.width - (maxX - minX) * scale) / 2, dy = (size.height - (maxY - minY) * scale) / 2
                func place(_ c: Coord) -> CGPoint {
                    let p = flat(c)
                    return CGPoint(x: dx + (p.x - minX) * scale, y: dy + (p.y - minY) * scale)
                }
                func line(_ path: [Coord]) -> Path {
                    var out = Path()
                    guard let start = path.first else { return out }
                    out.move(to: place(start))
                    for c in path.dropFirst() { out.addLine(to: place(c)) }
                    return out
                }
                let style = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                for path in walked { context.stroke(line(path), with: .color(Palette.nightText.opacity(0.85)), style: style) }
                for path in fresh {
                    context.stroke(line(path), with: .color(Palette.fresh),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(headline)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.nightText)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.nightMuted)
                .padding(.top, 2)
            HStack {
                Text("Unwalked")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.fresh)
                Spacer()
                Text("Streets © OpenStreetMap contributors")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.nightMuted)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Palette.ink)
    }

    /// The parts of a path that are not near home, as separate runs.
    static func awayFromHome(_ path: [Coord], home: Coord?) -> [[Coord]] {
        guard let home else { return [path] }
        let mask = HomeMask.mask(for: home)
        var runs: [[Coord]] = []
        var run: [Coord] = []
        for c in Geo.densify(path, spacing: 25) {
            if c.distance(to: mask.centre) > mask.radius {
                run.append(c)
            } else if run.count > 1 {
                runs.append(run)
                run = []
            } else {
                run = []
            }
        }
        if run.count > 1 { runs.append(run) }
        return runs
    }

    /// Draws the card as an image. The home area's centre is treated as home when there is no other.
    @MainActor
    static func image(walked: [[Coord]], fresh: [[Coord]] = [], home: Coord?, headline: String, detail: String) -> Image {
        let card = ShareCard(walked: walked.flatMap { awayFromHome($0, home: home) },
                             fresh: fresh.flatMap { awayFromHome($0, home: home) },
                             headline: headline, detail: detail)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return Image(uiImage: renderer.uiImage ?? UIImage())
    }
}
