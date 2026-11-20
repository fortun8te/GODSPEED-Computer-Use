import Foundation

public struct AppTimingProfile: Codable, Sendable {
    public let bundleID: String
    public fileprivate(set) var axLatenciesMs: [Double] = []
    public fileprivate(set) var settleTimesMs: [Double] = []
    public fileprivate(set) var timeoutDates: [Date] = []
    public fileprivate(set) var unresponsiveUntil: Date?

    public var p50AXLatencyMs: Double { Self.percentile(axLatenciesMs, 0.50) }
    public var p95AXLatencyMs: Double { Self.percentile(axLatenciesMs, 0.95) }
    public var p95SettleMs: Double { Self.percentile(settleTimesMs, 0.95) }

    fileprivate init(bundleID: String) { self.bundleID = bundleID }
    fileprivate static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)]
    }
}

public final class AppTimingProfiles: @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [String: AppTimingProfile] = [:]
    private var clock: Date = .distantPast
    private func mutate(_ app: String, _ body: (inout AppTimingProfile) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var profile = profiles[app] ?? AppTimingProfile(bundleID: app)
        body(&profile); profiles[app] = profile
    }
    public init() {}

    public func record(app: String, axLatencyMs: Double) {
        guard axLatencyMs.isFinite, axLatencyMs >= 0 else { return }
        mutate(app) { $0.axLatenciesMs = Array(($0.axLatenciesMs + [axLatencyMs]).suffix(64)) }
    }
    public func recordTimeout(app: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var p = profiles[app] ?? AppTimingProfile(bundleID: app)
        p.timeoutDates = p.timeoutDates.filter { now.timeIntervalSince($0) <= 30 } + [now]
        if p.timeoutDates.count >= 3 { p.unresponsiveUntil = now.addingTimeInterval(10) }
        profiles[app] = p
    }
    public func recordSettle(app: String, ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        mutate(app) { $0.settleTimesMs = Array(($0.settleTimesMs + [ms]).suffix(64)) }
    }
    public func messagingTimeout(for app: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let p = profiles[app], p.axLatenciesMs.count >= 8 else { return 0.25 }
        if let until = p.unresponsiveUntil, Date() < until { return 0.05 }
        return min(1, max(0.05, p.p95AXLatencyMs * 3 / 1000))
    }
    public func settleBudget(for app: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let p = profiles[app], !p.settleTimesMs.isEmpty else { return 0.3 }
        return min(1.2, max(0.08, p.p95SettleMs / 1000))
    }
    public func isUnresponsive(app: String, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }; clock = now
        guard let until = profiles[app]?.unresponsiveUntil else { return false }
        return now < until
    }
    public func save(to url: URL) throws {
        lock.lock(); let snapshot = profiles; lock.unlock()
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
    public func load(from url: URL) throws {
        let loaded = try JSONDecoder().decode([String: AppTimingProfile].self, from: Data(contentsOf: url))
        lock.lock(); profiles = loaded; lock.unlock()
    }
}
