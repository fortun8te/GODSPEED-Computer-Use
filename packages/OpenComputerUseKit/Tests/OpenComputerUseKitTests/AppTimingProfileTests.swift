import Foundation
import XCTest
@testable import OpenComputerUseKit

final class AppTimingProfileTests: XCTestCase {
    func testDefaultsClampsTimeoutAndSettle() {
        let p = AppTimingProfiles()
        XCTAssertEqual(p.messagingTimeout(for: "a"), 0.25)
        XCTAssertEqual(p.settleBudget(for: "a"), 0.3)
        for _ in 0..<8 { p.record(app: "a", axLatencyMs: 9000); p.recordSettle(app: "a", ms: 0) }
        XCTAssertEqual(p.messagingTimeout(for: "a"), 1)
        XCTAssertEqual(p.settleBudget(for: "a"), 0.08)
    }
    func testTimeoutBurstRecovery() {
        let p = AppTimingProfiles(), now = Date()
        p.record(app: "a", axLatencyMs: 20)
        for _ in 0..<3 { p.recordTimeout(app: "a", now: now) }
        XCTAssertTrue(p.isUnresponsive(app: "a", now: now))
        XCTAssertEqual(p.messagingTimeout(for: "a", now: now), 0.05)
        XCTAssertFalse(p.isUnresponsive(app: "a", now: now.addingTimeInterval(11)))
        XCTAssertEqual(p.messagingTimeout(for: "a", now: now.addingTimeInterval(11)), 0.25, "recovers after the window")
    }

    func testFastSuccessClearsUnresponsiveState() {
        let p = AppTimingProfiles(), now = Date()
        p.record(app: "a", axLatencyMs: 20)
        for _ in 0..<3 { p.recordTimeout(app: "a", now: now) }
        XCTAssertTrue(p.isUnresponsive(app: "a", now: now))
        XCTAssertEqual(p.messagingTimeout(for: "a", now: now), 0.05)

        p.record(app: "a", axLatencyMs: 5)
        XCTAssertFalse(p.isUnresponsive(app: "a", now: now), "one fast success ends the burst")
        XCTAssertEqual(p.messagingTimeout(for: "a", now: now), 0.25, "back to the normal default")

        // The old timeout dates are gone too: two more timeouts are not a new burst.
        p.recordTimeout(app: "a", now: now)
        p.recordTimeout(app: "a", now: now)
        XCTAssertFalse(p.isUnresponsive(app: "a", now: now))
    }

    func testTimeoutFollowsObservedLatencyWithinClamps() {
        let p = AppTimingProfiles()
        for _ in 0..<10 { p.record(app: "fast", axLatencyMs: 5) }
        XCTAssertEqual(p.messagingTimeout(for: "fast"), 0.05, accuracy: 1e-9, "3x a 5 ms p95 is clamped up to the floor")
        for _ in 0..<10 { p.record(app: "slow", axLatencyMs: 900) }
        XCTAssertEqual(p.messagingTimeout(for: "slow"), 1.0, accuracy: 1e-9, "clamped to one second")
        for _ in 0..<10 { p.record(app: "mid", axLatencyMs: 100) }
        XCTAssertEqual(p.messagingTimeout(for: "mid"), 0.3, accuracy: 1e-9)
    }

    func testOldTimeoutsOutsideThirtySecondsDoNotCount() {
        let p = AppTimingProfiles(), now = Date()
        p.recordTimeout(app: "a", now: now)
        p.recordTimeout(app: "a", now: now.addingTimeInterval(1))
        p.recordTimeout(app: "a", now: now.addingTimeInterval(40))
        XCTAssertFalse(p.isUnresponsive(app: "a", now: now.addingTimeInterval(40)))
    }
    /// The shared helper that call sites use: it adapts to fast and frozen apps, and never exceeds today's value.
    func testSharedHelperAdaptsAndNeverExceedsFixedValue() {
        let pid: pid_t = 987_001 // a fixture pid no real app uses; AppTiming.shared is process-wide
        XCTAssertEqual(AppTiming.messagingTimeout(pid: pid, fixed: 0.2), 0.2, "an unknown app keeps today's value")
        for _ in 0..<10 { AppTiming.shared.record(app: AppTiming.key(pid: pid), axLatencyMs: 5) }
        XCTAssertEqual(AppTiming.messagingTimeout(pid: pid, fixed: 0.2), 0.05, accuracy: 1e-9, "fast samples shorten the wait")
        for _ in 0..<10 { AppTiming.shared.record(app: AppTiming.key(pid: pid), axLatencyMs: 900) }
        XCTAssertEqual(AppTiming.messagingTimeout(pid: pid, fixed: 0.2), 0.2, accuracy: 1e-9, "slow samples never raise it above 0.2")

        let frozen: pid_t = 987_002
        let now = Date()
        for _ in 0..<3 { AppTiming.shared.recordTimeout(app: AppTiming.key(pid: frozen), now: now) }
        XCTAssertEqual(AppTiming.messagingTimeout(pid: frozen, fixed: 0.2), 0.05, accuracy: 1e-9, "a timeout burst uses the floor")
    }

    func testSharedSettleCapIsBoundedByTheCallSite() {
        let pid: pid_t = 987_003
        XCTAssertEqual(AppTiming.settleCap(pid: pid, fixed: 0.15), 0.15, "no samples: the call site's interval")
        AppTiming.shared.recordSettle(app: AppTiming.key(pid: pid), ms: 0)
        XCTAssertEqual(AppTiming.settleCap(pid: pid, fixed: 0.15), 0.08, accuracy: 1e-9, "a fast app settles within the learned budget")
        AppTiming.shared.recordSettle(app: AppTiming.key(pid: pid), ms: 5000)
        XCTAssertEqual(AppTiming.settleCap(pid: pid, fixed: 0.15), 0.15, "a slow app never waits longer than the interval")
    }

    private func withTempFile(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("timings.json"))
    }

    func testPersistenceRoundTrip() throws {
        try withTempFile { file in
            let a = AppTimingProfiles(), b = AppTimingProfiles()
            for _ in 0..<8 { a.record(app: "com.example", axLatencyMs: 100) }
            a.recordSettle(app: "com.example", ms: 500)
            XCTAssertEqual(a.messagingTimeout(for: "com.example"), 0.3, accuracy: 1e-9, "non-default before saving")
            try a.save(to: file)

            try b.load(from: file)
            XCTAssertEqual(b.messagingTimeout(for: "com.example"), 0.3, accuracy: 1e-9)
            XCTAssertEqual(b.settleBudget(for: "com.example"), 0.5, accuracy: 1e-9)
            XCTAssertEqual(b.messagingTimeout(for: "unknown"), 0.25, "other apps keep the default")
        }
    }

    func testConcurrentRecords() throws {
        let p = AppTimingProfiles(), group = DispatchGroup()
        for i in 0..<100 { group.enter(); DispatchQueue.global().async { p.record(app: "a", axLatencyMs: Double(i)); group.leave() } }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        try withTempFile { file in
            try p.save(to: file)
            let stored = try JSONDecoder().decode([String: AppTimingProfile].self, from: Data(contentsOf: file))["a"]
            let samples = try XCTUnwrap(stored?.axLatenciesMs)
            XCTAssertEqual(samples.count, min(100, 64), "keeps the newest 64 of 100 records")
            let p95 = try XCTUnwrap(stored?.p95AXLatencyMs)
            XCTAssertTrue(p95 >= samples.min()! && p95 <= samples.max()!, "p95 \(p95) lies in the stored range")
            XCTAssertTrue((0...99).contains(p95), "p95 \(p95) lies in the recorded range")
        }
    }
}
