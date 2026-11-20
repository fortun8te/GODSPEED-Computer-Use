import Foundation

/// Cooperative cancellation leaves cleanup and the receipt on the request worker.
public final class RequestCancellation: @unchecked Sendable {
    @TaskLocal public static var current: RequestCancellation?

    public struct Cancelled: LocalizedError {
        public var deliveryState: DeliveryState = .outcomeUnknown

        public var errorDescription: String? { "Request cancelled. Inspect any steps already in flight before retrying." }
    }

    private let lock = NSLock()
    private var cancelled = false
    private var disconnected = false
    private var callback: (@Sendable (Bool) -> Void)?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel(disconnected: Bool = false) {
        lock.withLock {
            guard !cancelled || (disconnected && !self.disconnected) else { return }
            cancelled = true
            self.disconnected = self.disconnected || disconnected
            callback?(disconnected)
        }
    }

    /// The callback must finish promptly and may not re-enter the token.
    public func onCancel(_ callback: (@Sendable (Bool) -> Void)?) {
        lock.withLock {
            self.callback = callback
            if cancelled { callback?(disconnected) }
        }
    }

    public static var requested: Bool { current?.isCancelled == true }

    public static func check(delivery: DeliveryState = .outcomeUnknown) throws {
        if requested { throw Cancelled(deliveryState: delivery) }
    }
}
