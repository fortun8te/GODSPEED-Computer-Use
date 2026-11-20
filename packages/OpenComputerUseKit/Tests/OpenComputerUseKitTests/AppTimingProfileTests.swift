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
    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("timings.json"), a = AppTimingProfiles(), b = AppTimingProfiles()
        a.record(app: "com.example", axLatencyMs: 42); try a.save(to: file); try b.load(from: file)
        XCTAssertEqual(b.messagingTimeout(for: "com.example"), 0.25)
    }
    func testConcurrentRecords() {
        let p = AppTimingProfiles(), group = DispatchGroup()
        for i in 0..<100 { group.enter(); DispatchQueue.global().async { p.record(app: "a", axLatencyMs: Double(i)); group.leave() } }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThan(p.settleBudget(for: "a"), 0)
    }
}
