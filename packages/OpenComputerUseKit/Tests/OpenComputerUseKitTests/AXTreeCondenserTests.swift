import Foundation
import XCTest
@testable import OpenComputerUseKit

/// All trees here are synthetic. Nothing is copied from recorded sessions.
final class AXTreeCondenserTests: XCTestCase {
    private func options(
        drop: Bool = false, collapse: Bool = false, truncate: Bool = false, dedupe: Bool = false,
        keepRuns: Int = 6, keepLast: Int = 2, maxTextLength: Int = 160,
        hidden: Bool = false, unwrap: Bool = false, description: Int = 0, repeated: Bool = false, budget: Int = 0
    ) -> AXTreeCondenser.Options {
        AXTreeCondenser.Options(
            dropStructuralNoise: drop, collapseRuns: collapse, keepRuns: keepRuns, keepLast: keepLast,
            truncateText: truncate, maxTextLength: maxTextLength, dedupeText: dedupe,
            dropHidden: hidden, unwrapSingleChild: unwrap, maxDescriptionLength: description,
            dropRepeatedProperties: repeated, maxCharacters: budget
        )
    }

    private func rows(_ range: ClosedRange<Int>, mark: [Int: String] = [:]) -> [String] {
        range.map { "\t\t\($0) row Song \($0)\(mark[$0] ?? "")" }
    }

    private func tree(_ lines: [String]) -> String {
        (["Window: Synthetic"] + lines).joined(separator: "\n")
    }

    func testCompactObservationKeepsControlsAndContextWithTheirOriginalNumbers() {
        let header = ["App=Synthetic", "Window=Library", "[w=settable]"]
        let body = [
            "0 window Library",
            "\t1 group",
            "\t\t2 scroll area (offscreen)",
            "\t\t\t3 group Selected playlist",
            "\t\t\t\t4 text Side A",
            "\t\t\t\t5 link Details",
            "\t\t\t\t6 group Secondary Actions: Press",
            "\t\t\t\t7 image",
            "\t\t\t\t8 image (focused)",
            "\t\t\t\t9 text field (w:str) Search = Miles",
            "\t10 button Next",
        ]
        let result = AXTreeCondenser.compactObservation((header + body + [""]).joined(separator: "\n"))
        XCTAssertEqual(result.components(separatedBy: "\n"), header + [
            "0 window Library",
            "\t2 scroll area (offscreen)",
            "\t\t3 group Selected playlist",
            "\t\t\t4 text Side A",
            "\t\t\t5 link Details",
            "\t\t\t6 group Secondary Actions: Press",
            "\t\t\t8 image (focused)",
            "\t\t\t9 text field (w:str) Search = Miles",
            "\t10 button Next",
            "",
        ])
    }

    func testCompactObservationKeepsAllRepeatedRowsAndFocusPastStandardBudget() {
        let links = (1...500).map { "\t\($0) link Item \($0) with a long descriptive title" }
        let lines = ["App=Synthetic", "0 window Library"] + links + ["\t501 text field (focused) Search"]
        let state = ToolCallResult(content: [.text(lines.joined(separator: "\n")), .text("Separate note")], isError: false)
        let result = LeanOutput.condensed(state, mode: .compact)
        XCTAssertEqual(result.content.map { $0.dictionary["text"] as? String }, [
            lines.joined(separator: "\n"), "Separate note",
        ])
    }

    func testCompactObservationPreservesActionIndexesWithoutRenderedTraits() {
        let lines = ["App=Synthetic", "0 window Library", "\t1 group", "\t\t2 image", "\t\t3 image"]
        let result = AXTreeCondenser.compactObservation(lines.joined(separator: "\n"), preserving: ["1", "3"])
        XCTAssertEqual(result.components(separatedBy: "\n"), Array(lines.prefix(3)) + [lines[4]])
    }

    func testCompactObservationKeepsPackedIndentationAcrossTabBoundary() {
        let input = [
            "App=Synthetic", "[tab=4 w=settable]", "0 window Library",
            " 1 group Named", "  2 group Named", "   3 group", "\t4 button Save", "  5 button Other",
        ]
        XCTAssertEqual(
            AXTreeCondenser.compactObservation(input.joined(separator: "\n")).components(separatedBy: "\n"),
            ["App=Synthetic", "[tab=4 w=settable]", "0 window Library",
             " 1 group Named", "  2 group Named", "   4 button Save", "  5 button Other"]
        )
    }

