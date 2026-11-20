import XCTest
@testable import OpenComputerUseKit

final class BrowserActionPolicyTests: XCTestCase {
    /// A drag drops onto a control, so the drop target's name must classify like a click on it.
    func testDragDropTargetsClassifyLikeClicks() {
        let cases: [(name: String, risk: ActionPolicy.Risk)] = [
            ("Delete", .delete), ("Trash", .delete), ("Verwijderen", .delete),
            ("Send", .send), ("Pay", .purchase), ("Betalen", .purchase),
        ]
        for (name, risk) in cases {
            let risks = ComputerUseToolDispatcher.browserEffectRisks(
                action: "drag", arguments: ["label": name], target: ActionPolicy.Target(title: name))
            XCTAssertTrue(risks.contains(risk), "\(name) should classify as \(risk.rawValue)")
        }
        XCTAssertEqual(ComputerUseToolDispatcher.browserEffectRisks(
            action: "drag", arguments: ["label": "Notes"], target: ActionPolicy.Target(title: "Notes")), [])
    }

    /// Any action that may have sent input gets the origin re-check even when it failed.
    func testFailedDeliveringActionsStillGetOriginRecheck() {
        for action in ["click", "drag", "type", "key", "check", "scroll_into_view", "select", "upload"] {
            XCTAssertTrue(ComputerUseToolDispatcher.browserActionMayDeliverInput(action), action)
        }
        for action in ["read", "screenshot", "tabs", "wait_for", "location", "read_text"] {
            XCTAssertFalse(ComputerUseToolDispatcher.browserActionMayDeliverInput(action), action)
        }
    }
}
