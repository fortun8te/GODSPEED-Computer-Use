import XCTest
@testable import OpenComputerUseKit

/// L9's gesture menu commands go through the action policy and never press a destructive command.
final class GestureSafetyTests: XCTestCase {
    func testNewActionToolsAreCoveredByThePolicyGate() {
        for tool in ["gesture", "scroll_into_view", "wait_for"] {
            XCTAssertTrue(ActionPolicy.nativeScopedTools.contains(tool), tool)
        }
    }

    func testGestureMenuCommandCarriesItsRisks() {
        let risks = ActionPolicy.nativeRisks(tool: "gesture", arguments: ["app": "Preview", "menu_path": ["File", "Move to Trash"]],
                                             bundleID: "com.apple.Preview", target: nil)
        XCTAssertTrue(risks.contains(.delete), "\(risks)")
        let zoom = ActionPolicy.nativeRisks(tool: "gesture", arguments: ["app": "Preview", "menu_path": "View > Zoom In"],
                                            bundleID: "com.apple.Preview", target: nil)
        XCTAssertTrue(zoom.isEmpty, "\(zoom)")
    }

    func testDestructiveTitlesAreRecognisedInEnglishAndDutch() {
        for title in ["Delete", "Move to Trash", "Quit Preview", "Verwijderen", "Prullenmand leegmaken", "Afmelden"] {
            XCTAssertTrue(MenuItemLookup.isDestructive(title) || ShortcutCache.isDestructive(title), title)
        }
        XCTAssertFalse(MenuItemLookup.isDestructive("Zoom In") || ShortcutCache.isDestructive("Zoom In"))
    }
}
