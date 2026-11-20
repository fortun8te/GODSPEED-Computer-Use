import XCTest
@testable import OpenComputerUseKit

final class WindowSettleTests: XCTestCase {
    func testReadDoesNotSettleBeforeDelayedBusySign() {
        var clock: TimeInterval = 0
        let settled = WindowSettle.wait(timeout: 0.5, now: { clock }, sleep: { clock += $0 }) {
            clock >= 0.1 && clock < 0.2
        }
        XCTAssertTrue(settled)
        XCTAssertGreaterThanOrEqual(clock, 0.3)
    }
    func testFrameQuietPeriodResetsAfterLateRedraw() {
        var clock: TimeInterval = 0
        let settledAt = WindowSettle.waitUntilStill(cap: 0.5, now: { clock }, sleep: { clock += $0 }) {
            clock < 0.11 ? 1 : 2
        }
        XCTAssertGreaterThanOrEqual(settledAt, 0.11 + WindowSettle.quietPeriod)
        XCTAssertLessThan(settledAt, 0.35)
    }

    func testStableFramesCannotOverrideAXBusyOrExtendTheBudget() {
        var clock: TimeInterval = 0
        let settledAt = WindowSettle.waitUntilStill(
            cap: 0.35, now: { clock }, sleep: { clock += $0 }, axBusy: { true }
        ) { 1 }
        XCTAssertEqual(settledAt, 0.35, accuracy: 0.001)
    }

    func testAXBusyResetsQuietEvenWhenFramesStayTheSame() {
        var clock: TimeInterval = 0
        let settledAt = WindowSettle.waitUntilStill(
            cap: 0.5, now: { clock }, sleep: { clock += $0 }, axBusy: { clock >= 0.08 && clock < 0.16 }
        ) { 1 }
        XCTAssertGreaterThanOrEqual(settledAt, 0.16 + WindowSettle.quietPeriod)
        XCTAssertLessThan(settledAt, 0.4)
    }
}
