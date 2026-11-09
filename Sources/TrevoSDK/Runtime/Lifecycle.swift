import Foundation

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

public enum TrevoAppStatus: Sendable {
    case active
    case background
}

/// Cancels a listener. Keep it for as long as the listener should run.
public final class TrevoSubscription: Sendable {
    private let onCancel: Locked<(@Sendable () -> Void)?>

    public init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = Locked(onCancel)
    }

    public func cancel() {
        let action = onCancel.withLock { action -> (@Sendable () -> Void)? in
            defer { action = nil }
            return action
        }
        action?()
    }
}

/// Tells the SDK when the app moves between foreground and background.
public protocol TrevoLifecycle: Sendable {
    func subscribe(_ listener: @escaping @Sendable (TrevoAppStatus) -> Void) -> TrevoSubscription
}

struct SystemLifecycle: TrevoLifecycle {
    func subscribe(_ listener: @escaping @Sendable (TrevoAppStatus) -> Void) -> TrevoSubscription {
        #if canImport(UIKit) && !os(watchOS)
            let center = NotificationCenter.default
            let observers = [
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
                ) { _ in listener(.background) },
                center.addObserver(
                    forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
                ) { _ in listener(.active) },
            ]
            let tokens = UncheckedSendable(observers)
            return TrevoSubscription {
                tokens.value.forEach { center.removeObserver($0) }
            }
        #else
            return TrevoSubscription {}
        #endif
    }
}

/// NotificationCenter tokens are opaque objects that are safe to remove from any thread.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

enum BackgroundTime {
    /// Runs `work` with the time the system grants a suspending app, so the last flush finishes.
    /// `performExpiringActivity` is safe in app extensions, unlike `UIApplication.beginBackgroundTask`.
    static func run(_ work: @escaping @Sendable () async -> Void) {
        #if os(iOS) || os(tvOS) || os(visionOS)
            ProcessInfo.processInfo.performExpiringActivity(withReason: "Trevo event flush") {
                expired in
                guard !expired else { return }
                let done = DispatchSemaphore(value: 0)
                Task {
                    await work()
                    done.signal()
                }
                _ = done.wait(timeout: .now() + Constants.requestTimeout + 5)
            }
        #else
            Task { await work() }
        #endif
    }
}
