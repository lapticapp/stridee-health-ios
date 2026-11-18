import Foundation
import HealthKit
import UIKit
import os

/// Apple Health → Stridee, from inside your app.
///
/// ```swift
/// // application(_:didFinishLaunchingWithOptions:) — every launch, including
/// // the background ones HealthKit makes to deliver new data.
/// HealthSync.configure(.init(tokenProvider: { try await MyAPI.strideeDeviceToken() }))
///
/// // When the athlete taps "Connect Apple Health":
/// try await HealthSync.shared.connect()
/// ```
///
/// From there it runs itself. HealthKit wakes the app when a workout or a night
/// of sleep is written; the SDK reads what is new, queues it on disk, and
/// uploads it with a device token your server minted. Coming back to the
/// foreground syncs too. Your backend hears about it on its webhook —
/// `activity.created` for workouts, `wellness.created` / `wellness.updated`
/// for the rest — exactly as for any other provider.
///
/// It works the other way too. With ``Configuration/schedulesWorkouts`` on,
/// the workouts your server creates with `POST /v1/workouts` are put on the
/// athlete's Apple Watch — see `WorkoutSchedule.swift`.
@MainActor
public final class HealthSync: ObservableObject {
    public static let shared = HealthSync()

    /// Where syncing stands. Observe it for a settings screen.
    @Published public internal(set) var status = Status()

    /// Configure the SDK. Call it from
    /// `application(_:didFinishLaunchingWithOptions:)` on **every** launch:
    /// HealthKit's background delivery relaunches the app and only delivers to
    /// observers registered before launch finishes.
    public static func configure(_ configuration: Configuration) {
        shared.configure(configuration)
    }

    /// Whether HealthKit exists on this device at all.
    public nonisolated var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private let queue = UploadQueue()
    let state = SyncState()
    let log = Logger(subsystem: "fit.stridee.health", category: "sync")

    private(set) var configuration: Configuration?
    private var tokens: TokenStore?
    private(set) var api: APIClient?
    /// The scheduling pass in flight, if any. See `WorkoutSchedule.swift`.
    var scheduleSync: Task<HealthSyncError?, Never>?
    private var observers: [HKObserverQuery] = []
    private var currentSync: Task<HealthSyncError?, Never>?
    private var resyncRequested = false
    private var foregroundObserver: NSObjectProtocol?

    private init() {}

