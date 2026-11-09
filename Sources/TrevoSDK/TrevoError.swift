/// A failure the SDK recovered from. Delivered to `TrevoOptions.onError`; never thrown.
public struct TrevoError: Error, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    init(_ message: String, cause: any Error) {
        self.message = "\(message): \(cause.localizedDescription)"
    }

    public var description: String { message }
}

typealias ErrorHandler = @Sendable (TrevoError) -> Void
