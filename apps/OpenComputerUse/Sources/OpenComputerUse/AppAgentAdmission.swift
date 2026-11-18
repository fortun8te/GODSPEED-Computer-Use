import Foundation

/// Coordinates request threads in the app agent. Callers must classify requests
/// before entering and keep any protected work inside the admitted closure.
final class AppAgentAdmission: @unchecked Sendable {
    enum Mode {
        case browserRead(client: String)
        case exclusive
    }

    struct Timeout: LocalizedError {
        var errorDescription: String? { "The app agent is busy. Try again." }
    }

    static let shared = AppAgentAdmission()

    private let condition = NSCondition()
    private let readerLimit = 3
    private var readers: Set<String> = []
    private var exclusive = false
    private var queuedWriters = 0

    var waitingExclusiveCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return queuedWriters
    }

    func withAdmission<T>(_ mode: Mode, timeout: TimeInterval = 45, _ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        if case .browserRead(let client) = mode, !client.isEmpty {
            condition.lock()
            while exclusive || queuedWriters > 0 || readers.count >= readerLimit || readers.contains(client) {
                guard condition.wait(until: deadline) else {
                    condition.unlock()
                    throw Timeout()
                }
            }
            readers.insert(client)
            condition.unlock()
            defer {
                condition.lock()
                readers.remove(client)
                condition.broadcast()
                condition.unlock()
            }
            return try body()
        }

        condition.lock()
        queuedWriters += 1
        while exclusive || !readers.isEmpty {
            guard condition.wait(until: deadline) else {
                queuedWriters -= 1
                condition.broadcast()
                condition.unlock()
                throw Timeout()
            }
        }
        queuedWriters -= 1
        exclusive = true
        condition.unlock()
        defer {
            condition.lock()
            exclusive = false
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }
}
