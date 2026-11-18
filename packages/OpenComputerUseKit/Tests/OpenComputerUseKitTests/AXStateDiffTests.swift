import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for `AXStateDiff`. Nothing here touches accessibility, the screen or the network.
final class AXStateDiffTests: XCTestCase {
    // MARK: - Helpers

    /// Renders a state the way the snapshot does: three header lines, then one line per row with
    /// its element index. `rows` holds (depth, content) pairs.
    private func state(
        title: String = "Notes",
        rows: [(Int, String)],
        firstIndex: Int = 1,
        indent: (Int) -> String = { String(repeating: "\t", count: $0) }
    ) -> String {
        var lines = [
            "App=com.apple.Notes (pid 4242)",
            "Window: \"\(title)\", App: Notes.",
            "[w=settable]",
        ]
        for (offset, row) in rows.enumerated() {
            lines.append("\(indent(row.0))\(firstIndex + offset) \(row.1)")
        }
        return lines.joined(separator: "\n")
    }

    private var baseRows: [(Int, String)] {
        [(0, "window Notes"), (1, "button Send"), (1, "text field To = a@x.com (w:str)"), (1, "button Cancel")]
    }

    /// A tree of `count` rows with varied depth and distinct content.
    private func bigRows(_ count: Int) -> [(Int, String)] {
        (0..<count).map { ((($0 / 3) % 4), "static text row \($0) lorem ipsum") }
    }

