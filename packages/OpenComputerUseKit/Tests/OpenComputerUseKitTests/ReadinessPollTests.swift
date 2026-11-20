import XCTest
@testable import OpenComputerUseKit

final class ReadinessPollTests: XCTestCase {
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
