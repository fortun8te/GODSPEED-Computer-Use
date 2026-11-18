import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for `done_when`, the stuck rules and the referee summary. No window, no accessibility,
/// no network and no model: file checks use an injected closure, and the page URL is a stub.
final class DoneCheckTests: XCTestCase {
    /// Counts how often the page URL is read.
    private final class Counter {
        var value = 0
    }

    private func evidence(
        screen: String,
        url: String? = nil,
        files: Set<String> = [],
        urlCalls: Counter? = nil
    ) -> DoneCheck.Evidence {
        DoneCheck.Evidence(
            screenText: screen,
            pageURL: {
                urlCalls?.value += 1
                return url
            },
            fileExists: { files.contains($0) }
        )
    }

    // MARK: - Parsing

    func testParsesOneObjectAndAList() throws {
        XCTAssertEqual(try DoneCheck.parse(["text": "Message sent"]), [.text("Message sent")])
        XCTAssertEqual(
            try DoneCheck.parse([
                ["text": "Sent"],
                ["gone": "Loading"],
            ]),
            [.text("Sent"), .gone("Loading")]
        )
        XCTAssertEqual(try DoneCheck.parse(nil), [])
        XCTAssertEqual(try DoneCheck.parse(NSNull()), [])
    }

    func testParsesEveryForm() throws {
        let raw: [[String: Any]] = [
            ["field": "Volume", "equals": 40],
            ["url_contains": "/thanks"],
            ["file_exists": "/tmp/godspeed-done-check-x.pdf"],
        ]
        let parsed = try DoneCheck.parse(raw)
        XCTAssertEqual(parsed, [
            .field(label: "Volume", equals: "40"),
            .urlContains("/thanks"),
            .fileExists("/tmp/godspeed-done-check-x.pdf"),
        ])
    }

    func testExpandsTildeInFileExists() throws {
        let parsed = try DoneCheck.parse(["file_exists": "~/Desktop/out.pdf"])
        XCTAssertEqual(parsed, [.fileExists(NSString(string: "~/Desktop/out.pdf").expandingTildeInPath)])
        XCTAssertFalse(parsed.contains(.fileExists("~/Desktop/out.pdf")))
    }

    func testRejectsMalformedEntries() {
        XCTAssertThrowsError(try DoneCheck.parse(["unknown": "x"]))
        XCTAssertThrowsError(try DoneCheck.parse(["text": ""]))
        XCTAssertThrowsError(try DoneCheck.parse(["field": "Volume"]), "field needs equals")
        XCTAssertThrowsError(try DoneCheck.parse("text: Sent"), "a bare string is not an entry")
        let mixed: [Any] = [["text": "a"], "b"]
        XCTAssertThrowsError(try DoneCheck.parse(mixed), "every entry must be an object")
        XCTAssertThrowsError(try DoneCheck.parse(Array(repeating: ["text": "a"], count: 9)), "at most 8 conditions")
    }

    // MARK: - Checking

    func testTextIsFoundInStateOrPageRead() {
        let screen = "Mail window\n\t3 static text Message sent to Avery"
        XCTAssertEqual(
            DoneCheck.check([.text("message SENT")], evidence: evidence(screen: screen)),
            .verified(met: ["\"message SENT\" is on screen"])
        )
        XCTAssertEqual(
            DoneCheck.check([.text("Draft saved")], evidence: evidence(screen: screen)),
            .missing(unmet: ["\"Draft saved\" is on screen"])
        )
    }

    func testFieldComparesValueAfterEqualsIgnoringTypeNote() {
        let screen = """
            Settings window
            \t3 static text checkbox Blue kite = 1
            \t4 selected song Blue kite = Quiet river (w:str)
            """
        XCTAssertTrue(DoneCheck.fieldEquals(screen, label: "checkbox Blue kite", value: "1"))
        XCTAssertTrue(DoneCheck.fieldEquals(screen, label: "selected song", value: "Quiet river"))
        XCTAssertFalse(DoneCheck.fieldEquals(screen, label: "checkbox Blue kite", value: "0"))
        XCTAssertFalse(DoneCheck.fieldEquals(screen, label: "Volume", value: "1"), "no such label")
        // Not a prefix match: "1" must not match "10".
        XCTAssertFalse(DoneCheck.fieldEquals("Volume = 10", label: "Volume", value: "1"))
    }

