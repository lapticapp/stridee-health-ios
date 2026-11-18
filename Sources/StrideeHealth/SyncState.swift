import Foundation
import HealthKit

/// What the SDK remembers between launches. Small and non-secret, so
/// `UserDefaults`; the token lives in the Keychain and uploads in
/// ``UploadQueue``.
struct SyncState {
    private let defaults: UserDefaults
    private static let prefix = "fit.stridee.health."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ name: String) -> String { Self.prefix + name }

    /// This device is connected and should sync.
    var isConnected: Bool {
        get { defaults.bool(forKey: key("connected")) }
        nonmutating set { defaults.set(newValue, forKey: key("connected")) }
    }

    /// A disconnect that could not reach the API, to retry at the next launch.
    var pendingRemoteDisconnect: Bool {
        get { defaults.bool(forKey: key("pendingRemoteDisconnect")) }
        nonmutating set { defaults.set(newValue, forKey: key("pendingRemoteDisconnect")) }
    }

    var lastSyncDate: Date? {
        get { date("lastSyncDate") }
        nonmutating set { setDate(newValue, "lastSyncDate") }
    }

    /// Wellness has been collected up to here. The next sync re-collects from a
    /// couple of days before it, because a watch writes yesterday late. Moves
    /// window by window through a long collection, so an app killed on the way
    /// resumes from the last window it sent.
    var wellnessCollectedThrough: Date? {
        get { date("wellnessCollectedThrough") }
        nonmutating set { setDate(newValue, "wellnessCollectedThrough") }
    }

    /// How far back the first sync's wellness history goes. Set when it starts.
    var wellnessHistoryStart: Date? {
        get { date("wellnessHistoryStart") }
        nonmutating set { setDate(newValue, "wellnessHistoryStart") }
    }

    /// The first sync's wellness history has been collected from here to
    /// ``wellnessCollectedThrough``. Moves back a window at a time, newest
    /// month first, until it reaches ``wellnessHistoryStart``. Absent on a
    /// device that read its history oldest first, before this existed: that
    /// history is whole once ``wellnessCollectedThrough`` reaches today.
    var wellnessHistoryReachedBack: Date? {
        get { date("wellnessHistoryReachedBack") }
        nonmutating set { setDate(newValue, "wellnessHistoryReachedBack") }
    }

    /// Apps whose wellness is left out, by bundle identifier. Kept across a
    /// disconnect: it says what the integration receives another way, not
    /// what this device has sent.
    var ignoredWellnessSources: Set<String> {
        get { Set(defaults.stringArray(forKey: key("ignoredWellnessSources")) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: key("ignoredWellnessSources")) }
    }

    /// When a sync last found new data in HealthKit, per data type. What an
    /// app reads to tell "connected and working" from "connected, but HealthKit
    /// is handing us nothing" — which, since iOS never reports a denied read,
    /// is the only sign of one.
    var lastDataFound: [HealthSync.DataType: Date] {
        get {
            let raw = defaults.dictionary(forKey: key("lastDataFound")) as? [String: Double] ?? [:]
            var out: [HealthSync.DataType: Date] = [:]
            for (name, seconds) in raw {
                if let type = HealthSync.DataType(rawValue: name) {
                    out[type] = Date(timeIntervalSince1970: seconds)
                }
            }
            return out
        }
        nonmutating set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) })
            defaults.set(raw, forKey: key("lastDataFound"))
        }
    }

    /// Workouts that start before this are not read, for an integration that
    /// takes no workout history: the date it gave, or the moment this device
    /// first read workouts.
    var workoutsSince: Date? {
        get { date("workoutsSince") }
        nonmutating set { setDate(newValue, "workoutsSince") }
    }

    /// The workouts since ``workoutsSince`` have been read back to here, by
    /// date, newest month first. The anchor covers what is added after.
    var workoutHistoryReachedBack: Date? {
        get { date("workoutHistoryReachedBack") }
        nonmutating set { setDate(newValue, "workoutHistoryReachedBack") }
    }

    /// The workout `HKQueryAnchor`, archived. Advanced batch by batch, each time
    /// every workout the batch covers is in the upload queue.
    var workoutAnchor: HKQueryAnchor? {
        get {
            guard let data = defaults.data(forKey: key("workoutAnchor")) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
        nonmutating set {
            guard let newValue,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true)
            else {
                defaults.removeObject(forKey: key("workoutAnchor"))
                return
            }
            defaults.set(data, forKey: key("workoutAnchor"))
        }
    }

    /// Adopt an anchor an app archived itself before using the SDK, then remove
    /// it from where it was. Removed so it is adopted exactly once: after a
    /// disconnect the SDK forgets its own anchor, and a reconnect has to start
    /// from the full history rather than from a stale import.
    func importWorkoutAnchor(fromUserDefaultsKey legacyKey: String) {
        guard let data = UserDefaults.standard.data(forKey: legacyKey) else { return }
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }
        guard defaults.data(forKey: key("workoutAnchor")) == nil,
              (try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)) != nil
        else { return }
        defaults.set(data, forKey: key("workoutAnchor"))
    }

    /// The workouts this device has scheduled on the watch, by WorkoutKit plan
    /// id. How the next sync tells its own plans from ones the app scheduled
    /// itself, and an unchanged workout from an edited one.
    var managedPlans: [UUID: ManagedPlan] {
        get {
            guard let data = defaults.data(forKey: key("managedPlans")),
                  let raw = try? JSONDecoder().decode([String: ManagedPlan].self, from: data)
            else { return [:] }
            var out: [UUID: ManagedPlan] = [:]
            for (id, plan) in raw {
                if let uuid = UUID(uuidString: id) { out[uuid] = plan }
            }
            return out
        }
        nonmutating set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            if raw.isEmpty {
                defaults.removeObject(forKey: key("managedPlans"))
            } else if let data = try? JSONEncoder().encode(raw) {
                defaults.set(data, forKey: key("managedPlans"))
            }
        }
    }

    /// The scheduling authorization the API was last told about, so it is told
    /// again only when it changes.
    var declaredScheduling: String? {
        get { defaults.string(forKey: key("declaredScheduling")) }
        nonmutating set { defaults.set(newValue, forKey: key("declaredScheduling")) }
    }

    /// See ``HealthSync/readWorkouts(startingFrom:)``. An earlier start than
    /// before carries the read by date back from where it stood, or from now
    /// when nothing was read by date yet: what HealthKit already held is past
    /// the anchor, and only a read by date hands it back.
    func readWorkouts(startingFrom date: Date, now: Date = Date()) {
        let before = workoutsSince
        guard before != date else { return }
        workoutsSince = date
        guard before.map({ date < $0 }) ?? true else { return }
        if workoutHistoryReachedBack == nil { workoutHistoryReachedBack = before ?? now }
    }

    /// See ``HealthSync/ignoreWellness(writtenBy:)``. An app taken off the
    /// list makes the next sync read the wellness history again.
    func ignoreWellness(writtenBy bundleIdentifiers: Set<String>) {
        let before = ignoredWellnessSources
        guard bundleIdentifiers != before else { return }
        ignoredWellnessSources = bundleIdentifiers
        guard !before.isSubset(of: bundleIdentifiers) else { return }
        for name in ["wellnessCollectedThrough", "wellnessHistoryStart", "wellnessHistoryReachedBack"] {
            defaults.removeObject(forKey: key(name))
        }
    }

    /// Forget everything about this device's sync — on disconnect, so the next
    /// connect starts with a full history.
    ///
    /// `managedPlans` is not in the list: those are plans physically on a
    /// watch, and forgetting them before they are removed would leave them
    /// there with nothing that knows they are ours. Whoever removes them
    /// clears it.
    func reset() {
        for name in ["connected", "lastSyncDate", "wellnessCollectedThrough", "wellnessHistoryStart", "wellnessHistoryReachedBack", "workoutAnchor", "workoutsSince", "workoutHistoryReachedBack", "lastDataFound", "declaredScheduling"] {
            defaults.removeObject(forKey: key(name))
        }
    }

    private func date(_ name: String) -> Date? {
        let seconds = defaults.double(forKey: key(name))
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    private func setDate(_ date: Date?, _ name: String) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: key(name))
        } else {
            defaults.removeObject(forKey: key(name))
        }
    }
}
