import Foundation

/// A local OS operation keeps the caller's deadline and cancellation while its
/// completion arrives on another thread. Work that has not started can be
/// abandoned; work already handed to macOS must be reconciled before retrying.
final class LocalOperation<Value>: @unchecked Sendable {
    let deadline: TimeInterval
    let cancellation: RequestCancellation?
    private let action: String
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var started = false
    private var abandoned = false
    private var result: Result<Value, Error>?

    init(timeout: TimeInterval, action: String,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.action = action
        self.now = now
        cancellation = RequestCancellation.current
        let current = now()
        let inherited = BrowserCallBudget.activeDeadline
        let requested = current + timeout
        guard current.isFinite, timeout.isFinite, timeout > 0, requested.isFinite,
              inherited?.isFinite != false else {
            throw ComputerUseError.timedOut("The \(action) time budget is unavailable.", delivery: .notSent)
        }
        deadline = min(requested, inherited ?? requested)
        try check()
    }

    var remaining: TimeInterval { deadline - now() }

    /// Check preparation without claiming that any native action was sent.
    func check() throws {
        try lock.withLock { try checkLocked() }
    }

    /// Call immediately before handing the operation to macOS. This also stops
    /// a scheduled worker from starting after its waiting caller has left.
    func begin() throws {
        try lock.withLock {
            try checkLocked()
            guard !started, result == nil else {
                throw ComputerUseError.stateUnavailable("The \(action) operation was already dispatched.")
            }
            started = true
        }
    }

    func complete(_ value: Result<Value, Error>) {
        lock.withLock {
            guard !abandoned, result == nil else { return }
            result = value
            wake.signal()
        }
    }

    /// A synchronous native worker still reports through the same one-shot
    /// completion as callback-based operations.
    func perform(_ body: () throws -> Value) {
        do {
            try begin()
            complete(.success(try body()))
        } catch {
            complete(.failure(error))
        }
    }

    func wait() throws -> Value {
        while true {
            let outcome: Result<Value, Error>? = try lock.withLock {
                do { try checkLocked() }
                catch {
                    abandoned = true
                    throw error
                }
                return result
            }
            if let outcome { return try outcome.get() }
            // Do not replace the cancellation callback owned by the request
            // transport. Polling bounds the wait and leaves its cleanup intact.
            _ = wake.wait(timeout: .now() + max(0, min(0.05, remaining)))
        }
    }

    private func checkLocked() throws {
        let delivery: DeliveryState = started ? .outcomeUnknown : .notSent
        if cancellation?.isCancelled == true {
            throw RequestCancellation.Cancelled(deliveryState: delivery)
        }
        let left = remaining
        guard !abandoned, left.isFinite, left > 0 else {
            throw ComputerUseError.timedOut(
                started ? "macOS did not confirm \(action) within the request's time budget. Inspect the app before retrying."
                    : "The \(action) time budget ended before dispatch. Nothing was sent.",
                delivery: delivery
            )
        }
    }
}
