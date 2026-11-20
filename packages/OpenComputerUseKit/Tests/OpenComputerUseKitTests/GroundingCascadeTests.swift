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

    // Steps 1 and 3: an exact unique name acts without a model; 2-12 ranked candidates act only on a clear lead.

    private let threeNames = [
        GroundingCascade.Option(id: "1", text: "Save"),
        GroundingCascade.Option(id: "2", text: "Saves"),
        GroundingCascade.Option(id: "3", text: "Savee"),
    ]

    func testExactUniqueMatchSkipsTheModel() {
        var asked = false
        let decision = GroundingCascade.resolve(label: "save", options: threeNames, isRisky: { _ in false }) { _ in
            asked = true
            return nil
        }
        XCTAssertEqual(decision, .act(id: "1", provenance: .ax, probability: nil, lead: nil))
        XCTAssertFalse(asked)
    }

    func testThreeRankedCandidatesAreActedOnWhenTheLeadIsClear() {
        var offered: [String] = []
        let decision = GroundingCascade.resolve(label: "Sav", options: threeNames, isRisky: { _ in false }) { options in
            offered = options.map(\.id)
            return ["1": 0.8, "2": 0.1, "3": 0.05, "none": 0.05]
        }
        XCTAssertEqual(offered, ["1", "2", "3"])
        XCTAssertEqual(decision, .act(id: "1", provenance: .model, probability: 0.8, lead: 0.8 - 0.1))
    }

    func testLowLeadOrLowProbabilityAbstains() {
        let lowLead = GroundingCascade.resolve(label: "Sav", options: threeNames, isRisky: { _ in false }) { _ in
            ["1": 0.75, "2": 0.5, "3": 0.0, "none": 0.0]
        }
        XCTAssertEqual(lowLead, .abstain("the top choice does not lead by 0.35"))

        let lowProbability = GroundingCascade.resolve(label: "Sav", options: threeNames, isRisky: { _ in false }) { _ in
            ["1": 0.6, "2": 0.1, "3": 0.1, "none": 0.2]
        }
        XCTAssertEqual(lowProbability, .abstain("the top choice is below 0.70"))
    }

    func testNoneScoringHighestAbstains() {
        let decision = GroundingCascade.resolve(label: "Sav", options: threeNames, isRisky: { _ in false }) { _ in
            ["1": 0.05, "2": 0.05, "3": 0.0, "none": 0.9]
        }
        if case .abstain = decision {} else { XCTFail("expected abstain, got \(decision)") }
    }

    func testRiskyTopChoiceIsOfferedNotClicked() {
        let names = [
            GroundingCascade.Option(id: "1", text: "Delete"),
            GroundingCascade.Option(id: "2", text: "Delete All"),
            GroundingCascade.Option(id: "3", text: "Deleted"),
        ]
        let decision = GroundingCascade.resolve(label: "Delet", options: names, isRisky: { $0.lowercased().hasPrefix("del") }) { _ in
            ["1": 0.9, "2": 0.05, "3": 0.0, "none": 0.05]
        }
        XCTAssertEqual(decision, .offer(ids: ["1", "2", "3"]))  // all three contain "delet"; the top one is never acted on
    }

    func testSingleOrNoCandidateNeverAsksTheModel() {
        var asked = false
        let decision = GroundingCascade.resolve(label: "Quasar", options: threeNames, isRisky: { _ in false }) { _ in
            asked = true
            return nil
        }
        XCTAssertEqual(decision, .abstain("no close control"))
        XCTAssertFalse(asked)
    }
}
