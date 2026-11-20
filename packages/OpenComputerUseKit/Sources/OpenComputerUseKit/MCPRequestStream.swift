import Foundation

/// Reads ahead so a cancellation or EOF can reach the serial request worker.
public final class MCPRequestStream: @unchecked Sendable {
    public struct Request: Sendable {
        public let line: String
        public let cancellation: RequestCancellation
        fileprivate let id: String?
    }

    private let condition = NSCondition()
    private var pending: [Request] = []
    private var active: Request?
    private var closed = false

    /// `busy` means the queue is full. The request is refused, and the active request keeps running.
    public enum Intake: Equatable, Sendable { case accepted, busy, closed }

    public static let busyCode = -32001

    public init() {}

    /// The reply for a refused line, in the same envelope the worker writes. Nil for a JSON-RPC notification.
    public static func busyEnvelope(for line: String) -> [String: Any]? {
        let envelope = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        guard envelope?["kind"] as? String == "mcp" else {
            return ["error": "The app agent is busy. Retry later."]
        }
        guard let rpcLine = envelope?["line"] as? String,
              let rpc = try? JSONSerialization.jsonObject(with: Data(rpcLine.utf8)) as? [String: Any],
              let id = rpc["id"]
        else { return nil }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                    "error": ["code": busyCode, "message": "Busy. Retry later."]]
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ["response": text]
    }

    /// JSON-RPC IDs are scoped to this connection. String and numeric IDs are distinct.
    @discardableResult
    public func receive(_ line: String, rpcLine: String?) -> Bool {
        intake(line, rpcLine: rpcLine) == .accepted
    }

    public func intake(_ line: String, rpcLine: String?) -> Intake {
        let rpc = rpcLine.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        if rpc?["method"] as? String == "notifications/cancelled" {
            let params = rpc?["params"] as? [String: Any]
            guard let id = Self.requestID(params?["requestId"]) else { return .accepted }
            condition.lock()
            let requests = ([active].compactMap { $0 } + pending).filter { $0.id == id }
            condition.unlock()
            for request in requests { request.cancellation.cancel() }
            return .accepted
        }
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return .closed }
        guard pending.count < 16 else { return .busy }
        pending.append(Request(line: line, cancellation: RequestCancellation(), id: Self.requestID(rpc?["id"])))
        condition.signal()
        return .accepted
    }

    public func next() -> Request? {
        condition.lock()
        defer { condition.unlock() }
        active = nil
        while pending.isEmpty && !closed { condition.wait() }
        guard !closed else { return nil }
        let request = pending.removeFirst()
        active = request
        return request
    }

    public func disconnect() {
        condition.lock()
        closed = true
        pending.removeAll()
        let cancellation = active?.cancellation
        condition.broadcast()
        condition.unlock()
        cancellation?.cancel(disconnected: true)
    }

    private static func requestID(_ value: Any?) -> String? {
        guard let value, value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
