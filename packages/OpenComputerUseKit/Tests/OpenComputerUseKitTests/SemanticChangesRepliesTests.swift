import XCTest
@testable import OpenComputerUseKit

/// Change-only batch replies with a `Changes:` summary (`OPEN_COMPUTER_USE_SEMANTIC_REPLIES`).
/// Before/after fixtures: each test reads the reply with the setting on and off.
final class SemanticChangesRepliesTests: XCTestCase {
    private let header = "App=com.apple.Notes (pid 4242)\nWindow: \"Notes\", App: Notes.\n[w=settable]"
    private var savedMinimum = 0

    // The fixtures are small; production skips the summary on diffs under 400 bytes (see the last test).
    override func setUp() {
        super.setUp()
        savedMinimum = LeanOutput.semanticSummaryMinDiffLength
        LeanOutput.semanticSummaryMinDiffLength = 0
    }

    override func tearDown() {
        LeanOutput.semanticSummaryMinDiffLength = savedMinimum
        super.tearDown()
    }

    func testShortDiffsAreSentWithoutASummaryLine() {
        LeanOutput.semanticSummaryMinDiffLength = 400
        let reply = LeanOutput.semanticDiffReply(header: "H", diff: "Changed:\n+ 4 text field To = b", before: "1 text field To = a",
                                                 after: "1 text field To = b")
        XCTAssertEqual(reply, "H\nChanged:\n+ 4 text field To = b")
    }

    private func tree(_ lines: [String]) -> String {
        ([header] + lines).joined(separator: "\n")
    }

    private func row(_ number: Int, _ depth: Int, _ text: String) -> String {
        String(repeating: "\t", count: depth) + "\(number) \(text)"
    }

    /// A window with `count` long list rows, numbered from 2.
    private func window(rows count: Int = 30) -> [String] {
        [row(1, 0, "window Notes")] + (2...(count + 1)).map { row($0, 1, "button Message row \($0) in the mailbox list, unread") }
    }

    /// Runs `body` with `OPEN_COMPUTER_USE_SEMANTIC_REPLIES` set to `value`, restoring the old value after.
    private func withSemanticReplies<T>(_ value: String?, _ body: () -> T) -> T {
        let key = "OPEN_COMPUTER_USE_SEMANTIC_REPLIES"
        let previous = ProcessInfo.processInfo.environment[key]
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return body()
    }

    private func reply(before: String, after: String, setting: String?) -> String {
        withSemanticReplies(setting) {
            LeanOutput.diffed(.text(after), previous: before).textContent
        }
    }

    // MARK: - (a) Dialog opened

    /// The Export dialog: numbered controls plus unnumbered layout lines that carry nothing to act on.
    private var exportDialogControls: [(Int, String)] {
        [
            (32, "button Choose folder for the export destination"),
            (33, "radio button PDF, for sending to other people"),
            (34, "radio button PNG, keeps a transparent background"),
            (35, "text field Folder = Documents/Exports (w:str)"),
            (36, "button Export now"),
            (37, "button Cancel export and keep the current settings"),
        ]
    }

    private func dialogOpenFixture() -> (before: String, after: String) {
        let before = tree(window())
        var dialog = [row(31, 1, "dialog Export options"), "\t\t\tlayout area"]
        for (number, text) in exportDialogControls {
            dialog.append(row(number, 2, text))
            dialog.append("\t\t\tgroup")
        }
        return (before, tree(window() + dialog))
    }

    func testDialogOpenReplyShrinksAndKeepsEveryNumberedControl() {
        let (before, after) = dialogOpenFixture()
        let on = reply(before: before, after: after, setting: nil)
        let off = reply(before: before, after: after, setting: "0")

        XCTAssertTrue(on.contains("Changes: Export options dialog opened"), on)
        XCTAssertLessThan(on.utf8.count, off.utf8.count)
        for (number, text) in exportDialogControls {
            XCTAssertTrue(on.contains("\(number) \(text)"), "missing \(number) \(text)\n\(on)")
        }
        XCTAssertFalse(on.contains("layout area"), on)
        XCTAssertFalse(on.contains("group"), on)
        print("SIZE (a) dialog open: full state \(after.utf8.count) B, change-only off \(off.utf8.count) B, on \(on.utf8.count) B")
    }

    // MARK: - (b) Value edit

    func testValueEditReadsAsLabelOldToNew() {
        let before = tree(window() + [row(32, 1, "text field To = a (w:str)")])
        let after = tree(window() + [row(32, 1, "text field To = b (w:str)")])
        let on = reply(before: before, after: after, setting: nil)
        let off = reply(before: before, after: after, setting: "0")

        XCTAssertTrue(on.contains("Changes: To: a → b"), on)
        XCTAssertTrue(on.contains("32 text field To = b (w:str)"), on)
        // A one-line summary costs a few bytes on a tiny diff; the gain is clarity, not size.
        XCTAssertLessThan(on.utf8.count, off.utf8.count + 60)
        print("SIZE (b) value edit: off \(off.utf8.count) B, on \(on.utf8.count) B")
    }

    // MARK: - (c) Setting off is today's output

    func testSettingOffReproducesTodaysTextExactly() {
        let (dialogBefore, dialogAfter) = dialogOpenFixture()
        let valueBefore = tree(window() + [row(32, 1, "text field To = a (w:str)")])
        let valueAfter = tree(window() + [row(32, 1, "text field To = b (w:str)")])

        for (before, after) in [(dialogBefore, dialogAfter), (valueBefore, valueAfter)] {
            // Today's change-only text: the header lines, a newline, then the AXStateDiff output.
            let headerLines = after.split(separator: "\n", maxSplits: 3).prefix(3).joined(separator: "\n")
            let expected = headerLines + "\n" + AXStateDiff.diff(
                previous: before, current: after, matchIndexes: ElementNumbering.isEnabled
            )!
            XCTAssertEqual(reply(before: before, after: after, setting: "0"), expected)
            XCTAssertEqual(reply(before: before, after: after, setting: "off"), expected)
        }
    }

    // MARK: - (d) Secure fields never leak

    func testSecureFieldValueNeverAppearsInTheChangesLine() {
        let before = tree(window() + [row(32, 1, "secure text field PIN = 1234 (w:str)")])
        let after = tree(window() + [row(32, 1, "secure text field PIN = 5678 (w:str)")])
        let on = reply(before: before, after: after, setting: nil)
        let changes = on.split(separator: "\n").first { $0.hasPrefix("Changes: ") }.map(String.init) ?? ""

        XCTAssertFalse(changes.isEmpty, on)
        XCTAssertFalse(changes.contains("1234"), changes)
        XCTAssertFalse(changes.contains("5678"), changes)
        XCTAssertTrue(changes.contains("PIN"), changes)
    }
}
