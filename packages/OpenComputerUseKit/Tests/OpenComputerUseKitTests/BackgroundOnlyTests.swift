import XCTest
@testable import OpenComputerUseKit

/// OPEN_COMPUTER_USE_BACKGROUND_ONLY=1: nothing may come in front of the user's work.
final class BackgroundOnlyTests: XCTestCase {
    private let key = "OPEN_COMPUTER_USE_BACKGROUND_ONLY"

    func testFlagParsing() {
        XCTAssertFalse(backgroundOnlyMode(environment: [:]))
        XCTAssertFalse(backgroundOnlyMode(environment: [key: "0"]))
        for value in ["1", "true", "YES", " on "] {
            XCTAssertTrue(backgroundOnlyMode(environment: [key: value]), value)
        }
    }

    func testPhysicalPointerFallbackStaysOffEvenWhenAllowed() {
        let allow = "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"
        XCTAssertTrue(globalPointerFallbacksEnabled(environment: [allow: "1"]))
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: [allow: "1", key: "1"]),
                       "the global path activates the app and moves the real pointer")
    }

    func testRaiseRefusalNamesTheModeAndWhatStillWorks() {
        XCTAssertTrue(backgroundOnlyRaiseRefusedMessage.contains(key))
        XCTAssertTrue(backgroundOnlyRaiseRefusedMessage.contains("Raise"))
    }
}
