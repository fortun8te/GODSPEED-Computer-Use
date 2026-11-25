import Foundation

/// Polls a read-only condition against a monotonic deadline. A positive result
/// allows the caller to take its next observation or perform a separate action.
enum ReadinessPoll {
    static func first<Value>(
        timeout: TimeInterval, interval: TimeInterval = 0.05,
        now: () -> TimeInterval = TimingLog.now,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        // With a pid, the sleep ends early on an AX notification for that app (see AXChangeMonitor).
        // Without one, or for an app that never notifies, the sleep is the same bounded interval as before.
        pid: pid_t? = nil,
        monitor: AXChangeMonitor? = nil,
        read: () -> Value?
    ) -> Value? {
        let started = now()
        let limit = started + timeout
        let inherited = BrowserCallBudget.activeDeadline
        guard started.isFinite, timeout.isFinite, timeout > 0, limit.isFinite,
              interval.isFinite, interval > 0, inherited?.isFinite != false else { return nil }
        let deadline = min(limit, inherited ?? limit)
        while !RequestCancellation.requested, now() < deadline {
            // Note the generation before the read, so a change during the read ends the next sleep at once.
            let watch = pid.map { (monitor ?? AXChangeMonitor.shared, $0) }
            let token = watch.map { $0.0.track($0.1) }
            guard !RequestCancellation.requested, now() < deadline else { return nil }
            let value = read()
            guard !RequestCancellation.requested, now() < deadline else { return nil }
            if let value { return value }
            let remaining = deadline - now()
            guard remaining > 0 else { return nil }
            if let watch, let token {
                watch.0.awaitChange(pid: watch.1, since: token, upTo: min(interval, remaining))
            } else {
                sleep(min(interval, remaining))
            }
        }
        return nil
    }
}
