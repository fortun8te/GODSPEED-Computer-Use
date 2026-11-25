import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class WindowSettleTests: XCTestCase {
    func testCancelledScanDoesNotContinueIntoMoreBranches() {
        let cancellation = RequestCancellation()
        var reads = 0
        let busy = RequestCancellation.$current.withValue(cancellation) {
            WindowSettle.busy(from: 0, requireComplete: true) { ids in
                reads += 1
                cancellation.cancel()
                return ids.map { WindowSettle.Signs(role: "AXGroup", children: [$0 + 1], busy: false, loaded: nil) }
            }
        }
        XCTAssertTrue(busy, "An interrupted scan cannot prove quiescence")
        XCTAssertEqual(reads, 1)
    }

    func testIndividualAXFailuresCannotLookLikeAnEmptyQuietBranch() {
        func errorValue(_ error: AXError) -> AXValue {
            var value = error
            return AXValueCreate(.axError, &value)!
        }
        let normal: [AnyObject] = ["AXGroup" as CFString, [] as NSArray,
                                   errorValue(.attributeUnsupported), errorValue(.noValue)]
        XCTAssertNotNil(WindowSettle.decodeSigns(normal), "Unsupported optional attributes are normal")
        for index in normal.indices {
            var failed = normal
            failed[index] = errorValue(.cannotComplete)
            XCTAssertNil(WindowSettle.decodeSigns(failed), "Attribute \(index) was not observed")
            failed[index] = NSNull()
            if index == 0 {
                XCTAssertNil(WindowSettle.decodeSigns(failed), "A role is required to classify the branch")
            } else {
                XCTAssertNotNil(WindowSettle.decodeSigns(failed), "CFNull is documented absence for optional attributes")
            }
        }
        var malformed = normal
        malformed[1] = "not children" as CFString
        XCTAssertNil(WindowSettle.decodeSigns(malformed))
        malformed = normal
        malformed[2] = "not a boolean" as CFString
        XCTAssertNil(WindowSettle.decodeSigns(malformed))
    }

    func testCancellationDuringQuietScanCannotConfirmSettled() {
        let cancellation = RequestCancellation()
        var clock: TimeInterval = 0
        var reads = 0
        let settled = RequestCancellation.$current.withValue(cancellation) {
            WindowSettle.wait(timeout: 0.5, now: { clock }, sleep: { clock += $0 }) {
                reads += 1
                if reads == 4 { cancellation.cancel() }
                return false
            }
        }
        XCTAssertFalse(settled)
        XCTAssertEqual(reads, 4)
    }

    func testQuietScanFinishingAtDeadlineCannotConfirmSettled() {
        var clock: TimeInterval = 0
        var reads = 0
        let settled = WindowSettle.wait(timeout: 0.2, now: { clock }, sleep: { clock += $0 }) {
            reads += 1
            if reads == 4 { clock = 0.2 }
            return false
        }
        XCTAssertFalse(settled)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(clock, 0.2)
    }

    func testCancellationDuringCaptureSkipsBusyReadAndFurtherSleep() {
        let cancellation = RequestCancellation()
        var clock: TimeInterval = 0
        var busyReads = 0
        RequestCancellation.$current.withValue(cancellation) {
            WindowSettle.waitUntilStill(cap: 0.5, now: { clock }, sleep: { clock += $0 }, axBusy: {
                busyReads += 1
                return false
            }) {
                cancellation.cancel()
                return 1
            }
        }
        XCTAssertEqual(busyReads, 0)
        XCTAssertEqual(clock, WindowSettle.floor)
    }

    func testCancellationDuringBusyReadSkipsFurtherSleep() {
        let cancellation = RequestCancellation()
        var clock: TimeInterval = 0
        RequestCancellation.$current.withValue(cancellation) {
            WindowSettle.waitUntilStill(cap: 0.5, now: { clock }, sleep: { clock += $0 }, axBusy: {
                cancellation.cancel()
                return false
            }) { 1 }
        }
        XCTAssertEqual(clock, WindowSettle.floor)
    }

    func testIncompleteAXScanCannotConfirmQuiescence() {
        typealias Signs = WindowSettle.Signs<Int>
        let clipped = Signs(role: "AXWindow", children: Array(1...WindowSettle.scanNodes), busy: false, loaded: nil)
        XCTAssertTrue(WindowSettle.busy(from: 0, requireComplete: true) { ids in
            ids.map { $0 == 0 ? clipped : nil }
        })
        XCTAssertTrue(WindowSettle.busy(from: 0, requireComplete: true) { _ in [nil] })
    }

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