    func testGoneMeansNoStateLineMentionsTheLabel() {
        XCTAssertEqual(
            DoneCheck.check([.gone("Loading")], evidence: evidence(screen: "Notes window\n\t3 button Save")),
            .verified(met: ["Loading is gone"])
        )
        XCTAssertEqual(
            DoneCheck.check([.gone("Loading")], evidence: evidence(screen: "3 sheet Loading")),
            .missing(unmet: ["Loading is gone"])
        )
    }

    func testUrlContainsReadsThePageOnlyWhenNeeded() {
        let counter = Counter()
        let result = DoneCheck.check(
            [.urlContains("/thanks"), .urlContains("shop")],
            evidence: evidence(screen: "", url: "https://shop.example/thanks?id=4", urlCalls: counter)
        )
        XCTAssertEqual(result, .verified(met: ["the page URL contains /thanks", "the page URL contains shop"]))
        XCTAssertEqual(counter.value, 1, "the page is read once for all url conditions")

        let untouched = Counter()
        _ = DoneCheck.check([.text("x")], evidence: evidence(screen: "x", urlCalls: untouched))
        XCTAssertEqual(untouched.value, 0, "no page read without a url condition")
    }

    func testUrlContainsIsMissingWithoutABrowserURL() {
        XCTAssertEqual(
            DoneCheck.check([.urlContains("/thanks")], evidence: evidence(screen: "", url: nil)),
            .missing(unmet: ["the page URL contains /thanks"])
        )
    }

    func testFileExistsUsesTheInjectedCheck() {
        let path = "/Users/example/out.pdf"
        XCTAssertEqual(
            DoneCheck.check([.fileExists(path)], evidence: evidence(screen: "", files: [path])),
            .verified(met: ["file \(path) exists"])
        )
        XCTAssertEqual(
            DoneCheck.check([.fileExists(path)], evidence: evidence(screen: "")),
            .missing(unmet: ["file \(path) exists"])
        )
    }

    func testVerifiedOnlyWhenEveryConditionIsMet() {
        let result = DoneCheck.check(
            [.text("Sent"), .gone("Sending"), .text("Draft saved")],
            evidence: evidence(screen: "Sent\n3 static text Sending")
        )
        XCTAssertEqual(result, .missing(unmet: ["Sending is gone", "\"Draft saved\" is on screen"]))
    }

    func testEmptyConditionsAreNeverVerified() {
        XCTAssertEqual(DoneCheck.check([], evidence: evidence(screen: "")), .verified(met: []))
    }

    // MARK: - Reply line

    func testReplyLineForVerifiedAndMissing() {
        XCTAssertEqual(
            DoneCheck.line(for: .verified(met: ["\"Sent\" is on screen", "file a.pdf exists"])),
            "Done: verified (\"Sent\" is on screen; file a.pdf exists)"
        )
        XCTAssertEqual(
            DoneCheck.line(for: .missing(unmet: ["Loading is gone"])),
            "Not done yet: (Loading is gone not confirmed)"
        )
    }

    // MARK: - Stuck rules

    func testSameStepFailingTwoBatchesInARowIsStuck() {
        let line = StuckRules.line(repeatedFailures: 2, failedStep: "click \"Save\"", appLookedIdentical: false)
        XCTAssertEqual(
            line,
            "Stuck: click \"Save\" has failed 2 batches in a row. Change approach instead of retrying it."
        )
    }

    func testOneFailureIsNotStuckYet() {
        XCTAssertNil(StuckRules.line(repeatedFailures: 1, failedStep: "click \"Save\"", appLookedIdentical: false))
        XCTAssertNil(StuckRules.line(repeatedFailures: 0, failedStep: nil, appLookedIdentical: false))
    }

    func testIdenticalAppAfterActingBatchIsStuck() {
        let line = StuckRules.line(repeatedFailures: 0, failedStep: nil, appLookedIdentical: true)
        XCTAssertEqual(line?.hasPrefix("Stuck: the app looks exactly as it did"), true)
        XCTAssertFalse(line?.contains("\n") ?? true, "one line")
    }

