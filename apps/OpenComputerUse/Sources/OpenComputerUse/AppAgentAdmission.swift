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
    private let readerLimit: Int
    private var readers: Set<String> = []
    private var exclusive = false
    private var queuedWriters: [UUID] = []
    private var queuedReaders: [(ticket: UUID, client: String)] = []
    private var writesWhileReaderWaiting = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let requested = environment["OPEN_COMPUTER_USE_PARALLEL_READS"].flatMap { Int($0) } ?? 3
        readerLimit = min(4, max(1, requested))
    }

    /// An older read for an active client cannot use a slot yet. Independent clients can still proceed.
    private func nextReader() -> UUID? {
        queuedReaders.first { !readers.contains($0.client) }?.ticket
    }

    // Prefer a queued writer, but after two exclusive admissions give the
    // oldest eligible reader one turn before starting the next writer.
    private var readerTurnDue: Bool {
        writesWhileReaderWaiting >= 2 && nextReader() != nil
    }

    var waitingExclusiveCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return queuedWriters.count
    }

    func withAdmission<T>(_ mode: Mode, timeout: TimeInterval = 45, _ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        if case .browserRead(let client) = mode, !client.isEmpty {
            let ticket = UUID()
            condition.lock()
            queuedReaders.append((ticket, client))
            while exclusive || (!queuedWriters.isEmpty && !readerTurnDue)
                    || readers.count >= readerLimit || nextReader() != ticket {
                guard condition.wait(until: deadline) else {
                    queuedReaders.removeAll { $0.ticket == ticket }
                    condition.broadcast()
                    condition.unlock()
                    throw Timeout()
                }
            }
            queuedReaders.removeAll { $0.ticket == ticket }
            readers.insert(client)
            writesWhileReaderWaiting = 0
            condition.broadcast()
            condition.unlock()
            defer {
                condition.lock()
                readers.remove(client)
                condition.broadcast()
                condition.unlock()
            }
            return try body()
        }

        let ticket = UUID()
        condition.lock()
        queuedWriters.append(ticket)
        while exclusive || !readers.isEmpty || queuedWriters.first != ticket || readerTurnDue {
            guard condition.wait(until: deadline) else {
                queuedWriters.removeAll { $0 == ticket }
                condition.broadcast()
                condition.unlock()
                throw Timeout()
            }
        }
        queuedWriters.removeFirst()
        exclusive = true
        writesWhileReaderWaiting = queuedReaders.isEmpty ? 0 : writesWhileReaderWaiting + 1
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