    // MARK: - Header

    func testHeaderLinesAreUntouched() {
        let header = ["App: Synthetic", "  Focused: nothing   ", "Note: 2 things"]
        let input = (header + ["0 window Synthetic", "\t1 group", "\t\t2 button Play"]).joined(separator: "\n")
        let output = AXTreeCondenser.condense(input)
        XCTAssertEqual(output.components(separatedBy: "\n").prefix(3), header[...])
    }

    // MARK: - Rule 1

    func testDropsUnlabeledContainersAndReindentsChildren() {
        let input = [
            "0 window Music",
            "\t1 group",
            "\t\t2 scroll area",
            "\t\t\t3 button Play",
            "\t4 group Sidebar",
            "\t\t5 link Home",
        ].joined(separator: "\n")
        let output = AXTreeCondenser.condense(input, options: options(drop: true))
        // The bare group goes; the scroll area stays (the model scrolls by its index).
        XCTAssertEqual(output, [
            "0 window Music",
            "\t2 scroll area",
            "\t\t3 button Play",
            "\t4 group Sidebar",
            "\t\t5 link Home",
        ].joined(separator: "\n"))
    }

    func testKeepsLabeledAndActionableContainers() {
        let lines = [
            "0 window Music",
            "\t1 group Sidebar",
            "\t2 group Secondary Actions: Press",
            "\t\t3 text Home",
        ]
        let input = lines.joined(separator: "\n")
        XCTAssertEqual(AXTreeCondenser.condense(input, options: options(drop: true)), input)
    }

    // MARK: - Rule 2

    func testCollapsesLongRunKeepingFirstSixAndLastTwo() {
        let input = tree(rows(2...21))
        let output = AXTreeCondenser.condense(input, options: options(collapse: true))
        let expected = ["Window: Synthetic"] + rows(2...7) + [
            "\t\t…(12 more rows like these; use query to find one)",
        ] + rows(20...21)
        XCTAssertEqual(output.components(separatedBy: "\n"), expected)
    }

    func testRunsAreNotCollapsedWhenTooShort() {
        let input = tree(rows(2...9))
        XCTAssertEqual(AXTreeCondenser.condense(input, options: options(collapse: true)), input)
    }

    func testSelectedFocusedAndSettableRowsAreNeverCollapsed() {
        let input = tree(rows(2...21, mark: [9: " (selected)", 12: " (focused)", 15: " (w:str)"]))
        let output = AXTreeCondenser.condense(input, options: options(collapse: true)).components(separatedBy: "\n")
        let expected = ["Window: Synthetic"] + rows(2...8) + [
            "\t\t9 row Song 9 (selected)",
            "\t\t…(2 more rows like these; use query to find one)",
            "\t\t12 row Song 12 (focused)",
            "\t\t…(2 more rows like these; use query to find one)",
            "\t\t15 row Song 15 (w:str)",
            "\t\t…(4 more rows like these; use query to find one)",
        ] + rows(20...21)
        XCTAssertEqual(output, expected)
    }

    func testRowsHoldingButtonsAreKept() {
        var lines = rows(2...21)
        lines.insert("\t\t\t\t30 button Like", at: 11)
        let output = AXTreeCondenser.condense(tree(lines), options: options(collapse: true))
        XCTAssertTrue(output.contains("30 button Like"))
    }

    // MARK: - Rule 3

    func testTruncatesLongTextLines() {
        let long = String(repeating: "a", count: 200)
        let output = AXTreeCondenser.condense("0 window X\n\t1 text \(long)", options: options(truncate: true))
        XCTAssertEqual(output, "0 window X\n\t1 text " + String(repeating: "a", count: 160) + "…")
    }

    func testShortTextIsNotTruncated() {
        let input = "0 window X\n\t1 text short"
        XCTAssertEqual(AXTreeCondenser.condense(input, options: options(truncate: true)), input)
    }

    // MARK: - Rule 4

    func testRemovesConsecutiveDuplicateTextLines() {
        let input = ["0 window X", "\t1 text Hello", "\t2 text Hello", "\t3 text Bye"].joined(separator: "\n")
        let output = AXTreeCondenser.condense(input, options: options(dedupe: true))
        XCTAssertEqual(output, ["0 window X", "\t1 text Hello", "\t3 text Bye"].joined(separator: "\n"))
    }

