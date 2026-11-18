import XCTest
@testable import OpenComputerUseKit

/// Calculator-style label spellings, checked in both directions.
final class LabelSpellingsTests: XCTestCase {
    func testKeypadGroupsPreserveOrderAndStopOnFailure() {
        enum DeliveryError: Error { case failed }
        var sent: [String] = []
        var gaps: [Bool] = []
        XCTAssertThrowsError(try SkyKeyboardDispatcher.deliverKeypadGroups("123456789=") { group, precededByKey in
            sent.append(String(group))
            gaps.append(precededByKey)
            if precededByKey { throw DeliveryError.failed }
        })
        XCTAssertEqual(sent, ["1234", "5678"])
        XCTAssertEqual(gaps, [false, true])

        sent.removeAll()
        SkyKeyboardDispatcher.deliverKeypadGroups("37*24=") { group, _ in sent.append(String(group)) }
        XCTAssertEqual(sent, ["37*2", "4="])
    }

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
        XCTAssertTrue(LabelSpellings.isKeypad(buttonNames: ["0", "one", "2", "three", "4"]))
        XCTAssertFalse(LabelSpellings.isKeypad(buttonNames: ["0", "zero", "1", "one", "two"]))
    }
}
