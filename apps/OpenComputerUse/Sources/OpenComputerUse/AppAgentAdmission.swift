import Foundation
import OpenComputerUseKit

/// Coordinates request workers in the app agent. Desktop work remains exclusive.
final class AppAgentAdmission: @unchecked Sendable {
    enum Mode: Equatable {
        case browserRead(client: String)
        case browserPeek(client: String)
        case browserTabWrite(client: String, tabID: Int)
        case exclusive

        var client: String? {
            switch self {
            case .browserRead(let client), .browserPeek(let client), .browserTabWrite(let client, _): client
            case .exclusive: nil
            }
        }

        var tabWrite: Int? {
            if case .browserTabWrite(_, let tabID) = self { return tabID }
            return nil
        }

        var isPeek: Bool {
            if case .browserPeek = self { return true }
            return false
        }
    }

    struct Timeout: LocalizedError {
        var errorDescription: String? { "The app agent is busy. Try again." }
    }

    /// Thrown when the desktop gate cannot be re-acquired after an inference wait. The request is cancelled.
    struct AdmissionLost: LocalizedError {
        var errorDescription: String? { "Desktop admission was lost mid-request. Inspect the steps that already ran before repeating them." }
    }

    static let shared = AppAgentAdmission()
    static let connectionLimit = 32
    static let queueLimit = 32

    private struct Ticket {
        let id = UUID()
        let mode: Mode
    }

    private let condition = NSCondition()
    private let now: @Sendable () -> TimeInterval
    private let sharedLimit: Int
    let parallelTabWrites: Bool
    private var active: [UUID: Mode] = [:]
    private var queued: [Ticket] = []
    private var writesWhileReaderWaiting = 0
    private var generation: UInt64 = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        let requested = environment["OPEN_COMPUTER_USE_PARALLEL_READS"].flatMap(Int.init) ?? 3
        sharedLimit = min(4, max(1, requested))
        parallelTabWrites = ["1", "true", "yes", "on"].contains(
            environment["OPEN_COMPUTER_USE_PARALLEL_BROWSER_WRITES"]?.lowercased() ?? ""
        )
    }

    var waitingExclusiveCount: Int {
        condition.withLock { queued.count { $0.mode == .exclusive } }
    }

    var waitingCount: Int { condition.withLock { queued.count } }

    private func nextTicket() -> UUID? {
        func compatible(_ mode: Mode) -> Bool {
            guard let client = mode.client, active.count < sharedLimit else { return false }
            return active.values.allSatisfy { other in
                guard other != .exclusive, other.client != client, !(mode.isPeek && other.isPeek) else { return false }
                switch (mode.tabWrite, other.tabWrite) {
                case (nil, nil): return true
                case (let tab?, let otherTab?): return tab != otherTab
                default: return false
                }
            }
        }

        // Peeks wait here before consuming a reader slot. At most one group
        // (three preview helpers) can run, and other reads remain eligible.
        let shared = queued.first { compatible($0.mode) }
        guard let writer = queued.first(where: { $0.mode == .exclusive }) else { return shared?.id }
        if writesWhileReaderWaiting >= 2, let shared { return shared.id }
        return active.isEmpty ? writer.id : nil
    }

    private func acquire(_ ticket: Ticket, timeout: TimeInterval) throws -> UInt64 {
        guard timeout.isFinite, timeout >= 0 else { throw Timeout() }
        let deadline = now() + timeout
        condition.lock()
        defer { condition.unlock() }
        guard queued.count < Self.queueLimit else { throw Timeout() }
        queued.append(ticket)
        defer {
            queued.removeAll { $0.id == ticket.id }
            condition.broadcast()
        }
        while nextTicket() != ticket.id {
            try RequestCancellation.check(delivery: .notSent)
            let left = deadline - now()
            guard left > 0 else { throw Timeout() }
            _ = condition.wait(until: Date().addingTimeInterval(min(left, 0.05)))
        }
        try RequestCancellation.check(delivery: .notSent)
        // Eligibility may have changed while this thread slept. A released
        // gate does not renew the queued request's deadline. Zero remains a
        // nonblocking attempt and is allowed only when no wait was needed.
        guard timeout == 0 || now() < deadline else { throw Timeout() }
        active[ticket.id] = ticket.mode
        generation &+= 1
        if ticket.mode == .exclusive {
            writesWhileReaderWaiting = queued.contains { $0.mode != .exclusive } ? writesWhileReaderWaiting + 1 : 0
        } else {
            writesWhileReaderWaiting = 0
        }
        return generation
    }

    private func release(_ ticket: Ticket) {
        condition.withLock {
            active.removeValue(forKey: ticket.id)
            condition.broadcast()
        }
    }

    func withAdmission<T>(_ requested: Mode, timeout: TimeInterval = 45, _ body: () throws -> T) throws -> T {
        let mode = requested.client == "" || (requested.tabWrite != nil && !parallelTabWrites) ? .exclusive : requested
        let ticket = Ticket(mode: mode)
        _ = try acquire(ticket, timeout: timeout)
        defer { release(ticket) }
        if mode == .exclusive, let token = RequestCancellation.current {
            return try RequestInferenceAdmission.$withoutExclusive.withValue({ [self] work in
                let before = condition.withLock { generation }
                release(ticket)
                let result = work()
                // The caller can only continue with its prior observations if
                // no other admission intervened and it still owns the gate.
                // Losing the gate stops the request: a typed cancellation, never a silent nil.
                let after: UInt64
                do { after = try acquire(ticket, timeout: 2) } catch {
                    token.cancel()
                    throw AdmissionLost()
                }
                guard after == before &+ 1 else {
                    token.cancel()
                    throw AdmissionLost()
                }
                return result
            }, operation: body)
        }
        return try body()
    }
}
