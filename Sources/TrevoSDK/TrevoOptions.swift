import Foundation

public struct TrevoOptions: Sendable {
    /// A Mobile key (`tsk_live_...`). A shipped binary can be unpacked, so never ship a secret key.
    public var apiKey: String
    /// This build's version, sent on every event and compared with `minAppVersion`. Defaults to
    /// `CFBundleShortVersionString`. Without one, a gated experiment returns control.
    public var appVersion: String?
    /// The language the app shows, such as `pt-BR`, for parameters with text per language.
    /// Defaults to the localization the app runs in; `setLocale` changes it at runtime.
    public var locale: String?
    /// Assign against this before storage and the network have answered.
    public var bootstrapConfig: [ExperimentConfig]
    public var configURL: URL
    public var ingestionURL: URL
    /// Config is also refreshed every time the app returns to the foreground.
    public var pollInterval: TimeInterval
    /// Queued events are also sent when the app moves to the background.
    public var flushInterval: TimeInterval
    /// Capped at 500 by the server.
    public var maxBatchSize: Int
    public var storage: (any TrevoStorage)?
    public var transport: (any TrevoTransport)?
    public var lifecycle: (any TrevoLifecycle)?
    /// Background failures. Defaults to the unified log.
    public var onError: (@Sendable (TrevoError) -> Void)?

    public init(
        apiKey: String,
        appVersion: String? = TrevoOptions.bundleVersion,
        locale: String? = nil,
        bootstrapConfig: [ExperimentConfig] = [],
        configURL: URL = TrevoOptions.defaultConfigURL,
        ingestionURL: URL = TrevoOptions.defaultIngestionURL,
        pollInterval: TimeInterval = 300,
        flushInterval: TimeInterval = 15,
        maxBatchSize: Int = 50,
        storage: (any TrevoStorage)? = nil,
        transport: (any TrevoTransport)? = nil,
        lifecycle: (any TrevoLifecycle)? = nil,
        onError: (@Sendable (TrevoError) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.appVersion = appVersion
        self.locale = locale
        self.bootstrapConfig = bootstrapConfig
        self.configURL = configURL
        self.ingestionURL = ingestionURL
        self.pollInterval = pollInterval
        self.flushInterval = flushInterval
        self.maxBatchSize = maxBatchSize
        self.storage = storage
        self.transport = transport
        self.lifecycle = lifecycle
        self.onError = onError
    }

    public static let defaultConfigURL = URL(string: "https://api.trevosdk.com/v1/config")!
    public static let defaultIngestionURL = URL(string: "https://ingest.trevosdk.com/v1/events")!

    /// The app's marketing version from its Info.plist.
    public static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