    func testDoesNotRemoveNonConsecutiveDuplicates() {
        let input = ["0 window X", "\t1 text Hello", "\t2 button Other", "\t3 text Hello"].joined(separator: "\n")
        XCTAssertEqual(AXTreeCondenser.condense(input, options: options(dedupe: true)), input)
    }

    // MARK: - Stats and empty input

    func testStatsCountLinesBeforeAndAfter() {
        let input = ["0 window X", "\t1 text Hello", "\t2 text Hello", "\t3 text Bye"].joined(separator: "\n")
        let result = AXTreeCondenser.condenseWithStats(input)
        XCTAssertEqual(result.before, 4)
        XCTAssertEqual(result.after, 3)
        XCTAssertEqual(result.text, AXTreeCondenser.condense(input))
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(AXTreeCondenser.condense(""), "")
        let result = AXTreeCondenser.condenseWithStats("")
        XCTAssertEqual(result.before, 0)
        XCTAssertEqual(result.after, 0)
    }

    // MARK: - Synthetic Spotify-like tree

    /// Roughly 1,500 lines: a toolbar, an unlabeled wrapper, a long song list where each row
    /// has two repeated text children, a few rows with buttons, one selected row, and a player bar.
    private func spotifyLikeTree(minimumLines: Int = 1500) -> String {
        var lines = [
            "App: Spotify",
            "Window: Spotify, 1 window",
            "0 window Spotify",
            "\t1 toolbar",
            "\t\t2 button Back",
            "\t\t3 button Forward",
            "\t\t4 text field Search (w:str) = jazz",
            "\t5 group",
            "\t\t6 scroll area",
            "\t\t\t7 list Songs",
        ]
        var index = 8
        var row = 0
        while lines.count < minimumLines - 5 {
            let rowIndex = index
            lines.append("\t\t\t\t\(rowIndex) row Song \(row), Artist \(row % 37)" + (row == 40 ? " (selected)" : ""))
            index += 1
            lines.append("\t\t\t\t\t\(index) text Song \(row)")
            index += 1
            lines.append("\t\t\t\t\t\(index) text Song \(row)")
            index += 1
            if row % 50 == 25 {
                lines.append("\t\t\t\t\t\(index) button More")
                index += 1
            }
            row += 1
        }
        lines += [
            "\t\(index) group",
            "\t\t\(index + 1) button Previous",
            "\t\t\(index + 2) button Play",
            "\t\t\(index + 3) slider Progress (w:float) = 0.4",
            "\t\t\(index + 4) text field Volume (w:float) = 0.8",
        ]
        return lines.joined(separator: "\n")
    }

    private func indexAndBody(_ line: String) -> (index: String, body: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, Int(pieces[0]) != nil else { return nil }
        return (String(pieces[0]), String(pieces[1]))
    }

    func testSyntheticSpotifyTreeShrinksByMoreThanHalfAndKeepsActionableLines() {
        let input = spotifyLikeTree()
        let result = AXTreeCondenser.condenseWithStats(input)
        XCTAssertGreaterThanOrEqual(result.before, 1500)
        XCTAssertLessThan(Double(result.after), Double(result.before) * 0.5)

        let outputLines = result.text.components(separatedBy: "\n")
        let outputTrimmed = Set(outputLines.map { $0.trimmingCharacters(in: .whitespaces) })

        for line in input.components(separatedBy: "\n") {
            let important = line.contains(" button ") || line.contains(" text field ")
                || line.contains(" slider ") || line.contains("(selected)")
            if important {
                XCTAssertTrue(outputTrimmed.contains(line.trimmingCharacters(in: .whitespaces)), "lost: \(line)")
            }
        }
    }

    func testEveryKeptIndexKeepsItsOriginalLine() {
        let input = spotifyLikeTree()
        var original: [String: String] = [:]
        for line in input.components(separatedBy: "\n") {
            if let parsed = indexAndBody(line) { original[parsed.index] = parsed.body }
        }
        let output = AXTreeCondenser.condense(input)
        for line in output.components(separatedBy: "\n") {
            guard let parsed = indexAndBody(line) else { continue }
            XCTAssertEqual(original[parsed.index], parsed.body, "index \(parsed.index) changed")
        }
    }

