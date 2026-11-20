import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class GroundingCascadeTests: XCTestCase {
    private func options(_ names: [String]) -> [GroundingCascade.Option] {
        names.enumerated().map { GroundingCascade.Option(id: String($0.offset + 1), text: $0.element) }
    }

    // Step 2: rule-based prefilter, capped at 12.

    func testPrefilterKeepsSpellingAndTypoMatchesAndDropsUnrelatedControls() {
        let names = ["Save", "Cancel", "Opslaan", "Print", "Sharpen", "Share", "Zoom In"]
        let picked = GroundingCascade.prefilter(label: "Sve", options: options(names))
        XCTAssertEqual(picked.map(\.text), ["Save"])

        let dutch = GroundingCascade.prefilter(label: "Save", options: options(names))
        XCTAssertEqual(dutch.first?.text, "Save")
        XCTAssertTrue(dutch.map(\.text).contains("Opslaan"))
        XCTAssertFalse(dutch.map(\.text).contains("Zoom In"))
    }

    func testPrefilterUsesLabelSpellingsForDigitsAndSymbols() {
        let names = ["one", "add", "3", "Clear"]
        let picked = GroundingCascade.prefilter(label: "1", options: options(names))
        XCTAssertEqual(picked.map(\.text), ["one"])
        XCTAssertEqual(GroundingCascade.prefilter(label: "+", options: options(names)).map(\.text), ["add"])
    }

    func testPrefilterIsNormalizedAndCappedAtTwelve() {
        let names = (1...20).map { "Item \($0) Ünïcode" } + ["  item-Unicode "]
        let picked = GroundingCascade.prefilter(label: "item unicode", options: options(names))
        XCTAssertEqual(picked.count, GroundingCascade.maxCandidates)
        XCTAssertEqual(GroundingCascade.maxCandidates, 12)
    }

    func testPrefilterReturnsNothingForUnrelatedLabel() {
        XCTAssertTrue(GroundingCascade.prefilter(label: "Quasar", options: options(["Save", "Print"])).isEmpty)
    }
}
