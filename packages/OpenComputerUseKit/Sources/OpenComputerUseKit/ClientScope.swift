import CryptoKit
import Foundation

/// Which agent the current thread is working for.
///
/// Several agents (each its own `OpenComputerUse mcp` process) share one background app agent. What an agent
/// was last shown, the app it last used, and its browser tab must stay its own; otherwise one agent's
/// `browser read` lands in another's tab, or its text goes to the app the other one touched last.
/// The proxy names its client (`OPEN_COMPUTER_USE_CLIENT`, by default the MCP proxy process), and
/// the app agent runs every request inside `ClientScope.with`. Outside one, the scope is "main".
public enum ClientScope {
    private static let threadKey = "godspeed.client-scope"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastActive: [String: Date] = [:]
    /// Requests running right now, per client. A call that runs longer than the activity window still counts.
    nonisolated(unsafe) private static var running: [String: Int] = [:]

    public static var current: String {
        (Thread.current.threadDictionary[threadKey] as? String) ?? "main"
    }

    /// Runs `body` as `client` on this thread.
    public static func with<T>(_ client: String?, _ body: () throws -> T) rethrows -> T {
        try withScope(sanitized(client), body)
    }

    /// Reinstates an already resolved identity on a worker thread.
    static func withScope<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[threadKey]
        dictionary[threadKey] = name
        lock.lock(); lastActive[name] = Date(); running[name, default: 0] += 1; lock.unlock()
        defer {
            lock.lock()
            lastActive[name] = Date()
            running[name] = (running[name] ?? 1) - 1
            if running[name] == 0 { running[name] = nil }
            lock.unlock()
            if let previous { dictionary[threadKey] = previous } else { dictionary.removeObject(forKey: threadKey) }
        }
        return try body()
    }

    /// Test support: forgets recent activity, so a test that expects "no other agent is active" starts clean.
    static func forgetActivityForTesting() {
        lock.lock(); lastActive = [:]; lock.unlock()
    }

    /// Requests running now, across every client. The app agent refuses to exit or be replaced while this is above zero.
    public static var requestsInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return running.values.reduce(0, +)
    }

    public static func sanitized(_ client: String?) -> String {
        guard let client, !client.isEmpty else { return "main" }
        let isSafe = client.utf8.count <= 40 && client.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
        if isSafe, client != "main", !client.hasPrefix("hash-") { return client }
        return "hash-" + SHA256.hash(data: Data(client.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a client other than `client` ran a request in the last `seconds`. State shared by all clients
    /// (window pins, parked windows) is not reset under an agent that is still working.
    public static func othersActive(than client: String? = nil, within seconds: TimeInterval = 30) -> Bool {
        let own = client ?? current
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        lastActive = lastActive.filter { now.timeIntervalSince($0.value) < 3_600 }
        if running.contains(where: { $0.key != own && $0.value > 0 }) { return true }
        return lastActive.contains { $0.key != own && now.timeIntervalSince($0.value) < seconds }
    }

    /// Clients that are running a request now, or ran one in the last `seconds`.
    public static func activeCount(within seconds: TimeInterval = 30) -> Int {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        let names = Set(running.filter { $0.value > 0 }.keys)
            .union(lastActive.filter { now.timeIntervalSince($0.value) < seconds }.keys)
        return names.count
    }
}

/// One value per client scope, made on first use. Values of clients not seen for two hours are dropped.
final class ScopedStore<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (value: Value, used: Date)] = [:]
    private let make: (String) -> Value
    private let drop: (Value) -> Void

    init(make: @escaping (String) -> Value, drop: @escaping (Value) -> Void = { _ in }) {
        self.make = make
        self.drop = drop
    }

    var existing: Value? {
        lock.lock()
        defer { lock.unlock() }
        return values[ClientScope.current]?.value
    }

    var current: Value {
        let scope = ClientScope.current
        let now = Date()
        var stale: [Value] = []
        lock.lock()
        if values.count > 6 {
            for (key, entry) in values where key != scope && now.timeIntervalSince(entry.used) > 7_200 {
                stale.append(entry.value)
                values[key] = nil
            }
        }
        let value = values[scope]?.value ?? make(scope)
        values[scope] = (value, now)
        lock.unlock()
        stale.forEach(drop)
        return value
    }
}