    func testTwoThousandLinesCondensesUnder50Milliseconds() {
        let input = spotifyLikeTree(minimumLines: 2000)
        XCTAssertGreaterThanOrEqual(input.components(separatedBy: "\n").count, 2000)
        let start = DispatchTime.now().uptimeNanoseconds
        _ = AXTreeCondenser.condense(input)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(elapsedMs, 50, "condense took \(elapsedMs) ms")
    }

    // MARK: - Compaction rules (hidden, unwrap, descriptions, repeats, budget)

    func testDropsHiddenAndOffscreenButKeepsHiddenStateAndBareDecoration() {
        let input = [
            "0 window X",
            "\t1 button Ghost (hidden)",
            "\t\t2 text under ghost",
            "\t3 row Far (offscreen)",
            "\t4 row Pinned (offscreen, selected)",
            "\t5 image",
            "\t6 image Logo",
            "\t7 separator",
            "\t8 button Play",
        ].joined(separator: "\n")
        let output = AXTreeCondenser.condense(input, options: options(hidden: true))
        XCTAssertEqual(output, ["0 window X", "\t4 row Pinned (offscreen, selected)", "\t6 image Logo", "\t8 button Play"].joined(separator: "\n"))
    }

    func testUnwrapsSingleChildGroupsButNotBusyOnes() {
        let input = [
            "0 window X",
            "\t1 group",
            "\t\t2 group Settings",
            "\t\t\t3 text Settings",
            "\t4 group Toolbar",
            "\t\t5 button A",
            "\t\t6 button B",
            "\t7 group Card",
            "\t\t8 button Buy",
        ].joined(separator: "\n")
        let output = AXTreeCondenser.condense(input, options: options(drop: true, unwrap: true))
        XCTAssertEqual(output, [
            "0 window X",
            "\t3 text Settings",
            "\t4 group Toolbar",
            "\t\t5 button A",
            "\t\t6 button B",
            "\t7 group Card",
            "\t\t8 button Buy",
        ].joined(separator: "\n"))
    }

    func testCutsLongDescriptionsToEighty() {
        let long = String(repeating: "d", count: 120)
        let input = "0 window X\n\t1 button Play Description: \(long), Secondary Actions: Press"
        let output = AXTreeCondenser.condense(input, options: options(description: 80))
        XCTAssertEqual(output, "0 window X\n\t1 button Play Description: " + String(repeating: "d", count: 80) + "…, Secondary Actions: Press")
    }

    func testDropsHelpRepeatedFromThePreviousSibling() {
        let input = [
            "0 window X",
            "\t1 button Cut Help: Edit the text",
            "\t2 button Copy Help: Edit the text",
            "\t3 button Paste Help: Other",
        ].joined(separator: "\n")
        let output = AXTreeCondenser.condense(input, options: options(repeated: true))
        XCTAssertEqual(output, ["0 window X", "\t1 button Cut Help: Edit the text", "\t2 button Copy", "\t3 button Paste Help: Other"].joined(separator: "\n"))
    }

    func testStateRowsSplitFoldsAndAreNeverFolded() {
        let input = tree(rows(2...41, mark: [20: " (checked)", 25: " = 40"]))
        let output = AXTreeCondenser.condense(input, options: options(collapse: true))
        XCTAssertTrue(output.contains("20 row Song 20 (checked)"))
        XCTAssertTrue(output.contains("25 row Song 25 = 40"))
        XCTAssertEqual(output.components(separatedBy: "\n").filter { $0.contains("more rows") }.count, 3)
    }

    func testBudgetCutsWithVisibleLineAndKeepsActionableAfterwards() {
        var lines = ["0 window X"]
        for n in 1...400 { lines.append("\t\(n) text Line number \(n) with some padding words") }
        lines.append("\t999 button Send")
        let output = AXTreeCondenser.condense(lines.joined(separator: "\n"), options: options(budget: 3000))
        XCTAssertLessThan(output.count, 3200)
        XCTAssertTrue(output.contains("999 button Send"))
        XCTAssertTrue(output.contains("more lines cut to fit; use query"))
    }

    func testDefaultOutputStaysWithinBudgetOnHugeTree() {
        let output = AXTreeCondenser.condense(spotifyLikeTree(minimumLines: 6000))
        XCTAssertLessThan(output.count, 18_000)
    }
}
