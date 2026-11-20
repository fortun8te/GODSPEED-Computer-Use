import XCTest
@testable import OpenComputerUseKit

final class ReadinessPollTests: XCTestCase {
    func testReadyDialogDoesNotSleep() {
        let ready = ReadinessPoll.first(timeout: 0.6, now: { 0 }, sleep: { _ in
            XCTFail("An already available dialog should not sleep")
        }, read: { "Save" })
        XCTAssertEqual(ready, "Save")
    }

    func testDelayedReadinessStopsImmediatelyAndNeverSleepsPastDeadline() {
        var now: TimeInterval = 0
        var reads = 0
        let ready = ReadinessPoll.first(timeout: 0.13, interval: 0.05, now: { now }, sleep: { now += $0 }) {
            reads += 1
            return reads == 3 ? "Save" : nil
        }
        XCTAssertEqual(ready, "Save")
        XCTAssertEqual(now, 0.1, accuracy: 0.0001)
        let unavailable: Bool? = ReadinessPoll.first(timeout: 0.13, interval: 0.05, now: { now }, sleep: { now += $0 }) { nil }
        XCTAssertNil(unavailable)
        XCTAssertEqual(now, 0.23, accuracy: 0.0001)
    }

    func testLazyWebAreaReadsFullTreeOnceAfterMultipleProbes() {
        var probes = 0
        var renders = 0
        SnapshotBuilder.refreshLazyWebArea(timeout: 0.8, probe: {
            probes += 1
            return probes == 3
        }, render: { renders += 1 })
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(renders, 1)
    }

    func testLazyWebAreaTimeoutStillReadsTreeOnceForDiagnosis() {
        var renders = 0
        SnapshotBuilder.refreshLazyWebArea(timeout: 0, probe: { false }, render: { renders += 1 })
        XCTAssertEqual(renders, 1)
    }
}
