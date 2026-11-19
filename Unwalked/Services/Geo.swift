import CoreLocation
import MapKit

enum Geo {
    static let earthRadius = 6_371_000.0

    /// The point `distance` metres from `origin` along `bearing` degrees.
    static func destination(from origin: Coord, bearing: Double, distance: CLLocationDistance) -> Coord {
        let δ = distance / earthRadius
        let θ = bearing * .pi / 180
        let φ1 = origin.lat * .pi / 180
        let λ1 = origin.lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return Coord(lat: φ2 * 180 / .pi, lon: λ2 * 180 / .pi)
    }

    static func length(of path: [Coord]) -> CLLocationDistance {
        zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// Distance from `point` to the segment a–b, in metres, using a local flat projection.
    static func distance(from point: Coord, toSegment a: Coord, _ b: Coord) -> CLLocationDistance {
        let mPerLat = 111_320.0
        let mPerLon = 111_320.0 * cos(point.lat * .pi / 180)
        let ax = (a.lon - point.lon) * mPerLon, ay = (a.lat - point.lat) * mPerLat
        let bx = (b.lon - point.lon) * mPerLon, by = (b.lat - point.lat) * mPerLat
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
        let px = ax + t * dx, py = ay + t * dy
        return (px * px + py * py).squareRoot()
    }

    /// Nearest point on `path`: the index of the segment's start and the distance to it.
    static func nearest(to point: Coord, on path: [Coord], from start: Int = 0) -> (index: Int, distance: CLLocationDistance) {
        guard path.count > 1 else {
            return (0, path.first.map { point.distance(to: $0) } ?? .infinity)
        }
        let first = min(max(0, start), path.count - 2)
        var best = (index: first, distance: CLLocationDistance.infinity)
        for i in first..<(path.count - 1) {
            let d = distance(from: point, toSegment: path[i], path[i + 1])
            if d < best.distance { best = (i, d) }
        }
        return best
    }

    static func path(of polyline: MKPolyline) -> [Coord] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords.map(Coord.init)
    }

    /// Resamples a path so no two points are more than `spacing` metres apart.
    static func densify(_ path: [Coord], spacing: CLLocationDistance) -> [Coord] {
        guard var last = path.first else { return [] }
        var out = [last]
        for next in path.dropFirst() {
            let d = last.distance(to: next)
            if d > spacing {
                let n = Int(d / spacing)
                for k in 1...n {
                    let t = Double(k) / Double(n + 1)
                    out.append(Coord(lat: last.lat + (next.lat - last.lat) * t, lon: last.lon + (next.lon - last.lon) * t))
                }
            }
            out.append(next)
            last = next
        }
        return out
    }

    static func region(fitting path: [Coord], padding: Double = 1.35) -> MKCoordinateRegion? {
        guard let first = path.first else { return nil }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for c in path {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max(0.004, (maxLat - minLat) * padding),
                        longitudeDelta: max(0.004, (maxLon - minLon) * padding))
        )
    }

    static func region(around center: Coord, radius: CLLocationDistance) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center.cl, latitudinalMeters: radius * 2.6, longitudinalMeters: radius * 2.6)
    }
}
