import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class BatchReceiptsTests: XCTestCase {
    private func node(_ index: Int, _ role: String, _ name: String?) -> SmartSteps.Node {
        SmartSteps.Node(index: index, role: role, subrole: nil, name: name, frame: nil)
    }

    func testFailureReceiptUsesDeliveryState() {
        XCTAssertEqual(BatchEffects.failureReceipt(.notSent), .notSent)
        XCTAssertEqual(BatchEffects.failureReceipt(.outcomeUnknown), .outcomeUnknown)
        XCTAssertNil(BatchEffects.failureReceipt(.acknowledged))
        XCTAssertNil(BatchEffects.failureReceipt(.verified))
    }

    func testStaleAndAmbiguousErrorsUseTypesEvenWhenLabelsContainErrorWords() throws {
        XCTAssertTrue(SmartSteps.isStale(ComputerUseError.staleTarget("read again")))
        XCTAssertFalse(SmartSteps.isStale(ComputerUseError.message("no longer has the identity")))
        XCTAssertFalse(SmartSteps.isNotFound(ComputerUseError.ambiguousTarget("no element labelled")))
        XCTAssertTrue(SmartSteps.isNotFound(ComputerUseError.targetNotFound("read again")))
        XCTAssertFalse(ElementNumbering.isGone(ComputerUseError.message(ElementNumbering.goneMessage(index: "1"))))
    }

    func testLineAppendsReceiptToFirstLineOnly() {
        XCTAssertEqual(BatchEffects.line("2. click \"Save\": ok", receipt: .noEffectSeen), "2. click \"Save\": ok - no effect seen")
        XCTAssertEqual(BatchEffects.line("2. query: ok\nrow", receipt: .notSent), "2. query: ok - not sent\nrow")
        XCTAssertEqual(BatchEffects.line("2. click: ok", receipt: nil), "2. click: ok")
    }

    func testChangeExpectation() {
        XCTAssertTrue(BatchEffects.expectsVisibleChange(tool: "click"))
        XCTAssertFalse(BatchEffects.expectsVisibleChange(tool: "scroll"))
        XCTAssertTrue(BatchEffects.sawNoChange(["no visible change"]))
        XCTAssertFalse(BatchEffects.sawNoChange(["effect: 1 button +x"]))
    }

    func testAdviceForUnknownDoesNotSayResend() {
        let unknown = BatchEffects.advice(for: .outcomeUnknown, stepNumber: 3)
        XCTAssertTrue(unknown.contains("whether step 3 took effect before retrying"))
        XCTAssertTrue(unknown.contains("Resume at the first unfinished step"))
        XCTAssertTrue(BatchEffects.advice(for: .notSent, stepNumber: 3).contains("Step 3 was not sent"))
    }

    func testAcknowledgedReadbackFailureGuidesInspectionWithoutRetry() {
        let receipt = TrajectoryLog.BatchReceipt(
            totalSteps: 2, steps: [.init(failureCode: .timeout, deliveryState: .acknowledged)], stop: .stepFailure
        )
        XCTAssertEqual(receipt.recovery?["action"] as? String, "inspect_result")
        XCTAssertEqual(receipt.recovery?["step"] as? Int, 1)
        XCTAssertEqual(BatchEffects.advice(for: .acknowledged, stepNumber: 1),
                       "Step 1 was sent. Inspect its result before continuing.")
    }

    func testHealsToTheSingleRedrawnTwin() {
        let outcome = StaleHealing.resolve(index: "12", role: "button", label: "Save", nodes: [
            node(30, "AXButton", "Cancel"), node(31, "AXButton", "Save"), node(32, "AXStaticText", "Save"),
        ])
        XCTAssertEqual(outcome, .use(index: 31, note: "(element 12 was redrawn; used 31 \"Save\")"))
    }

    func testSeveralMatchesListCandidates() {
        let outcome = StaleHealing.resolve(index: "12", role: "button", label: "Save", nodes: [
            node(31, "AXButton", "Save"), node(40, "AXButton", "Save"),
        ])
        guard case .refuse(let message) = outcome else { return XCTFail("expected refusal") }
        XCTAssertTrue(message.hasPrefix("stale: element 12 (button \"Save\") is gone, nothing sent."))
        XCTAssertTrue(message.contains("2 controls match now: 31 button \"Save\", 40 button \"Save\""))
        XCTAssertTrue(ElementNumbering.isGone(ComputerUseError.elementGone(message)))
    }

    func testNoMatchListsCloseNames() {
        let outcome = StaleHealing.resolve(index: "12", role: "button", label: "Save", nodes: [
            node(5, "AXButton", "Save As…"), node(6, "AXButton", "Cancel"),
        ])
        guard case .refuse(let message) = outcome else { return XCTFail("expected refusal") }
        XCTAssertTrue(message.contains("None matches exactly. Close: 5 button \"Save As…\""))
        XCTAssertFalse(message.contains("Cancel"))
        guard case .refuse(let bare) = StaleHealing.resolve(index: "1", role: "button", label: "Zip", nodes: []) else { return XCTFail() }
        XCTAssertTrue(bare.contains("No control has that name now."))
    }

    func testUnknownLabelFallsBackToPlainGoneMessage() {
        XCTAssertEqual(
            StaleHealing.resolve(index: "9", role: nil, label: nil, nodes: []),
            .refuse(ElementNumbering.goneMessage(index: "9"))
        )
    }
}
