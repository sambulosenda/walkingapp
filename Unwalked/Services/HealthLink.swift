import CoreLocation
import Foundation
import HealthKit
import Observation

/// A walk recorded somewhere else and brought in from Apple Health to colour the map.
struct ImportedWalk: Codable, Identifiable, Hashable {
    /// The workout's id in Health, so the same walk is never brought in twice.
    var id: UUID
    var date: Date
    var path: [Coord]
}

/// Apple Health (F14): past walking routes come in to colour the map, and each Unwalked walk can go
/// out as a workout.
///
/// What is read from Health stays on the phone like every other walk. Nothing from Health is sent
/// anywhere, and nothing is read but walking and hiking workouts and their routes.
@Observable
final class HealthLink {
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private(set) var isImporting = false
    /// The outcome of the last import, for Settings to show.
    private(set) var message: String?

    private static let savesKey = "savesWorkoutsToHealth"
    /// Whether each finished walk is saved to Health as a workout.
    private(set) var savesWorkouts = UserDefaults.standard.bool(forKey: HealthLink.savesKey)

    /// Marks a workout as one Unwalked wrote, so importing skips it: that walk is on the map already.
    private static let marker = "UnwalkedWalkID"

    private var readTypes: Set<HKObjectType> { [HKObjectType.workoutType(), HKSeriesType.workoutRoute()] }
    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.distanceWalkingRunning)]
    }

    /// Asks for access. True when the request went through, which is not the same as being allowed:
    /// Health never says whether reading was granted.
    func requestAccess() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            return true
        } catch {
            NSLog("Unwalked Health access failed: %@", String(describing: error))
            return false
        }
    }

    @MainActor
    func setSavesWorkouts(_ on: Bool) async {
        if on, await !requestAccess() { return }
        savesWorkouts = on
        UserDefaults.standard.set(on, forKey: Self.savesKey)
    }

    // MARK: Import

    /// Brings in walking and hiking workouts that have a route and are not in `library` yet.
    @MainActor
    func importWalks(into library: WalkLibrary) async {
        guard Self.isAvailable else { message = "Apple Health isn't available on this device."; return }
        guard await requestAccess() else { message = "Couldn't ask Apple Health for your walks."; return }
        isImporting = true
        defer { isImporting = false }
        let known = Set(library.imported.map(\.id))
        let fresh = await walks(skipping: known)
        library.addImported(fresh)
        NSLog("Unwalked Health import: %d new walks", fresh.count)
        message = fresh.isEmpty
            ? "No new walks with a route found in Apple Health."
            : "Brought in \(fresh.count) \(fresh.count == 1 ? "walk" : "walks") from Apple Health."
    }

    private func walks(skipping known: Set<UUID>) async -> [ImportedWalk] {
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .walking), HKQuery.predicateForWorkouts(with: .hiking),
        ])
        let workouts: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        var out: [ImportedWalk] = []
        for workout in workouts where !known.contains(workout.uuid) && workout.metadata?[Self.marker] == nil {
            let path = await route(of: workout)
            if path.count > 1 { out.append(ImportedWalk(id: workout.uuid, date: workout.startDate, path: path)) }
        }
        return out
    }

    /// A workout's route, thinned to a point every 10 m or so.
    private func route(of workout: HKWorkout) async -> [Coord] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: HKSeriesType.workoutRoute(),
                                              predicate: HKQuery.predicateForObjects(from: workout),
                                              anchor: nil, limit: HKObjectQueryNoLimit) { _, samples, _, _, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        var path: [Coord] = []
        for route in routes {
            let locations: [CLLocation] = await withCheckedContinuation { continuation in
                var all: [CLLocation] = []
                let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                    all += batch ?? []
                    if done || error != nil { continuation.resume(returning: all) }
                }
                store.execute(query)
            }
            for location in locations {
                let c = Coord(location.coordinate)
                if let last = path.last, last.distance(to: c) < 10 { continue }
                path.append(c)
            }
        }
        return path
    }

    // MARK: Save

    /// Saves a finished walk to Health as a walking workout with its route, when that is switched on.
    func save(_ walk: WalkRecord) async {
        guard Self.isAvailable, savesWorkouts, walk.path.count > 1, walk.duration > 0 else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        let end = walk.date.addingTimeInterval(walk.duration)
        do {
            try await builder.beginCollection(at: walk.date)
            let distance = HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                                            quantity: HKQuantity(unit: .meter(), doubleValue: walk.distance),
                                            start: walk.date, end: end)
            try await builder.addSamples([distance])
            try await builder.addMetadata([Self.marker: walk.id.uuidString])
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return }

            // The trail has places but no times, so spread them evenly over the walk.
            let last = Double(max(1, walk.path.count - 1))
            let locations = walk.path.enumerated().map { i, c in
                CLLocation(coordinate: c.cl, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1,
                           timestamp: walk.date.addingTimeInterval(walk.duration * Double(i) / last))
            }
            let route = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            try await route.insertRouteData(locations)
            try await route.finishRoute(with: workout, metadata: nil)
            NSLog("Unwalked Health: saved a %.0f m walk as a workout", walk.distance)
        } catch {
            NSLog("Unwalked Health save failed: %@", String(describing: error))
        }
    }
}
