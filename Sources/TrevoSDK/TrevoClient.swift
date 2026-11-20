import Foundation
import os

/// Experiments and event tracking for an iOS app. Create one per app and keep it for the app's
/// lifetime. Every method is safe to call from any thread.
public final class TrevoClient: @unchecked Sendable {
    private struct State {
        var anonymousId: String?
        var userId: String?
        // Bumped by identify() and reset(), so a slow startup read can't undo a newer identity.
        var anonymousRevision = 0
        var userRevision = 0
        var assignmentRevision = 0
        var assignments: [String: String] = [:]
        var exposures = ExposureDeduper()
        var pending: [PendingEvent] = []
        var locale: String?
        var listeners: [UUID: @MainActor @Sendable () -> Void] = [:]
        // Startup can load config before identity; publishing that state would flash control.
        var canEmitChanges = false
        var isReady = false
        var stopped = false
        var pollTask: Task<Void, Never>?
        var flushTask: Task<Void, Never>?
        var lifecycleSubscription: TrevoSubscription?
        // A read that failed left the stored arms in place, so nothing overwrites them this session.
        var assignmentsUnreadable = false
    }

    private struct PendingEvent {
        let name: String
        let properties: [String: TrevoValue]?
        let insertId: String?
        let timestamp: String
    }

    private let state = Locked(State())
    private let enabled: Bool
    private let appVersion: String?
    private let defaultLocale: String?
    private let bootstrap: ExperimentRegistry
    private let pollInterval: TimeInterval
    private let flushInterval: TimeInterval
    private let onError: ErrorHandler
    private let storage: StorageQueue
    private let lifecycle: any TrevoLifecycle
    let config: ConfigStore
    let events: EventQueue
    let paywalls: PaywallStore
    private var startup: Task<Void, Never>!

    public convenience init(options: TrevoOptions) {
        self.init(options: options, paywallFiles: PaywallDirectory.standard())
    }

    init(
        options: TrevoOptions, paywallFiles: any PaywallPageFiles,
        paywallDownloads: Bool = PaywallStore.platformHasView
    ) {
        let onError = options.onError ?? Self.log
        let apiKey = options.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = options.transport ?? URLSessionTransport(timeout: Constants.requestTimeout)
        let headers = ["Authorization": "Bearer \(apiKey)", "User-Agent": TrevoSDKVersion.userAgent]
        let storage = StorageQueue(storage: options.storage ?? FileStorage.standard(), onError: onError)
        let changes = ChangeRelay()

        let refusal = Self.keyRefusal(apiKey)
        self.enabled = refusal == nil
        self.appVersion = options.appVersion.flatMap { JSString.isBlank($0) ? nil : $0 }
        self.defaultLocale = Self.cleanLocale(options.locale)
        self.bootstrap = ExperimentRegistry(options.bootstrapConfig)
        self.pollInterval = Self.clamped(options.pollInterval, from: Constants.minPollInterval)
        self.flushInterval = Self.clamped(options.flushInterval, from: Constants.minFlushInterval)
        self.onError = onError
        self.storage = storage
        self.lifecycle = options.lifecycle ?? SystemLifecycle()
        let paywalls = PaywallStore(
            files: paywallFiles, transport: transport, storage: storage, onError: onError,
            downloads: paywallDownloads)
        self.paywalls = paywalls
        self.config = ConfigStore(
            url: options.configURL, headers: headers, transport: transport, storage: storage,
            onError: onError, onChange: { changes.emit() },
            onPaywalls: { entries, fetched in paywalls.adopt(entries, fetched: fetched) })
        self.events = EventQueue(
            url: options.ingestionURL, headers: headers, maxBatchSize: options.maxBatchSize,
            transport: transport, storage: storage, onError: onError)

        changes.target = self
        if let refusal {
            onError(TrevoError(refusal))
            state.withLock { $0.isReady = true }
            startup = Task {}
            return
        }
        startup = Task { [weak self] in await self?.start() }
    }

    deinit {
        state.withLock { state in
            state.pollTask?.cancel()
            state.flushTask?.cancel()
        }
        cancelLifecycleSubscription()
    }

    // MARK: Experiments

