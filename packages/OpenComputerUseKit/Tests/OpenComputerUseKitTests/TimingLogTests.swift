import XCTest
@testable import OpenComputerUseKit

final class TimingLogTests: XCTestCase {
    func testCountersContainOnlyStageAndCount() {
        XCTAssertEqual(TimingLog.counterLine("snapshot.image_bytes", value: 42),
                       "[open-computer-use] count snapshot.image_bytes 42\n")
    }

    func testDisabledTimingDoesNotEvaluateCounter() {
        guard !TimingLog.enabled else { return }
        func unexpectedCount() -> Int {
            XCTFail("Disabled counters must not compute sizes")
            return 0
        }
        TimingLog.count("snapshot.text_bytes", unexpectedCount())
    }
}
