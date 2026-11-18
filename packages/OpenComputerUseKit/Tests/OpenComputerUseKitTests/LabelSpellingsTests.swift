import XCTest
@testable import OpenComputerUseKit

/// Calculator-style label spellings, checked in both directions.
final class LabelSpellingsTests: XCTestCase {
    func testWordFindsDigitAndDigitFindsWord() {
        XCTAssertTrue(LabelSpellings.alternatives("seven").contains("7"))
        XCTAssertTrue(LabelSpellings.alternatives("7").contains("seven"))
    }

    func testWordFindsSymbolAndSymbolFindsWord() {
        XCTAssertTrue(LabelSpellings.alternatives("add").contains("+"))
        XCTAssertTrue(LabelSpellings.alternatives("+").contains("add"))
        XCTAssertTrue(LabelSpellings.alternatives("equals").contains("="))
        XCTAssertTrue(LabelSpellings.alternatives("decimal").contains("."))
        XCTAssertTrue(LabelSpellings.alternatives("divide").contains("÷"))
        XCTAssertTrue(LabelSpellings.alternatives("allclear").contains("ac"))
    }

    func testKeypadIsFoundFromDigitWords() {
        XCTAssertTrue(LabelSpellings.isKeypad(buttonNames: ["one", "two", "three", "four", "five"]))
        XCTAssertFalse(LabelSpellings.isKeypad(buttonNames: ["one", "two"]))
    }
}
