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

    public init() {}

    /// JSON-RPC IDs are scoped to this connection. String and numeric IDs are distinct.
    @discardableResult
    public func receive(_ line: String, rpcLine: String?) -> Bool {
        let rpc = rpcLine.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        if rpc?["method"] as? String == "notifications/cancelled" {
            let params = rpc?["params"] as? [String: Any]
            guard let id = Self.requestID(params?["requestId"]) else { return true }
            condition.lock()
            let requests = ([active].compactMap { $0 } + pending).filter { $0.id == id }
            condition.unlock()
            for request in requests { request.cancellation.cancel() }
            return true
        }
        condition.lock()
        defer { condition.unlock() }
        guard !closed, pending.count < 16 else { return false }
        pending.append(Request(line: line, cancellation: RequestCancellation(), id: Self.requestID(rpc?["id"])))
        condition.signal()
        return true
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
