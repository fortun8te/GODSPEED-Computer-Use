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

    /// Enter in an iframe form or typing into an iframe password field must be classified in that frame.
    func testKeyboardPolicyFollowsFocusIntoNestedFrames() throws {
        var entered: [String] = []
        let focused = try BrowserPage.focusedPolicyElement(start: "main", focus: { document in
            switch document {
            case "main": return .frameOwner(objectID: "outer-iframe")
            case "outer": return .frameOwner(objectID: "inner-iframe")
            default: return .element(objectID: "password-field")
            }
        }, enter: { owner in
            entered.append(owner)
            return owner == "outer-iframe" ? "outer" : "inner"
        })
        XCTAssertEqual(focused, "password-field")
        XCTAssertEqual(entered, ["outer-iframe", "inner-iframe"])
    }

    func testKeyboardPolicyFailsClosedWhenFocusedFrameCannotBeEntered() {
        XCTAssertThrowsError(try BrowserPage.focusedPolicyElement(start: "main", focus: { _ in
            .frameOwner(objectID: "self-referencing-iframe")
        }, enter: { _ in "main" })) { error in
            guard case ComputerUseError.actionDenied = error else { return XCTFail("\(error)") }
        }
    }
}