    /// The variant this user is assigned, recording an exposure the first time. Deterministic and
    /// synchronous. Returns `control` until `ready()` finishes, unless `bootstrapConfig` has the key.
    public func getVariant(_ experimentKey: String, trackExposure: Bool = true) -> String {
        guard enabled, !experimentKey.isEmpty else { return Constants.controlVariant }
        // Once a real config lands it is the whole truth, or a stopped experiment keeps being
        // served from the binary's bootstrap.
        let experiment =
            config.hasConfig
            ? config.experiment(experimentKey)
            : config.experiment(experimentKey) ?? bootstrap[experimentKey]
        guard let experiment else { return Constants.controlVariant }
        return assign(experiment, trackExposure: trackExposure)
    }

    /// The value the running experiment on `name` gives this user, recording an exposure like
    /// `getVariant`. Returns `defaultValue` when no experiment sets it, the arm sets no value, or
    /// the value is another type. Text per language gives the text for the app's language (see
    /// `setLocale`), or `defaultValue` when it has none.
    public func getParameter(_ name: String, default defaultValue: String, trackExposure: Bool = true)
        -> String
    {
        guard let value = parameter(name, trackExposure) else { return defaultValue }
        if let text = value.stringValue { return text }
        return TranslatedText.text(value, locale: shownLocale) ?? defaultValue
    }

    public func getParameter(_ name: String, default defaultValue: Bool, trackExposure: Bool = true)
        -> Bool
    {
        parameter(name, trackExposure)?.boolValue ?? defaultValue
    }

    public func getParameter(_ name: String, default defaultValue: Double, trackExposure: Bool = true)
        -> Double
    {
        parameter(name, trackExposure)?.numberValue ?? defaultValue
    }

    /// A number that is not a whole `Int` serves the default.
    public func getParameter(_ name: String, default defaultValue: Int, trackExposure: Bool = true)
        -> Int
    {
        guard let number = parameter(name, trackExposure)?.numberValue,
            number.rounded() == number, let whole = Int(exactly: number)
        else { return defaultValue }
        return whole
    }

    /// The language the app shows, such as `pt-BR`, for parameters with text per language. Call it
    /// where the app picks or changes its language; `nil` goes back to `TrevoOptions.locale`, or
    /// to the localization the app runs in.
    public func setLocale(_ locale: String?) {
        let next = Self.cleanLocale(locale)
        let changed = state.withLock { state -> Bool in
            guard state.locale != next else { return false }
            state.locale = next
            return true
        }
        if changed { emitChange() }
    }

    // MARK: Events

    /// Queues an event. Property values are strings, numbers, booleans, arrays, objects or null.
    /// - Parameter insertId: A stable idempotency key, so a replayed event is recorded once.
    public func track(_ eventName: String, properties: [String: TrevoValue]? = nil, insertId: String? = nil) {
        guard enabled else { return }
        enqueue(
            PendingEvent(
                name: eventName, properties: properties, insertId: insertId,
                timestamp: Timestamp.iso(Date())))
    }

    /// Sends queued events now.
    public func flush() async {
        await events.flush()
    }

    // MARK: Identity

    /// Associates later events with a known user and assigns from that user id, as every other
    /// Trevo SDK does. Persisted, so the next launch keeps it.
    public func identify(_ userId: String) {
        guard enabled else { return }
        guard !JSString.isBlank(userId) else {
            onError(TrevoError("identify requires a userId"))
            return
        }
        guard userId.utf16.count <= Constants.maxUserIdLength else {
            onError(TrevoError("identify userId exceeds \(Constants.maxUserIdLength) characters"))
            return
        }
        state.withLock { state in
            if state.userId != userId { state.exposures.clear() }
            state.userRevision += 1
            state.userId = userId
        }
        storage.write(StorageKey.userId, userId, failure: "Failed to persist user id")
        emitChange()
    }

    /// Clears the user and starts a new anonymous id, so the device is a new participant. Call on sign-out.
    public func reset() {
        guard enabled else { return }
        let minted = Self.newId()
        state.withLock { state in
            state.userRevision += 1
            state.anonymousRevision += 1
            state.assignmentRevision += 1
            state.userId = nil
            state.anonymousId = minted
            state.assignments.removeAll()
            state.assignmentsUnreadable = false
            state.exposures.clear()
        }
        storage.remove(StorageKey.assignments, failure: "Failed to clear experiment assignments")
        storage.remove(StorageKey.userId, failure: "Failed to clear stored user id")
        storage.write(StorageKey.anonymousId, minted, failure: "Failed to persist anonymous id")
        emitChange()
    }

