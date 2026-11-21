import MapKit
import SwiftUI

/// Everything the v2 screens draw over the map.
struct MapLayers {
    /// Every street walked before, drawn dark (light after dark).
    var walked: [[Coord]] = []
    /// The selected loop, as a soft orange band.
    var loop: [Coord]?
    /// The loops not picked, drawn faint so they can be seen and tapped.
    var others: [[Coord]] = []
    /// The rest of the route while walking.
    var ahead: [Coord]?
    /// New-to-you streets, solid orange.
    var fresh: [[Coord]] = []
    /// A shortcut home, dotted.
    var shortcut: [Coord]?
    /// The street being reported, red dashes.
    var reported: [Coord]?
    var home: Coord?
    /// A stop the loop passes on the way.
    var via: ViaPoint?
    var showsUser = false
    var homeArea: HomeArea?
}

struct UnwalkedMap: View {
    var layers: MapLayers
    @Binding var position: MapCameraPosition
    var interactive = true
    /// Called with the place tapped, for picking a loop off the map.
    var onTap: ((Coord) -> Void)?

    var body: some View {
        MapReader { proxy in
            // Screen coordinates: the map runs under the status bar, so its own space and the reader's
            // differ by the safe area, and a tap would land a hundred metres off.
            map.gesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                if let onTap, let place = proxy.convert(tap.location, from: .global) { onTap(Coord(place)) }
            }, including: onTap == nil ? .subviews : .all)
        }
    }

    private var map: some View {
        Map(position: $position, interactionModes: interactive ? [.pan, .zoom] : []) {
            if let area = layers.homeArea {
                MapPolygon(HomeAreaMask.polygon(for: area))
                    .foregroundStyle(Theme.ground.opacity(0.62))
                MapCircle(center: area.center.cl, radius: area.radius)
                    .foregroundStyle(.clear)
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 8]))
            }

            ForEach(Array(layers.walked.enumerated()), id: \.offset) { _, path in
                MapPolyline(coordinates: path.map(\.cl))
                    .stroke(Theme.walked, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }

            ForEach(Array(layers.others.enumerated()), id: \.offset) { _, path in
                MapPolyline(coordinates: path.map(\.cl))
                    .stroke(Theme.walked.opacity(0.28), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            if let loop = layers.loop {
                MapPolyline(coordinates: loop.map(\.cl))
                    .stroke(Theme.fresh.opacity(0.3), style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))
            }

            if let ahead = layers.ahead {
                MapPolyline(coordinates: ahead.map(\.cl))
                    .stroke(Theme.walked.opacity(0.35), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            ForEach(Array(layers.fresh.enumerated()), id: \.offset) { _, path in
                MapPolyline(coordinates: path.map(\.cl))
                    .stroke(Theme.fresh, style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
            }

            if let shortcut = layers.shortcut {
                MapPolyline(coordinates: shortcut.map(\.cl))
                    .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: shortcut.map(\.cl))
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [1, 8]))
            }

            if let reported = layers.reported {
                MapPolyline(coordinates: reported.map(\.cl))
                    .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: reported.map(\.cl))
                    .stroke(Palette.reported, style: StrokeStyle(lineWidth: 6, lineCap: .butt, lineJoin: .round, dash: [5, 9]))
            }

            if let home = layers.home {
                Annotation("Home", coordinate: home.cl, anchor: .center) {
                    HomeMarker()
                }
                .annotationTitles(.hidden)
            }

            if let via = layers.via {
                Annotation(via.name, coordinate: via.coord.cl, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Palette.ink)
                        .accessibilityHidden(true)
                }
            }

            if layers.showsUser {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControlVisibility(.hidden)
        .ignoresSafeArea()
        // VoiceOver reads the sheet and controls first, then the map behind them.
        .accessibilitySortPriority(-1)
    }
}

struct HomeMarker: View {
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Palette.ink, lineWidth: 3))
            .overlay(Circle().fill(Palette.ink).frame(width: 6, height: 6))
            // A dot on the map, not a control: VoiceOver has nothing to do with it.
            .accessibilityHidden(true)
    }
}

/// A big rectangle with the home-area circle cut out, to dim everything outside it.
enum HomeAreaMask {
    static func polygon(for area: HomeArea) -> MKPolygon {
        let c = area.center
        let outer = [
            Coord(lat: c.lat + 0.5, lon: c.lon - 0.8), Coord(lat: c.lat + 0.5, lon: c.lon + 0.8),
            Coord(lat: c.lat - 0.5, lon: c.lon + 0.8), Coord(lat: c.lat - 0.5, lon: c.lon - 0.8),
        ].map(\.cl)
        let hole = stride(from: 0.0, to: 360, by: 5).map {
            Geo.destination(from: c, bearing: $0, distance: area.radius).cl
        }
        return MKPolygon(coordinates: outer, count: outer.count,
                         interiorPolygons: [MKPolygon(coordinates: hole, count: hole.count)])
    }
}

extension MapCameraPosition {
    /// Frames `path` in the part of the screen above a bottom sheet that covers `sheetFraction` of it.
    static func fitting(_ path: [Coord], sheetFraction: Double = 0.4, padding: Double = 1.4) -> MapCameraPosition {
        guard var region = Geo.region(fitting: path, padding: padding) else { return .userLocation(fallback: .automatic) }
        region = region.shiftedForSheet(sheetFraction)
        return .region(region)
    }

    static func home(_ center: Coord, radius: CLLocationDistance = 700, sheetFraction: Double = 0.4) -> MapCameraPosition {
        .region(Geo.region(around: center, radius: radius).shiftedForSheet(sheetFraction))
    }

    /// Close follow-cam for walking.
    static func following(_ here: Coord?, fallback: [Coord]) -> MapCameraPosition {
        if here != nil { return .userLocation(followsHeading: true, fallback: .fitting(fallback, sheetFraction: 0.1)) }
        return .fitting(fallback, sheetFraction: 0.1)
    }
}

extension MKCoordinateRegion {
    /// Grows the region downward so its content sits above a sheet covering the bottom of the screen.
    func shiftedForSheet(_ fraction: Double) -> MKCoordinateRegion {
        guard fraction > 0, fraction < 0.9 else { return self }
        let fullSpan = span.latitudeDelta / (1 - fraction)
        let newCenterLat = center.latitude + span.latitudeDelta / 2 - fullSpan / 2
        return MKCoordinateRegion(
            center: .init(latitude: newCenterLat, longitude: center.longitude),
            span: .init(latitudeDelta: fullSpan, longitudeDelta: span.longitudeDelta)
        )
    }
}
