import Foundation

/// Numeric measurements scoped to one synchronous MCP request, including nested batch steps.
final class ToolTelemetry: @unchecked Sendable {
    @TaskLocal static var current: ToolTelemetry?
    private let lock = NSLock()
    private var counters: [String: Double] = [:]
    private let clock: () -> TimeInterval
    private let startedAt: TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        startedAt = clock()
    }

    func add(_ key: String, _ value: Double = 1) {
        guard value.isFinite, value >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        counters[key, default: 0] += value
    }

    func recordHelper(_ route: String, startedAt: TimeInterval, image: Bool, reply: [String: Any]?) {
        add("\(route)_requests")
        let wallMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        add("helper_wall_ms", wallMs)
        add("\(route)_wall_ms", wallMs)
        if image { add("helper_image_requests") }
        if reply == nil { add("helper_no_response") }
        if reply?[HelperHTTP.busyResponseKey] as? Bool == true { add("helper_busy_responses") }
        if let ms = reply?["ms"] as? Double, ms.isFinite, ms >= 0 {
            add("helper_inference_ms", ms)
            add("\(route)_inference_ms", ms)
            add("helper_inference_samples")
        }
    }

    func snapshot() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    func reply(_ result: ToolCallResult) -> [String: Any] {
        // Elapsed execution must survive a system-clock adjustment. Finalize before the
        // trajectory is written so a measured zero-helper call is distinguishable from
        // legacy rows that did not collect telemetry.
        let elapsed = (clock() - startedAt) * 1_000
        lock.lock()
        if elapsed.isFinite { counters["wall_ms"] = max(0, elapsed) }
        let measurements = counters
        lock.unlock()
        var reply = result.asDictionary
        var metadata = reply["_meta"] as? [String: Any] ?? [:]
        metadata["godspeed/telemetry"] = measurements
        reply["_meta"] = metadata
        return reply
    }
}
