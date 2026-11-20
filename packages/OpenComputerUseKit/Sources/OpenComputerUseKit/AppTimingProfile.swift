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
    private func mutate(_ app: String, _ body: (inout AppTimingProfile) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var profile = profiles[app] ?? AppTimingProfile(bundleID: app)
        body(&profile); profiles[app] = profile
    }
    /// Lowest AX timeout, used for unresponsive apps. Also the latency under which a call counts as a fast success.
    static let floorTimeout: TimeInterval = 0.05
    public init() {}

    public func record(app: String, axLatencyMs: Double) {
        guard axLatencyMs.isFinite, axLatencyMs >= 0 else { return }
        mutate(app) { profile in
            profile.axLatenciesMs = Array((profile.axLatenciesMs + [axLatencyMs]).suffix(64))
            // A call that answers within the floor proves the app is responsive again.
            if axLatencyMs / 1000 < AppTimingProfiles.floorTimeout {
                profile.unresponsiveUntil = nil
                profile.timeoutDates = []
            }
        }
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
    /// AX messaging timeout for `app`: the floor while the app is marked unresponsive (checked first, so a
    /// frozen app never waits for enough samples), 0.25 s until 8 samples exist, then about 3x the p95.
    public func messagingTimeout(for app: String, now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let p = profiles[app] else { return 0.25 }
        if let until = p.unresponsiveUntil, now < until { return AppTimingProfiles.floorTimeout }
        guard p.axLatenciesMs.count >= 8 else { return 0.25 }
        return min(1, max(AppTimingProfiles.floorTimeout, p.p95AXLatencyMs * 3 / 1000))
    }
    public func settleBudget(for app: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let p = profiles[app], !p.settleTimesMs.isEmpty else { return 0.3 }
        return min(1.2, max(0.08, p.p95SettleMs / 1000))
    }
    public func isUnresponsive(app: String, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
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

/// The one timing profile set for this process, keyed by app pid. AX call sites share it, so a slow or
/// frozen app adapts every read, not only the read that noticed it.
enum AppTiming {
    static let shared = AppTimingProfiles()

    static func key(pid: pid_t) -> String { "pid:\(pid)" }

    /// AX messaging timeout for `pid`: the learned value, but never above `fixed` (today's value at the call site).
    static func messagingTimeout(pid: pid_t, fixed: Float) -> Float {
        Float(min(TimeInterval(fixed), shared.messagingTimeout(for: key(pid: pid))))
    }

    /// Upper bound for a post-action settle wait on `pid`: the learned budget, but never above `fixed`.
    static func settleCap(pid: pid_t, fixed: TimeInterval) -> TimeInterval {
        min(fixed, shared.settleBudget(for: key(pid: pid)))
    }
}
