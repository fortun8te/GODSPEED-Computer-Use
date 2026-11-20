import Foundation

/// Polls a read-only condition against a monotonic deadline. A positive result
/// allows the caller to take its next observation or perform a separate action.
enum ReadinessPoll {
    static func first<Value>(
        timeout: TimeInterval, interval: TimeInterval = 0.05,
        now: () -> TimeInterval = TimingLog.now,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        read: () -> Value?
    ) -> Value? {
        let deadline = now() + timeout
        repeat {
            if let value = read() { return value }
            let remaining = deadline - now()
            guard remaining > 0 else { return nil }
            sleep(min(interval, remaining))
        } while now() <= deadline
        return nil
    }
}