    private func lines(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - No change and renumbering

    func testIdenticalStatesReportNoChanges() {
        let text = state(rows: baseRows)
        XCTAssertEqual(AXStateDiff.diff(previous: text, current: text), AXStateDiff.noChangesMessage)
        XCTAssertEqual(AXStateDiff.noChangesMessage, "No changes since your last read.")
    }

    func testRenumberedAndReindentedTreeHasNoChanges() {
        let previous = state(rows: baseRows, firstIndex: 1)
        let current = state(rows: baseRows, firstIndex: 500) { String(repeating: " ", count: $0 * 2) }
        XCTAssertEqual(AXStateDiff.diff(previous: previous, current: current), AXStateDiff.noChangesMessage)
    }

    // MARK: - Changed, added and removed lines

    func testOneValueChangeShowsOnePlusLineWithCurrentIndex() throws {
        let previous = state(rows: baseRows, firstIndex: 1)
        var changedRows = baseRows
        changedRows[2] = (1, "text field To = sam@x.com (w:str)")
        // The current read numbers this row 22, so the summary must show 22, not the old index 3.
        let current = state(rows: changedRows, firstIndex: 20)

        let output = try XCTUnwrap(AXStateDiff.diff(previous: previous, current: current))
        let outputLines = lines(output)

        XCTAssertEqual(outputLines.first, "Changes since your last read (2 of 7 lines; indexes below are current):")
        XCTAssertEqual(outputLines.filter { $0.hasPrefix("+ ") }, ["+ \t22 text field To = sam@x.com (w:str)"])
        XCTAssertEqual(outputLines.filter { $0.hasPrefix("- ") }, ["- text field To = a@x.com (w:str)"])
        XCTAssertEqual(outputLines.last, "Unchanged: 6 lines. Ask get_app_state for the full window if needed.")
    }

    func testAddedDialogLinesShowAsPlusLines() throws {
        let previous = state(rows: baseRows)
        var withDialog = baseRows
        withDialog.insert(contentsOf: [
            (0, "dialog Confirm delete"),
            (1, "button OK"),
            (1, "text Are you sure?"),
        ], at: 2)
        let current = state(rows: withDialog)

        let output = try XCTUnwrap(AXStateDiff.diff(previous: previous, current: current))
        let outputLines = lines(output)

        XCTAssertEqual(outputLines.filter { $0.hasPrefix("+ ") }.count, 3)
        XCTAssertEqual(outputLines.filter { $0.hasPrefix("- ") }.count, 0)
        // "button OK" is the fourth row, so with headers in front it reads index 4 in the current state.
        XCTAssertTrue(outputLines.contains("+ \t4 button OK"), output)
        XCTAssertTrue(output.contains("(3 of 10 lines"), output)
        XCTAssertTrue(output.contains("Unchanged: 7 lines."), output)
    }

    func testLongRemovedRunCollapsesToSummary() throws {
        let rows = bigRows(30)
        let previous = state(rows: rows)
        let current = state(rows: Array(rows[0..<4]) + Array(rows[16...]))

        let output = try XCTUnwrap(AXStateDiff.diff(previous: previous, current: current))
        let outputLines = lines(output)

        XCTAssertEqual(outputLines.filter { $0.hasPrefix("- ") }.count, 9, "8 shown lines plus the summary")
        XCTAssertEqual(outputLines.filter { $0.hasPrefix("- ") }.last, "- (4 more lines removed)")
        XCTAssertEqual(outputLines.filter { $0.hasPrefix("+ ") }.count, 0)
        // Removed lines lose their stale index.
        XCTAssertEqual(outputLines[1], "- static text row 4 lorem ipsum")
    }

    func testHeaderLinesAppearOnlyWhenChanged() throws {
        let rows = baseRows
        let sameHeader = try XCTUnwrap(AXStateDiff.diff(
            previous: state(rows: rows),
            current: state(rows: rows.map { ($0.0, $0.1 == "button Send" ? "button Send now" : $0.1) })
        ))
        XCTAssertFalse(sameHeader.contains("Window:"), sameHeader)
        XCTAssertFalse(sameHeader.contains("App="), sameHeader)

        let newTitle = try XCTUnwrap(AXStateDiff.diff(
            previous: state(title: "Notes", rows: rows),
            current: state(title: "Drafts", rows: rows)
        ))
        XCTAssertTrue(newTitle.contains("+ Window: \"Drafts\", App: Notes."), newTitle)
        XCTAssertTrue(newTitle.contains("- Window: \"Notes\", App: Notes."), newTitle)
        XCTAssertFalse(newTitle.contains("App=com.apple.Notes"), newTitle)
    }

    // MARK: - Fallback to full state

    func testEmptyPreviousReturnsNil() {
        XCTAssertNil(AXStateDiff.diff(previous: "", current: "anything"))
    }

    func testLargeChangeReturnsNil() {
        let rows = bigRows(100)
        let previous = state(rows: rows)
        // Rewrite 80 of 100 rows: far above the default 50% threshold.
        let rewritten = rows.enumerated().map { $0.offset < 80 ? ($0.element.0, "fresh dialog row \($0.offset)") : $0.element }
        XCTAssertNil(AXStateDiff.diff(previous: previous, current: state(rows: rewritten)))
    }

    func testModerateChangeStillSummarises() {
        let rows = bigRows(100)
        let previous = state(rows: rows)
        // 20 rows changed out of about 100: under the threshold.
        let edited = rows.enumerated().map { $0.offset % 5 == 0 ? ($0.element.0, "edited row \($0.offset)") : $0.element }
        XCTAssertNotNil(AXStateDiff.diff(previous: previous, current: state(rows: edited)))
    }

    func testThresholdIsConfigurable() {
        let rows = bigRows(100)
        let previous = state(rows: rows)
        let edited = rows.enumerated().map { $0.offset % 5 == 0 ? ($0.element.0, "edited row \($0.offset)") : $0.element }
        XCTAssertNil(AXStateDiff.diff(previous: previous, current: state(rows: edited), maxChangedFraction: 0.1))
    }

    // MARK: - strippedContent

    func testStrippedContentDropsIndentationAndIndex() {
        XCTAssertEqual(AXStateDiff.strippedContent(of: "\t\t12 button Send"), "button Send")
        XCTAssertEqual(AXStateDiff.strippedContent(of: "\t\t  12 button Send"), "button Send")
        XCTAssertEqual(AXStateDiff.strippedContent(of: "    3 text field To = x (w:str)"), "text field To = x (w:str)")
        XCTAssertEqual(AXStateDiff.strippedContent(of: "\t12"), "12", "a bare number is not an index")
        XCTAssertEqual(AXStateDiff.strippedContent(of: "# heading"), "# heading")
        XCTAssertEqual(AXStateDiff.strippedContent(of: "App=com.apple.Notes (pid 4242)"), "App=com.apple.Notes (pid 4242)")
    }

    // MARK: - Performance

    func testDiffingTwoThousandLineTreesIsFast() {
        // 2,000 lines in total: 3 header lines and 1,997 rows. The current read is renumbered and
        // has 50 scattered value changes, which forces a real edit script rather than the prefix trim.
        let rows = bigRows(1997)
        let previous = state(rows: rows, firstIndex: 1)
        var changed = rows
        for offset in stride(from: 7, to: rows.count, by: 40) {
            changed[offset].1 = "scattered change \(offset)"
        }
        let current = state(rows: changed, firstIndex: 5000)

        let start = DispatchTime.now().uptimeNanoseconds
        let output = AXStateDiff.diff(previous: previous, current: current)
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertNotNil(output)
        XCTAssertEqual(output.map { lines($0).filter { $0.hasPrefix("+ ") }.count }, 50)
        XCTAssertLessThan(elapsedMilliseconds, 100, "diff took \(elapsedMilliseconds) ms")
    }
}