    /// This install's anonymous id, once stored state has loaded.
    public var anonymousId: String? {
        state.withLock { $0.anonymousId }
    }

    // MARK: Lifecycle

    /// True once stored state has loaded and the first config fetch has settled.
    public var isReady: Bool {
        state.withLock { $0.isReady }
    }

    /// Returns once stored state has loaded and the first config fetch has settled.
    public func ready() async {
        await startup.value
    }

    /// Calls `listener` on the main thread after anything that can change what the getters return:
    /// config, identity, `setLocale`, or startup finishing.
    @discardableResult
    public func onChange(_ listener: @escaping @MainActor @Sendable () -> Void) -> TrevoSubscription {
        let id = UUID()
        state.withLock { $0.listeners[id] = listener }
        return TrevoSubscription { [weak self] in
            self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) }
        }
    }

    /// Stops polling and lifecycle observation, then sends and persists what is queued.
    public func shutdown() async {
        state.withLock { $0.stopped = true }
        await startup.value
        stopTimers()
        cancelLifecycleSubscription()
        drainPending()
        paywalls.stop()
        await paywalls.idle()
        await events.flush()
        events.persist()
        await storage.drain()
        state.withLock { $0.listeners.removeAll() }
    }

    // MARK: Internals

    private func start() async {
        let stored = await storage.read([
            StorageKey.anonymousId, StorageKey.userId, StorageKey.assignments,
            StorageKey.config, StorageKey.queue, StorageKey.paywalls,
        ])
        restore(stored)
        paywalls.hydrate(stored[StorageKey.paywalls] ?? StoredValue(value: nil, failed: false))
        config.hydrate(stored[StorageKey.config] ?? StoredValue(value: nil, failed: false))
        events.hydrate(stored[StorageKey.queue] ?? StoredValue(value: nil, failed: false))
        drainPending()

        guard !isStopped else { return }
        keepLifecycleSubscription(lifecycle.subscribe { [weak self] status in self?.handle(status) })
        startTimers()
        await refreshConfig()

        guard !isStopped else { return }
        state.withLock { state in
            state.canEmitChanges = true
            state.isReady = true
        }
        emitChange()
        Task { await events.flush() }
    }

    private func restore(_ stored: [String: StoredValue]) {
        let anonymous = stored[StorageKey.anonymousId]
        let user = stored[StorageKey.userId]
        let savedAssignments = stored[StorageKey.assignments]
        let restoredAssignments = parseAssignments(savedAssignments)
        let minted = Self.newId()
        // One section, so no getVariant on another thread assigns between the identity and its arms.
        let (persistMinted, clearUser) = state.withLock { state -> (Bool, Bool) in
            var persistMinted = false
            if state.anonymousRevision == 0 {
                if let value = anonymous?.value, !JSString.isBlank(value) {
                    state.anonymousId = value
                } else {
                    // Minted once per install; losing it re-buckets the device.
                    state.anonymousId = minted
                    persistMinted = anonymous?.failed != true
                }
            }
            var clearUser = false
            if state.userRevision == 0, let value = user?.value {
                if Self.isValidUserId(value) {
                    state.userId = value
                } else {
                    clearUser = true
                }
            }
            if state.assignmentRevision == 0 {
                state.assignments.merge(restoredAssignments) { _, stored in stored }
                state.assignmentsUnreadable = savedAssignments?.failed == true
            }
            return (persistMinted, clearUser)
        }
        if persistMinted {
            storage.write(StorageKey.anonymousId, minted, failure: "Failed to persist anonymous id")
        }
        if clearUser {
            storage.remove(StorageKey.userId, failure: "Failed to clear invalid stored user id")
        }
    }

    private func parseAssignments(_ stored: StoredValue?) -> [String: String] {
        guard let raw = stored?.value else { return [:] }
        guard let object = try? JSON.decode(raw).objectValue else {
            onError(TrevoError("Stored experiment assignments unusable"))
            return [:]
        }
        return object.compactMapValues(\.stringValue)
    }

    private func assign(_ experiment: ExperimentConfig, trackExposure: Bool) -> String {
        let key = experiment.experimentKey
        let nowMs = Timestamp.milliseconds(Date())
        let outcome = state.withLock { state -> (variant: String, remember: Bool, expose: Bool)? in
            guard
                let bucketingId = Assignment.bucketingId(
                    userId: state.userId, anonymousId: state.anonymousId),
                // An old binary has no code for a newer variant, so it stays in control.
                VersionGate.admits(
                    appVersion: appVersion, platform: Constants.platform,
                    minimum: experiment.minAppVersion)
            else { return nil }

            let assignmentKey = "\(bucketingId):\(key)"
            let stored = state.assignments[assignmentKey]
            let remembered = experiment.variants.contains { $0.name == stored } ? stored : nil
            // A shipped winner outranks a remembered arm without replacing it, so a reopened test
            // puts each device back on its own arm. A device with none remembers what it was served.
            let variant =
                Assignment.settledVariant(experiment) ?? remembered
                ?? Assignment.assignVariant(bucketingId, experiment)
            let remember = remembered == nil && stored != variant
            if remember { state.assignments[assignmentKey] = variant }
            let expose =
                trackExposure
                && state.exposures.shouldLog(
                    identity: bucketingId, experimentKey: key, variant: variant, nowMs: nowMs)
            return (variant, remember, expose)
        }
        guard let outcome else { return Constants.controlVariant }

        if outcome.remember { persistAssignments() }
        if outcome.expose {
            enqueue(
                PendingEvent(
                    name: Constants.exposureEvent,
                    properties: ["experimentKey": .string(key), "variantName": .string(outcome.variant)],
                    insertId: nil, timestamp: Timestamp.iso(Date())))
        }
        return outcome.variant
    }

    private func parameter(_ name: String, _ trackExposure: Bool) -> TrevoValue? {
        guard enabled, !name.isEmpty else { return nil }
        // Same source rule as getVariant: a loaded config replaces the bootstrap outright.
        let configs = config.hasConfig ? config.all : config.all + bootstrap.all
        guard let experiment = Parameters.experiment(setting: name, in: configs) else { return nil }
        let variant = assign(experiment, trackExposure: trackExposure)
        return Parameters.value(name, in: experiment, variant: variant)
    }

    /// Also the locale a remote paywall page is told.
    var shownLocale: String? {
        state.withLock { $0.locale } ?? defaultLocale ?? Self.appLocale
    }

    func report(_ error: TrevoError) {
        onError(error)
    }

    // A page whose download failed offline is tried again after any refresh the server answers,
    // a 304 included, not only when config changes.
    private func refreshConfig() async {
        if await config.refresh() == .answered { paywalls.downloadMissing() }
    }

    // The localization the app runs in, which can differ from the device's first language.
    private static var appLocale: String? {
        cleanLocale(Bundle.main.preferredLocalizations.first)
            ?? cleanLocale(Locale.preferredLanguages.first)
    }

    private static func cleanLocale(_ locale: String?) -> String? {
        guard let locale else { return nil }
        let trimmed = JSString.trimmed(locale)
        return trimmed.isEmpty ? nil : String(decoding: trimmed, as: UTF16.self)
    }

    private func persistAssignments() {
        storage.perform("Failed to persist experiment assignments") { [state] storage in
            // Read when the write runs, so a burst of assignments ends with the newest snapshot.
            guard let snapshot = state.withLock({ $0.assignmentsUnreadable ? nil : $0.assignments })
            else { return }
            if snapshot.isEmpty {
                try storage.remove(StorageKey.assignments)
            } else {
                try storage.write(
                    StorageKey.assignments,
                    value: try JSON.encodeString(snapshot.mapValues(TrevoValue.string)))
            }
        }
    }

    private func enqueue(_ pending: PendingEvent) {
        let identity = state.withLock { state -> (userId: String?, anonymousId: String?)? in
            guard state.userId != nil || state.anonymousId != nil else {
                // track() is synchronous but identity loads from storage, so hold early events.
                if state.pending.count >= Constants.maxPendingEvents { state.pending.removeFirst() }
                state.pending.append(pending)
                return nil
            }
            return (state.userId, state.anonymousId)
        }
        guard let identity else { return }

        let built = EventBuilder.build(
            EventInput(
                eventName: pending.name, properties: pending.properties, userId: identity.userId,
                anonymousId: identity.anonymousId, timestamp: pending.timestamp,
                sdkVersion: TrevoSDKVersion.sdkVersion, appVersion: appVersion,
                insertId: pending.insertId ?? Self.newId()))
        switch built {
        case .success(let event):
            events.enqueue(event)
        case .failure(let reason):
            onError(TrevoError("Trevo track(\"\(pending.name)\") ignored: \(reason.rawValue)"))
        }
    }

    /// Replays events tracked before identity loaded, keeping their original timestamps.
    private func drainPending() {
        let pending = state.withLock { state -> [PendingEvent] in
            defer { state.pending.removeAll() }
            return state.pending
        }
        pending.forEach(enqueue)
    }

    private func handle(_ status: TrevoAppStatus) {
        guard !isStopped else { return }
        switch status {
        case .background:
            // Timers stop firing once suspended, and the process can be killed without warning.
            stopTimers()
            // On disk before the flush starts: the system can suspend the app mid-request.
            events.persist()
            BackgroundTime.run { [events, storage] in
                await events.flush()
                await storage.drain()
            }
        case .active:
            startTimers()
            // The only kill switch that needs no App Store release.
            Task { await refreshConfig() }
            Task { await events.flush() }
        }
    }

    private func startTimers() {
        state.withLock { state in
            guard !state.stopped else { return }
            if state.pollTask == nil {
                state.pollTask = Self.repeating(every: pollInterval) { [weak self] in
                    guard let self else { return false }
                    await self.refreshConfig()
                    return true
                }
            }
            if state.flushTask == nil {
                state.flushTask = Self.repeating(every: flushInterval) { [weak self] in
                    guard let self else { return false }
                    await self.events.flush()
                    return true
                }
            }
        }
    }

    private func stopTimers() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            defer {
                state.pollTask = nil
                state.flushTask = nil
            }
            return [state.pollTask, state.flushTask].compactMap { $0 }
        }
        tasks.forEach { $0.cancel() }
    }

    /// Keeps the startup subscription unless shutdown already ran, in which case it is cancelled.
    private func keepLifecycleSubscription(_ subscription: TrevoSubscription) {
        let kept = state.withLock { state -> Bool in
            guard !state.stopped, state.lifecycleSubscription == nil else { return false }
            state.lifecycleSubscription = subscription
            return true
        }
        if !kept { subscription.cancel() }
    }

    private func cancelLifecycleSubscription() {
        let subscription = state.withLock { state -> TrevoSubscription? in
            defer { state.lifecycleSubscription = nil }
            return state.lifecycleSubscription
        }
        subscription?.cancel()
    }

    private var isStopped: Bool {
        state.withLock { $0.stopped }
    }

    fileprivate func emitChange() {
        let listeners = state.withLock { state in
            state.canEmitChanges ? Array(state.listeners.values) : []
        }
        for listener in listeners {
            Task { @MainActor in listener() }
        }
    }

    private static func repeating(
        every interval: TimeInterval, _ body: @escaping @Sendable () async -> Bool
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                if !(await body()) { return }
            }
        }
    }

    private static let secretKeyPrefixes = ["tsk_secret_", "tsk_admin_"]

    private static func keyRefusal(_ apiKey: String) -> String? {
        if apiKey.isEmpty { return "TrevoClient requires an apiKey; serving control and sending nothing" }
        if secretKeyPrefixes.contains(where: apiKey.hasPrefix) {
            return
                "TrevoClient refuses a secret key: an app can be unpacked, so use a Mobile key (tsk_live_...)"
        }
        return nil
    }

    /// `Task.sleep` takes nanoseconds as a UInt64, so an interval past a day would trap.
    private static func clamped(_ interval: TimeInterval, from minimum: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return 86_400 }
        return min(max(minimum, interval), 86_400)
    }

    private static func isValidUserId(_ value: String) -> Bool {
        !JSString.isBlank(value) && value.utf16.count <= Constants.maxUserIdLength
    }

    private static func newId() -> String {
        UUID().uuidString.lowercased()
    }

    private static let logger = Logger(subsystem: "com.trevosdk", category: "TrevoSDK")

    private static let log: ErrorHandler = { error in
        logger.warning("[Trevo] \(error.message, privacy: .public)")
    }
}

/// Lets the config store, built before the client exists, report changes back to it.
private final class ChangeRelay: @unchecked Sendable {
    weak var target: TrevoClient?

    func emit() {
        target?.emitChange()
    }
}