    private func configure(_ configuration: Configuration) {
        self.configuration = configuration
        let tokens = TokenStore(provider: configuration.tokenProvider)
        self.tokens = tokens
        self.api = APIClient(baseURL: configuration.baseURL, tokens: tokens)

        if let legacyKey = configuration.importWorkoutAnchorFromUserDefaultsKey {
            state.importWorkoutAnchor(fromUserDefaultsKey: legacyKey)
        }

        status.isConnected = state.isConnected
        status.lastSyncDate = state.lastSyncDate
        status.lastDataFound = state.lastDataFound
        Task { self.status.pendingUploads = await self.queue.count }
        status.workoutScheduling.scheduledCount = state.managedPlans.count
        Task { _ = await self.authorizationStatus() }
        if configuration.schedulesWorkouts {
            Task { await self.workoutSchedulingAuthorization() }
        }

        if state.isConnected {
            // Registered synchronously, before launch finishes — the whole
            // reason `configure` belongs in `didFinishLaunching`.
            startObserving()
            Task { await self.confirmConnection() }
        }

        if state.pendingRemoteDisconnect, let api {
            Task {
                if (try? await api.deleteConnection()) != nil { self.state.pendingRemoteDisconnect = false }
            }
        }

        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state.isConnected else { return }
                    try? await self.syncNow()
                }
            }
        }
    }

    // MARK: - Permissions

    /// Where the permission flow stands, asked of HealthKit now. Also kept on
    /// ``Status/authorization``.
    ///
    /// Never `granted` or `denied` — iOS does not say. See
    /// ``AuthorizationStatus``.
    @discardableResult
    public func authorizationStatus() async -> AuthorizationStatus {
        let result: AuthorizationStatus
        if !isHealthDataAvailable {
            result = .unavailable
        } else if let configuration {
            let types = Self.readTypes(for: configuration.dataTypes)
            let answered: Bool = await withCheckedContinuation { continuation in
                store.getRequestStatusForAuthorization(toShare: [], read: types) { status, _ in
                    continuation.resume(returning: status == .unnecessary)
                }
            }
            result = answered ? .requested : .notRequested
        } else {
            result = .notRequested
        }
        status.authorization = result
        return result
    }

    /// Whether ``connect()`` would show the HealthKit permission sheet.
    ///
    /// `false` once the athlete has answered for every type this configuration
    /// reads — in this install or a previous one.
    public func needsAuthorization() async -> Bool {
        await authorizationStatus() != .requested
    }

    /// Show the HealthKit permission sheet without connecting.
    ///
    /// For an app that asks during onboarding and connects later, or that
    /// added wellness to ``Configuration/dataTypes`` and needs to ask for the
    /// new types. iOS shows the sheet only for types never asked about, so
    /// calling this again is harmless — it returns at once.
    ///
    /// Returning normally means the user answered, not that they allowed
    /// anything: see ``AuthorizationStatus``.
    ///
    /// - Parameter dataTypes: What to ask for. Defaults to
    ///   ``Configuration/dataTypes``.
    public func requestAuthorization(for dataTypes: Set<DataType>? = nil) async throws {
        guard isHealthDataAvailable else { throw HealthSyncError.healthDataUnavailable }
        guard let configuration else { throw HealthSyncError.notConfigured }
        try await store.requestAuthorization(
            toShare: [], read: Self.readTypes(for: dataTypes ?? configuration.dataTypes)
        )
        await authorizationStatus()
    }

    /// Open your app's page in the Settings app.
    ///
    /// The nearest place iOS lets an app send someone to change its Health
    /// access: there is no link straight to the Health switches. On recent iOS
    /// versions the page lists Health; otherwise the switches are at
    /// Settings → Health → Data Access & Devices → your app. Say which in the
    /// sentence around the button.
    @discardableResult
    public func openSettings() async -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
        return await UIApplication.shared.open(url)
    }

    // MARK: - Connecting

    /// Ask for HealthKit access, connect this user, and start syncing.
    ///
    /// Shows the permission sheet for anything not yet asked about, then tells
    /// the API this user is connected — your webhook gets `account.connected`
    /// the first time — and runs the first sync, which sends workout history
    /// in full unless ``Configuration/sendsWorkoutHistory`` is off, and
    /// ``Configuration/wellnessHistoryDays`` of wellness. Returns
    /// once connected; the first sync carries on in the background.
    ///
    /// - Parameter requestingAuthorization: `false` connects without showing
    ///   the sheet, for an app that already holds HealthKit access and is
    ///   moving onto the SDK. Types never granted simply return no data.
    public func connect(requestingAuthorization: Bool = true) async throws {
        guard isHealthDataAvailable else { throw HealthSyncError.healthDataUnavailable }
        guard let configuration, let api else { throw HealthSyncError.notConfigured }

        if requestingAuthorization {
            try await requestAuthorization(for: configuration.dataTypes)
        }

        _ = try await api.putConnection()

        state.pendingRemoteDisconnect = false
        // A new connection knows nothing about this device: tell it again
        // whether workouts can be scheduled here.
        state.declaredScheduling = nil
        state.isConnected = true
        status.isConnected = true
        status.lastError = nil
        startObserving()

        Task { try? await self.syncNow() }
    }

    /// Stop syncing and disconnect this user.
    ///
    /// Stops observing HealthKit, drops anything still queued, and forgets this
    /// device's progress so a later ``connect()`` starts from the full history.
    /// Workouts this SDK scheduled on the watch are taken off it.
    ///
    /// - Parameter revokeOnServer: `true` (the default) also disconnects the
    ///   user on the Stridee API — your webhook gets `account.disconnected` and
    ///   their device tokens stop working. Pass `false` to stop only this
    ///   device, for example when the user signs out of your app; their
    ///   connection stays, and connecting again later is seamless. A server
    ///   disconnect that cannot reach the API is retried at the next launch.
    public func disconnect(revokeOnServer: Bool = true) async {
        stopObserving()
        currentSync?.cancel()
        scheduleSync?.cancel()
        await queue.removeAll()
        state.reset()
        await removeScheduledWorkouts()
        status = Status()

        if revokeOnServer, let api {
            do {
                _ = try await api.deleteConnection()
            } catch {
                state.pendingRemoteDisconnect = true
            }
        }
        await tokens?.clear()
    }

    /// Ask the API whether this user is still connected; stop if not.
    private func confirmConnection() async {
        guard let api, state.isConnected else { return }
        if (try? await api.getConnection()) == .notConnected {
            await markDisconnectedRemotely()
        }
    }

    func markDisconnectedRemotely() async {
        log.notice("disconnected on the server; stopping")
        stopObserving()
        state.reset()
        status.isConnected = false
        status.pendingUploads = 0
        status.lastError = .disconnectedRemotely
        await queue.removeAll()
        // Their workouts stop being ours to keep on the watch.
        Task { await self.removeScheduledWorkouts() }
    }

    /// Leave out the wellness these apps write to HealthKit, for an
    /// integration that receives their data another way: a WHOOP or Garmin
    /// account connected directly, whose nights would otherwise arrive twice.
    /// Kept between launches.
    ///
    /// An app taken off the list leaves days nothing else covered, so the
    /// wellness history is read again on the next sync, newest month first.
    public func ignoreWellness(writtenBy bundleIdentifiers: Set<String>) {
        state.ignoreWellness(writtenBy: bundleIdentifiers)
    }

    /// Read workouts from this date on, for an integration that takes no
    /// workout history (``Configuration/sendsWorkoutHistory`` off) and knows
    /// when its user connected: without it, they are read from the moment
    /// this device first read workouts. Kept between launches; a disconnect
    /// forgets it. An earlier date than before reads the workouts in between,
    /// newest first.
    public func readWorkouts(startingFrom date: Date) {
        state.readWorkouts(startingFrom: date)
    }

    // MARK: - Syncing

    /// Read what is new from HealthKit and upload everything queued.
    ///
    /// Safe to call at any time and from anywhere: concurrent calls share one
    /// sync, and a call made while one is running schedules another right after
    /// it. Throws what stopped it, which is also on ``status``.
    public func syncNow() async throws {
        if let running = currentSync {
            resyncRequested = true
            if let error = await running.value { throw error }
            return
        }

        let task = Task { () -> HealthSyncError? in
            var error: HealthSyncError?
            repeat {
                resyncRequested = false
                error = await performSync()
            } while resyncRequested && error == nil && !Task.isCancelled
            return error
        }
        currentSync = task
        let error = await task.value
        currentSync = nil
        if let error { throw error }
    }

    private func performSync() async -> HealthSyncError? {
        guard let configuration, let api else { return .notConfigured }
        guard state.isConnected else { return .notConnected }
        guard isHealthDataAvailable else { return .healthDataUnavailable }

        status.isSyncing = true
        // Finish the upload if the app is backgrounded mid-sync.
        let background = UIApplication.shared.beginBackgroundTask(withName: "StrideeHealth sync")
        let error = await collectAndSend(configuration, api)
        let pending = await queue.count
        var finished = status
        finished.isSyncing = false
        finished.progress = nil
        finished.pendingUploads = pending
        status = finished
        UIApplication.shared.endBackgroundTask(background)
        return error
    }

    private func collectAndSend(_ configuration: Configuration, _ api: APIClient) async -> HealthSyncError? {
        // What a sync the app did not live to finish left behind goes first.
        // Then the last days of wellness, so a year of workouts read for the
        // first time never holds back last night; then the workouts, a batch
        // at a time; then the wellness history, newest month first.
        var error = await drain(api)
        let wellness = configuration.dataTypes.contains(.wellness)
        if error == nil, wellness {
            error = await collectRecentWellness(configuration, uploadingWith: api)
        }
        if error == nil, configuration.dataTypes.contains(.workouts) {
            error = await collectWorkouts(configuration, uploadingWith: api)
        }
        if error == nil, wellness {
            error = await collectWellnessHistory(uploadingWith: api)
        }
        // Disconnected mid-sync: `disconnect` already reset the status.
        guard state.isConnected else { return error }
        if let error {
            status.lastError = error
        } else {
            let now = Date()
            state.lastSyncDate = now
            status.lastSyncDate = now
            status.lastError = nil
        }

        // The other direction, last: nothing here waits on HealthKit, and a
        // failed upload is no reason to leave the watch out of date. Its own
        // failure is kept on `status.workoutScheduling`, not on `lastError`,
        // which is about what was read and sent.
        let scheduleError = configuration.schedulesWorkouts ? await runScheduleSync() : nil
        return error ?? scheduleError
    }

    /// Workouts read from HealthKit per anchored query. The anchor moves once
    /// each batch is queued, so a first sync over years of workouts that the
    /// system kills resumes from the last batch, not from the first workout.
    private static let workoutBatchSize = 50

    /// Queue every workout added since the anchor, a batch at a time, advancing
    /// the anchor after each and uploading the batch before reading the next.
    /// Safe to advance before uploading: the queue is on disk. Uploading as it
    /// goes keeps a year of workouts, routes and all, from piling up on disk
    /// at once.
    ///
    /// Without workout history (``Configuration/sendsWorkoutHistory`` off), a
    /// first read starts the anchor at the present, so it only ever hands back
    /// new workouts, and the workouts since ``SyncState/workoutsSince`` are read
    /// by date instead, newest month first, newest workout first.
    private func collectWorkouts(
        _ configuration: Configuration, uploadingWith api: APIClient
    ) async -> HealthSyncError? {
        let exporter = WorkoutExporter(store: store)
        var found = false
        defer { if found { recordDataFound(.workouts) } }
        if !configuration.sendsWorkoutHistory, state.workoutAnchor == nil {
            let now = Date()
            if state.workoutsSince == nil { state.workoutsSince = now }
            if state.workoutHistoryReachedBack == nil { state.workoutHistoryReachedBack = now }
            if let present = await presentWorkoutAnchor(from: now) { state.workoutAnchor = present }
        }
        let since = configuration.sendsWorkoutHistory ? nil : state.workoutsSince

        while !Task.isCancelled {
            let (workouts, anchor) = await fetchWorkouts(
                after: state.workoutAnchor, startingFrom: since, limit: Self.workoutBatchSize
            )
            guard await queueWorkouts(workouts, configuration, exporter) else { return nil }
            if let anchor { state.workoutAnchor = anchor }
            if !workouts.isEmpty { found = true }
            if let error = await drain(api) { return error }
            if workouts.count < Self.workoutBatchSize { break }
        }

        guard let since, let reachedBack = state.workoutHistoryReachedBack else { return nil }
        let history = SyncWindows.cutBack(
            from: reachedBack, to: since, days: Self.workoutHistoryWindowDays, calendar: .current
        )
        for window in history {
            if Task.isCancelled { return nil }
            let workouts = await workoutsStarting(in: window)
            for batch in workouts.chunked(by: Self.workoutBatchSize) {
                guard await queueWorkouts(batch, configuration, exporter) else { return nil }
                if let error = await drain(api) { return error }
            }
            if !workouts.isEmpty { found = true }
            state.workoutHistoryReachedBack = window.start
        }
        return nil
    }

    /// Days of workout history read by date at a time, newest first.
    private static let workoutHistoryWindowDays = 30

    /// Export and queue workouts, skipping what the configuration leaves out.
    /// `false` when disconnected meanwhile: write nothing more, or a later
    /// connect would resume from an anchor that skips the history.
    private func queueWorkouts(
        _ workouts: [HKWorkout], _ configuration: Configuration, _ exporter: WorkoutExporter
    ) async -> Bool {
        for workout in workouts {
            let source = workout.sourceRevision.source.bundleIdentifier
            if configuration.excludedSourceBundleIDs.contains(source) { continue }
            if configuration.excludedWorkoutActivityTypes.contains(workout.workoutActivityType) { continue }
            // Off the main actor: a long ride's route is a lot of JSON.
            let exported = await Task.detached { await exporter.export(workout) }.value
            guard let exported else {
                log.error("could not serialise workout \(workout.uuid, privacy: .public)")
                continue
            }
            guard state.isConnected else { return false }
            await queue.enqueue(exported.rawData, kind: .workout, key: exported.externalId)
        }
        return state.isConnected
    }

    /// An anchor past every workout HealthKit holds now: a query for workouts
    /// that start from now on finds none and hands back where the store stands.
    private func presentWorkoutAnchor(from now: Date) async -> HKQueryAnchor? {
        let predicate = HKQuery.predicateForSamples(withStart: now, end: nil, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(), predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit
            ) { _, _, _, newAnchor, _ in
                continuation.resume(returning: newAnchor)
            }
            store.execute(query)
        }
    }

    /// The workouts that start in `window`, newest first.
    private func workoutsStarting(in window: SyncWindows.Window) async -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: .strictStartDate)
        let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: [newestFirst]
            ) { _, samples, _ in
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchWorkouts(
        after anchor: HKQueryAnchor?, startingFrom since: Date?, limit: Int
    ) async -> ([HKWorkout], HKQueryAnchor?) {
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate) }
        return await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(), predicate: predicate, anchor: anchor, limit: limit
            ) { _, samples, _, newAnchor, _ in
                let workouts = (samples as? [HKWorkout] ?? []).sorted { $0.startDate > $1.startDate }
                continuation.resume(returning: (workouts, newAnchor))
            }
            store.execute(query)
        }
    }

    /// Items per wellness upload. Well inside the API's 2,000 and 10 MB.
    private static let wellnessBatchSize = 500

    /// Days of wellness read from HealthKit at a time. A month of samples is
    /// small; a year of them, read at once, is what filled the memory of phones
    /// with a long history and got the app killed before it had sent anything.
    private static let wellnessWindowDays = 30

    /// Collect wellness from a little before where the last collection ended,
    /// so the late-arriving tail of yesterday is re-sent, and upload it. On a
    /// first sync that is the last month, and the history behind it is set up
    /// for ``collectWellnessHistory(uploadingWith:)``.
    ///
    /// Each window is read and serialised off the main actor, queued, recorded
    /// as collected, and uploaded. An app killed on the way resumes from the
    /// last window it recorded, and a window that could not be uploaded is
    /// kept on disk for the next sync, which drains it before reading more.
    private func collectRecentWellness(
        _ configuration: Configuration, uploadingWith api: APIClient
    ) async -> HealthSyncError? {
        let now = Date()
        let calendar = Calendar.current
        let collector = WellnessCollector(store: store, ignoredSources: state.ignoredWellnessSources)
        let recentStart: Date
        if let through = state.wellnessCollectedThrough {
            recentStart = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: through)) ?? through
        } else {
            let today = calendar.startOfDay(for: now)
            let historyStart = calendar.date(byAdding: .day, value: -configuration.wellnessHistoryDays, to: today) ?? today
            let lastMonth = calendar.date(byAdding: .day, value: -Self.wellnessWindowDays, to: today) ?? today
            recentStart = max(historyStart, lastMonth)
            state.wellnessHistoryStart = historyStart
            state.wellnessHistoryReachedBack = recentStart
        }

        for window in SyncWindows.cut(from: recentStart, to: now, days: Self.wellnessWindowDays, calendar: calendar) {
            guard await queueWellness(of: window, with: collector) else { return nil }
            state.wellnessCollectedThrough = window.end
            if let error = await drain(api) { return error }
        }
        return nil
    }

    /// Carry the first sync's wellness history back from the last month, a
    /// window at a time, newest first, the same way.
    private func collectWellnessHistory(uploadingWith api: APIClient) async -> HealthSyncError? {
        guard let reachedBack = state.wellnessHistoryReachedBack,
              let historyStart = state.wellnessHistoryStart else { return nil }
        let calendar = Calendar.current
        let collector = WellnessCollector(store: store, ignoredSources: state.ignoredWellnessSources)
        let history = SyncWindows.cutBack(
            from: reachedBack, to: historyStart, days: Self.wellnessWindowDays, calendar: calendar
        )
        for window in history {
            guard await queueWellness(of: window, with: collector) else { return nil }
            state.wellnessHistoryReachedBack = window.start
            if let error = await drain(api) { return error }
        }
        return nil
    }

    /// Read one window of wellness and queue it. `false` when the sync should
    /// stop here without an error: cancelled, disconnected meanwhile, or a
    /// batch that would not serialise.
    private func queueWellness(of window: SyncWindows.Window, with collector: WellnessCollector) async -> Bool {
        if Task.isCancelled { return false }
        let batchSize = Self.wellnessBatchSize
        let (found, bodies): (Bool, [Data]?) = await Task.detached {
            let items = await collector.collect(from: window.start, to: window.end)
            var bodies: [Data] = []
            for batch in items.chunked(by: batchSize) {
                let envelope: [String: Any] = ["format": "healthkit.wellness.v1", "items": batch]
                guard let body = try? JSONSerialization.data(withJSONObject: envelope) else {
                    return (!items.isEmpty, nil)
                }
                bodies.append(body)
            }
            return (!items.isEmpty, bodies)
        }.value
        // Disconnected while collecting: see `collectWorkouts`.
        guard state.isConnected else { return false }
        guard let bodies else {
            log.error("could not serialise a wellness batch")
            return false
        }
        if found { recordDataFound(.wellness) }
        for body in bodies {
            await queue.enqueue(body, kind: .wellness, key: UUID().uuidString)
        }
        return true
    }

    private func recordDataFound(_ type: DataType) {
        var found = state.lastDataFound
        found[type] = Date()
        state.lastDataFound = found
        status.lastDataFound = found
    }

    /// Items uploaded between two updates of ``Status/progress`` and
    /// ``Status/pendingUploads``. Each update reaches every observer of
    /// ``status``; one per item, over a queue of a thousand, kept the app busy
    /// relaying them.
    private static let progressStride = 10

    /// Upload the queue, oldest first, until it is empty or something stops it.
    ///
    /// A payload the API refuses as invalid (400, 413) is dropped — sending it
    /// again cannot succeed, and keeping it would block everything behind it.
    /// An upload of a data type ``Configuration/dataTypes`` no longer names,
    /// queued before it was taken out, is dropped unsent. A transport or token
    /// failure stops the drain and leaves the rest for the next sync.
    private func drain(_ api: APIClient) async -> HealthSyncError? {
        let items = await queue.items()
        guard !items.isEmpty else { return nil }

        var dropped: HealthSyncError?
        for (index, item) in items.enumerated() {
            if index % Self.progressStride == 0 {
                var progressed = status
                progressed.progress = .init(done: index, total: items.count)
                progressed.pendingUploads = items.count - index
                status = progressed
            }
            guard configuration?.sends(item.kind) ?? true, let body = await queue.body(of: item) else {
                await queue.remove(item)
                continue
            }
            do {
                let outcome: APIClient.Outcome
                switch item.kind {
                case .workout: outcome = try await api.uploadWorkout(body)
                case .wellness: outcome = try await api.uploadWellness(body)
                }
                if outcome == .notConnected {
                    await markDisconnectedRemotely()
                    return .disconnectedRemotely
                }
                await queue.remove(item)
            } catch let error as HealthSyncError {
                if case .rejected(let code, _) = error, code == 400 || code == 413 {
                    log.error("API refused a queued \(item.kind.rawValue, privacy: .public); dropping it")
                    await queue.remove(item)
                    dropped = error
                    continue
                }
                return error
            } catch {
                return .transport(error.localizedDescription)
            }
        }
        return dropped
    }

    // MARK: - Background delivery

    /// Register an observer per type worth waking for, with background delivery.
    ///
    /// Workouts wake immediately. Wellness wakes at most hourly — Apple caps
    /// several of these types there anyway, and a sync re-collects every kind,
    /// so observing sleep, HRV and steps is enough to pick up the rest.
    private func startObserving() {
        guard observers.isEmpty, isHealthDataAvailable, let configuration else { return }

        var watched: [(HKSampleType, HKUpdateFrequency)] = []
        if configuration.dataTypes.contains(.workouts) {
            watched.append((HKObjectType.workoutType(), .immediate))
        }
        if configuration.dataTypes.contains(.wellness) {
            if let t = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { watched.append((t, .hourly)) }
            if let t = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { watched.append((t, .hourly)) }
            if let t = HKQuantityType.quantityType(forIdentifier: .stepCount) { watched.append((t, .hourly)) }
        }

        for (type, frequency) in watched {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil, let self else {
                    completion()
                    return
                }
                // HealthKit waits for `completion` before it considers the
                // update delivered, and backs off an app that never calls it.
                Task { @MainActor in
                    try? await self.syncNow()
                    completion()
                }
            }
            observers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: frequency) { [log] ok, error in
                if !ok {
                    log.error("background delivery refused for \(type.identifier, privacy: .public): \(String(describing: error), privacy: .public) — is the HealthKit Background Delivery entitlement set?")
                }
            }
        }
    }

    private func stopObserving() {
        for query in observers { store.stop(query) }
        observers.removeAll()
        store.disableAllBackgroundDelivery { _, _ in }
    }

    // MARK: - What is read

    /// The HealthKit types each data type needs. Read-only: the SDK never
    /// writes to HealthKit.
    static func readTypes(for dataTypes: Set<DataType>) -> Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        func quantity(_ ids: [HKQuantityTypeIdentifier]) {
            for id in ids {
                if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
            }
        }

        if dataTypes.contains(.workouts) {
            types.insert(HKObjectType.workoutType())
            types.insert(HKSeriesType.workoutRoute())
            quantity([
                .heartRate, .activeEnergyBurned,
                .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                .runningPower, .cyclingPower, .cyclingCadence,
            ])
        }

        if dataTypes.contains(.wellness) {
            quantity([
                .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .basalEnergyBurned,
                .flightsClimbed, .appleExerciseTime, .restingHeartRate, .heartRate,
                .heartRateVariabilitySDNN, .vo2Max, .respiratoryRate, .oxygenSaturation,
                .bodyMass, .bodyFatPercentage, .bodyMassIndex,
                .bloodPressureSystolic, .bloodPressureDiastolic,
                .appleSleepingWristTemperature,
            ])
            if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        }

        return types
    }
}