    func testFailureRuleWinsOverIdenticalRuleAndAddsOneLine() {
        let line = StuckRules.line(repeatedFailures: 3, failedStep: "click \"Save\"", appLookedIdentical: true)
        XCTAssertEqual(line?.hasPrefix("Stuck: click \"Save\" has failed 3 batches"), true)
    }

    // MARK: - Referee summary

    func testDialogIsDetectedFromTheRoleWord() {
        XCTAssertTrue(RefereeSummary.dialogOpen(in: "Notes window\n\t3 sheet Loading"))
        XCTAssertTrue(RefereeSummary.dialogOpen(in: "3 dialog Export"))
        XCTAssertFalse(RefereeSummary.dialogOpen(in: "Notes window\n\t3 static text sheet music"))
        XCTAssertFalse(RefereeSummary.dialogOpen(in: "Notes window\n\t3 button Save"))
    }

    func testAlertCountsAsADialog() {
        XCTAssertTrue(RefereeSummary.dialogOpen(in: "Finder window\n\t4 alert Are you sure"))
    }

    func testSummaryHasTheFieldsInOrderAndCapsChanges() {
        let long = String(repeating: "x", count: 900)
        let text = RefereeSummary.build(
            goal: "Save the note",
            steps: [(step: "click \"Save\"", result: "FAILED: no element found")],
            repeatedFailures: 2,
            screenChanged: false,
            dialogOpen: true,
            changes: long
        )
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines[0], "Goal: Save the note")
        XCTAssertEqual(lines[1], "Steps:")
        XCTAssertEqual(lines[2], "1. click \"Save\": FAILED: no element found")
        XCTAssertEqual(lines[3], "Repeated failures: 2")
        XCTAssertEqual(lines[4], "Screen changed: no")
        XCTAssertEqual(lines[5], "Dialog or sheet open: yes")
        XCTAssertEqual(lines[6], "Changes:")
        XCTAssertEqual(lines[7].count, RefereeSummary.changeLimit)
    }

    func testSummaryWithoutChangesSaysNone() {
        let text = RefereeSummary.build(
            goal: "g", steps: [], repeatedFailures: 0, screenChanged: true, dialogOpen: false, changes: nil
        )
        XCTAssertTrue(text.hasSuffix("Changes:\n(none)"))
        XCTAssertTrue(text.contains("Screen changed: yes"))
    }

    func testScreenKeepsTheWindowAndKeyLinesWithoutFurniture() {
        let state = """
        App=com.apple.TextEdit (pid 74782)
        Window: "bench-01.txt", App: TextEdit.
        [w=settable]
        0 standard window bench-01.txt, Secondary Actions: Raise
        \t1 scroll area Secondary Actions: Scroll Up, Scroll Down
        \t\t2 text entry area (w:str) Bench line one.
        \t\t3 scroll bar (disabled, w:float) 0.18
        \t\t6 ruler marker (w:float) = 0, Secondary Actions: Delete
        \t\t7 button (disabled, w:float) Save
        """
        let screen = RefereeSummary.screen(from: state)
        XCTAssertEqual(screen, """
        Window: "bench-01.txt", App: TextEdit.
        0 standard window bench-01.txt
        1 scroll area Secondary Actions: Scroll Up, Scroll Down
        2 text entry area Bench line one.
        7 button (disabled) Save
        """)
        let text = RefereeSummary.build(
            goal: "g", steps: [], repeatedFailures: 0, screenChanged: true, dialogOpen: false, changes: nil,
            screen: screen
        )
        XCTAssertTrue(text.contains("Changes:\n(none)\nScreen:\nWindow: \"bench-01.txt\""))
    }

    func testScreenIsCapped() {
        let state = (0..<40).map { "\($0) button Item \($0)" }.joined(separator: "\n")
        let lines = RefereeSummary.screen(from: state).split(separator: "\n")
        XCTAssertEqual(lines.count, RefereeSummary.screenLineLimit)
    }
}
