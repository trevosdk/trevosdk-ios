import Foundation

/// Where downloaded pages live, by their SHA-256.
protocol PaywallPageFiles: Sendable {
    func read(_ sha256: String) throws -> Data?
    /// Atomic, so a crash mid-write never leaves half a page.
    func write(_ sha256: String, _ data: Data) throws
    func remove(_ sha256: String) throws
    func stored() throws -> Set<String>
}

/// `Application Support/trevosdk/paywalls`, next to the SDK's other storage and excluded from backup.
final class PaywallDirectory: PaywallPageFiles {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func standard() -> PaywallDirectory {
        PaywallDirectory(
            directory: FileStorage.standardDirectory().appendingPathComponent("paywalls", isDirectory: true))
    }

    func read(_ sha256: String) throws -> Data? {
        let url = file(sha256)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ sha256: String, _ data: Data) throws {
        try prepareDirectory()
        try data.write(to: file(sha256), options: Self.writeOptions)
    }

    func remove(_ sha256: String) throws {
        let url = file(sha256)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func stored() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Set(names.filter { $0.hasSuffix(".html") }.map { String($0.dropLast(5)) })
    }

    private func file(_ sha256: String) -> URL {
        directory.appendingPathComponent("\(sha256).html", isDirectory: false)
    }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
        private static let writeOptions: Data.WritingOptions = [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication,
        ]
    #else
        private static let writeOptions: Data.WritingOptions = [.atomic]
    #endif
}
