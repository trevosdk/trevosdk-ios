import Foundation

/// Where the SDK keeps its identity, assignments, config and event queue between launches.
/// Calls arrive one at a time on a background queue.
public protocol TrevoStorage: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ key: String, value: String) throws
    func remove(_ key: String) throws
}

/// One file per key in Application Support. Excluded from backup: the anonymous id identifies
/// this install, and a restored copy would put two devices on one id.
public final class FileStorage: TrevoStorage {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/trevosdk`; on macOS under the app's bundle id, since an app outside the
    /// sandbox shares Application Support with every other app; on tvOS in Caches, the only
    /// persistent-ish place tvOS gives an app, which the system may purge.
    public static func standard() -> FileStorage {
        let manager = FileManager.default
        #if os(tvOS)
            let base = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
        #else
            let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #endif
        var directory = base ?? manager.temporaryDirectory
        #if os(macOS)
            let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
            directory.appendPathComponent(owner, isDirectory: true)
        #endif
        return FileStorage(directory: directory.appendingPathComponent("trevosdk", isDirectory: true))
    }

    public func read(_ key: String) throws -> String? {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ key: String, value: String) throws {
        try prepareDirectory()
        try Data(value.utf8).write(to: file(key), options: Self.writeOptions)
    }

    public func remove(_ key: String) throws {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    // Readable after first unlock, so a background flush can still reach the queue.
    #if os(iOS) || os(tvOS) || os(visionOS)
        private static let writeOptions: Data.WritingOptions = [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication,
        ]
    #else
        private static let writeOptions: Data.WritingOptions = [.atomic]
    #endif
}

/// A stored value, or a read that failed. A failed read is never overwritten: the data is still
/// there, just unreadable for now (a locked device, say).
struct StoredValue: Sendable {
    let value: String?
    let failed: Bool
}

/// Runs storage calls in order on one background queue, so an older write can never land after a
/// newer one.
final class StorageQueue: @unchecked Sendable {
    private let storage: any TrevoStorage
    private let queue = DispatchQueue(label: "com.trevosdk.storage", qos: .utility)
    private let onError: ErrorHandler

    init(storage: any TrevoStorage, onError: @escaping ErrorHandler) {
        self.storage = storage
        self.onError = onError
    }

    func write(_ key: String, _ value: String, failure: String) {
        perform(failure) { try $0.write(key, value: value) }
    }

    func remove(_ key: String, failure: String) {
        perform(failure) { try $0.remove(key) }
    }

    func perform(_ failure: String, _ operation: @escaping @Sendable (any TrevoStorage) throws -> Void) {
        queue.async { [storage, onError] in
            do {
                try operation(storage)
            } catch {
                onError(TrevoError(failure, cause: error))
            }
        }
    }

    func read(_ keys: [String]) async -> [String: StoredValue] {
        await withCheckedContinuation { continuation in
            queue.async { [storage, onError] in
                var values: [String: StoredValue] = [:]
                for key in keys {
                    do {
                        values[key] = StoredValue(value: try storage.read(key), failed: false)
                    } catch {
                        onError(TrevoError("Failed to read stored \(key)", cause: error))
                        values[key] = StoredValue(value: nil, failed: true)
                    }
                }
                continuation.resume(returning: values)
            }
        }
    }

    /// Resolves once every call queued before it has run.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
