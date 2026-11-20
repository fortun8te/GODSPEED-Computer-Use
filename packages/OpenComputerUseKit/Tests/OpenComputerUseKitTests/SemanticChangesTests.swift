import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for `SemanticChanges`. Each state is a small tree written the way the snapshot renders it.
final class SemanticChangesTests: XCTestCase {
    // MARK: - Helpers

    /// Three header lines, then one line per row with its element number. `rows` holds (depth, content).
    private func state(title: String = "Notes", rows: [(Int, String)], firstIndex: Int = 1) -> String {
        var lines = [
            "App=com.apple.Notes (pid 4242)",
            "Window: \"\(title)\", App: Notes.",
            "[w=settable]",
        ]
        for (offset, row) in rows.enumerated() {
            lines.append("\(String(repeating: "\t", count: row.0))\(firstIndex + offset) \(row.1)")
        }
        return lines.joined(separator: "\n")
    }

    private var baseRows: [(Int, String)] {
        [(0, "window Notes"), (1, "button Send"), (1, "text field To = a@x.com (w:str)"), (1, "button Cancel")]
    }

    // MARK: - Dialogs and titles

    func testSaveDialogOpenedIsOneEventAndItsContentsStayQuiet() {
        let before = state(rows: baseRows)
        let after = state(rows: baseRows + [
            (1, "dialog Save"),
            (2, "text field Name = report.txt (w:str)"),
            (2, "button Save"),
            (2, "button Cancel"),
        ])
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Save dialog opened"])
        XCTAssertEqual(SemanticChanges.summary(before: before, after: after), "Save dialog opened")
    }

    func testDialogClosedIsReportedWithItsTitle() {
        let open = state(rows: baseRows + [(1, "alert Discard changes?"), (2, "button Discard")])
        XCTAssertEqual(SemanticChanges.events(before: open, after: state(rows: baseRows)), ["Discard changes? alert closed"])
    }

    func testUntitledAlertTakesItsFirstTextLine() {
        let before = state(rows: baseRows)
        let after = state(rows: baseRows + [(1, "alert"), (2, "text Quit without saving?"), (2, "button OK")])
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Quit without saving? alert opened"])
    }

    func testWindowTitleChange() {
        let before = state(title: "Notes", rows: baseRows)
        let after = state(title: "Drafts", rows: baseRows)
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Window title changed: Notes → Drafts"])
    }

    // MARK: - Values

    func testFieldValueChangeShowsLabelOldAndNew() {
        let before = state(rows: baseRows)
        var edited = baseRows
        edited[2] = (1, "text field To = sam@x.com (w:str)")
        XCTAssertEqual(SemanticChanges.events(before: before, after: state(rows: edited)), ["To: a@x.com → sam@x.com"])
    }

    func testLongFieldValuesAreClippedToFortyCharacters() {
        let old = String(repeating: "a", count: 50)
        let new = String(repeating: "b", count: 50)
        let before = state(rows: [(0, "window Notes"), (1, "text field Body = \(old) (w:str)")])
        let after = state(rows: [(0, "window Notes"), (1, "text field Body = \(new) (w:str)")])
        let expected = "Body: " + String(repeating: "a", count: 40) + "… → " + String(repeating: "b", count: 40) + "…"
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), [expected])
    }

    func testSecureFieldValuesAreNeverPrinted() {
        let before = state(rows: [(0, "window Login"), (1, "secure text field Password = hunter2")])
        let after = state(rows: [(0, "window Login"), (1, "secure text field Password = hunter2-new")])
        let events = SemanticChanges.events(before: before, after: after)
        XCTAssertEqual(events, ["Password changed"])
        XCTAssertFalse(events.joined().contains("hunter2"))
    }

    func testPasswordLikeLabelIsRedactedEvenInPlainField() {
        let before = state(rows: [(0, "window Verify"), (1, "text field PIN code = 1234")])
        let after = state(rows: [(0, "window Verify"), (1, "text field PIN code = 5678")])
        let events = SemanticChanges.events(before: before, after: after)
        XCTAssertEqual(events, ["PIN code changed"])
        XCTAssertFalse(events.joined().contains("1234"))
        XCTAssertFalse(events.joined().contains("5678"))
    }

    func testFieldLabelsThatOnlyContainPinAreNotRedacted() {
        // "Shipping" contains "pin" as letters but is not a secret word.
        let before = state(rows: [(0, "window Checkout"), (1, "text field Shipping = Oslo")])
        let after = state(rows: [(0, "window Checkout"), (1, "text field Shipping = Bergen")])
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Shipping: Oslo → Bergen"])
    }

    // MARK: - Toggles, selection and buttons

    func testCheckBoxTurningOn() {
        let before = state(rows: [(0, "window Settings"), (1, "check box Remember me = off (w:bool)")])
        let after = state(rows: [(0, "window Settings"), (1, "check box Remember me = on (w:bool)")])
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Check box \"Remember me\" turned on"])
    }

    func testSelectionMovesBetweenRows() {
        let before = state(rows: [(0, "window Mail"), (1, "row Inbox (selected)"), (1, "row Drafts")])
        let after = state(rows: [(0, "window Mail"), (1, "row Inbox"), (1, "row Drafts (selected)")])
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Selection changed: Inbox → Drafts"])
    }

    func testButtonBecomingEnabled() {
        let before = state(rows: [(0, "window Notes"), (1, "button Send (disabled)")])
        let after = state(rows: [(0, "window Notes"), (1, "button Send")])
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Button \"Send\" enabled"])
    }

    // MARK: - Quiet cases and limits

    func testReorderedRowsGiveNoEvents() {
        let before = state(rows: baseRows)
        let reordered = state(rows: [baseRows[0], baseRows[3], baseRows[2], baseRows[1]], firstIndex: 40)
        XCTAssertEqual(SemanticChanges.events(before: before, after: reordered), [])
        XCTAssertNil(SemanticChanges.summary(before: before, after: reordered))
    }

    func testUnlabelledContainersAndTextDoNotCreateEvents() {
        let before = state(rows: baseRows)
        let after = state(rows: baseRows + [(1, "group"), (2, "static text Loading...")])
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), [])
    }

    func testLimitCapsTheEventList() {
        let before = state(rows: baseRows)
        let many = (0..<12).map { (1, "button Item \($0)") }
        let after = state(rows: baseRows + many)
        XCTAssertEqual(SemanticChanges.events(before: before, after: after, limit: 8).count, 8)
        XCTAssertEqual(SemanticChanges.events(before: before, after: after, limit: 20).count, 12)
        XCTAssertEqual(SemanticChanges.events(before: before, after: after, limit: 8).first, "New button \"Item 0\"")
    }

    func testSummaryJoinsTheFirstEventsOnOneLine() {
        let before = state(rows: baseRows)
        let after = state(rows: baseRows + [(1, "button Item 1"), (1, "button Item 2"), (1, "button Item 3"), (1, "button Item 4")])
        XCTAssertEqual(
            SemanticChanges.summary(before: before, after: after, limit: 2),
            "New button \"Item 1\"; New button \"Item 2\""
        )
    }

    func testEmptyBeforeStateGivesNoEvents() {
        XCTAssertEqual(SemanticChanges.events(before: "", after: state(rows: baseRows)), [])
    }
}
