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

    func testDirectBrowserEvidenceDoesNotVerifyOtherConditions() {
        let wanted: [DoneCheck.Condition] = [.text("Sent"), .text("Receipt")]
        let evidence = DoneCheck.Evidence(screenText: nil, pageURL: { "https://example.test" },
                                          directlyVerified: [.text("Sent")])
        XCTAssertEqual(DoneCheck.check(wanted, evidence: evidence), .missing(unmet: [wanted[1].summary]))
    }

    func testDirectCompletionReadsFileAndExactFieldWithoutScreenState() {
        let conditions: [DoneCheck.Condition] = [.fileExists("/test/file"), .field(label: "Title", equals: "Ready")]
        var files: [String] = []
        var fields: [String] = []
        let result = DoneCheck.directCompletion(conditions, fileExists: {
            files.append($0)
            return true
        }, fieldValue: {
            fields.append($0)
            return "Ready"
        })
        XCTAssertEqual(result, .verified(met: conditions.map(\.summary)))
        XCTAssertEqual(files, ["/test/file"])
        XCTAssertEqual(fields, ["Title"])
        XCTAssertNil(DoneCheck.directCompletion(conditions, fileExists: { _ in true }, fieldValue: { _ in nil }))
        XCTAssertNil(DoneCheck.directCompletion([.text("Ready")], fieldValue: { _ in XCTFail("Text requires an observation"); return nil }))
    }

    func testDoneWhenAndWaitAcceptCommonSpellings() throws {
        XCTAssertEqual(try DoneCheck.parse(["contains": "Saved"]), [.text("Saved")])
        XCTAssertEqual(try DoneCheck.parse(["url": "/thanks"]), [.urlContains("/thanks")])
        XCTAssertEqual(try DoneCheck.parse(["field": "Volume", "is": 40]), [.field(label: "Volume", equals: "40")])
        XCTAssertEqual(try DoneCheck.parse(["absent": "Loading"]), [.gone("Loading")])
        XCTAssertThrowsError(try DoneCheck.parse(["nonsense": "x"]))
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["until": "Done"]).kind, .text("Done"))
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["dialog": "Export"]).kind, .window("Export"))
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["disappears": "Loading"]).kind, .gone("Loading"))
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["settle": 1]).kind, .settle)
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["text": "x", "timeout": 3]).timeoutMs, 3_000)
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["text": "x", "timeout": 2500]).timeoutMs, 2_500)
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["text": "x", "ms": 700]).timeoutMs, 700)
        XCTAssertThrowsError(try BatchEffects.Wait(arguments: ["nothing": true]))
    }

    func testDestructiveLabelsNeverFallThroughToMenuItems() {
        for label in ["Delete", "Delete…", "Move to Trash", "Don’t Save", "Don't Save", "Quit TextEdit", "Close Window", "Empty Trash", "Send"] {
            XCTAssertTrue(MenuItemLookup.isDestructive(label), label)
        }
        for label in ["Make Plain Text", "Show Fonts", "Select All", "Copy", "Paste", "Bold", "Closed Captions", "Sender Info", "Cuts list"] {
            XCTAssertFalse(MenuItemLookup.isDestructive(label), label)
        }
    }

    func testBrowserActionAliasesMapToRealActions() {
        XCTAssertEqual(ComputerUseToolDispatcher.canonicalBrowserAction("input"), "type")
        XCTAssertEqual(ComputerUseToolDispatcher.canonicalBrowserAction("list-tabs"), "tabs")
        XCTAssertEqual(ComputerUseToolDispatcher.canonicalBrowserAction("list_tabs"), "tabs")
        XCTAssertEqual(ComputerUseToolDispatcher.canonicalBrowserAction("scroll_down"), "scroll")
        XCTAssertEqual(ComputerUseToolDispatcher.canonicalBrowserAction("click"), "click")
        XCTAssertEqual(ComputerUseToolDispatcher.canonicalBrowserAction("nonsense"), "nonsense")
        // Every alias points at an action the browser tool lists.
        let listed = Set("open, go, read, screenshot, click, drag, type, fill_field, copy, cut, paste, key, hover, select, check, uncheck, scroll, scroll_into_view, back, forward, reload, wait_for, tabs, use_tab, close_tab, wait, location, info, outline, frames, read_text, link_destination, control_state, value, upload, peek".components(separatedBy: ", "))
        for (alias, action) in ComputerUseToolDispatcher.browserActionAliases {
            XCTAssertTrue(listed.contains(action), "\(alias) -> \(action)")
            XCTAssertFalse(ComputerUseToolDispatcher.knownBrowserActions.contains(alias), "\(alias) shadows a real action")
            XCTAssertTrue(ComputerUseToolDispatcher.knownBrowserActions.contains(action), "\(alias) -> unknown \(action)")
        }
    }

    func testFrozenAppMessageNamesTheAppAndStopsRetries() {
        XCTAssertTrue(SnapshotBuilder.appLooksFrozen(.cannotComplete))
        XCTAssertFalse(SnapshotBuilder.appLooksFrozen(.success))
        XCTAssertFalse(SnapshotBuilder.appLooksFrozen(.noValue))
        let message = SnapshotBuilder.appNotRespondingMessage(name: "Calculator")
        XCTAssertTrue(message.hasPrefix("Calculator is not responding"))
        XCTAssertTrue(message.contains("Do not retry"))
        XCTAssertTrue(SnapshotBuilder.appNotRespondingMessage(name: nil).hasPrefix("The app"))
    }

    func testLabeledNumberMatchesRegionalFormatting() {
        XCTAssertTrue(DoneCheck.containsLabeledNumber("5 text Description: Edit field 6.958", "Edit field 6958"))
        XCTAssertTrue(DoneCheck.containsLabeledNumber("Edit field 0,25", "edit field 0.25"))
        XCTAssertFalse(DoneCheck.containsLabeledNumber("Edit field 69.580", "Edit field 6958"))
        XCTAssertFalse(DoneCheck.containsLabeledNumber("Last Expression 6.958", "Edit field 6958"))
        XCTAssertFalse(DoneCheck.containsLabeledNumber("Edit field 16,41", "Edit field 1641"))
    }

    func testNumberMatchesRegionalFormatting() {
        XCTAssertTrue(DoneCheck.containsNumber("Edit field 1.641", "1641"))
        XCTAssertTrue(DoneCheck.containsNumber("Edit field 1,641", "1641"))
        XCTAssertTrue(DoneCheck.containsNumber("Total 1\u{202F}641", "1641"))
        XCTAssertTrue(DoneCheck.containsNumber("Edit field 0,25", "0.25"))
        XCTAssertTrue(DoneCheck.containsNumber("Edit field 1.234.567,5", "1234567.5"))
        XCTAssertTrue(DoneCheck.containsNumber("value −12", "-12"))
        XCTAssertFalse(DoneCheck.containsNumber("Edit field 16,41", "1641"))
        XCTAssertFalse(DoneCheck.containsNumber("Edit field 16410", "1641"))
        XCTAssertFalse(DoneCheck.containsNumber("Edit field 1.6411", "1641"))
        XCTAssertFalse(DoneCheck.containsNumber("Edit field 1641", "1.641"))
        XCTAssertFalse(DoneCheck.containsNumber("Edit field 1.641", "Total"))
        XCTAssertFalse(DoneCheck.containsNumber("Edit field 120", "12"))
        let calculator = "Window ID: 12573\n\t\t\t4 scroll area ID: StandardInputView;value:120, Secondary Actions: Copy\n\t\t\t\t5 text Description: Edit field 120\n\t\t\t12 button 9 ID: Nine"
        XCTAssertFalse(DoneCheck.containsNumber(calculator, "12"))
        XCTAssertFalse(DoneCheck.containsNumber(calculator, "12573"))
        XCTAssertFalse(DoneCheck.containsNumber(calculator, "4"))
        XCTAssertTrue(DoneCheck.containsNumber(calculator, "120"))
        XCTAssertTrue(DoneCheck.containsNumber(calculator, "9"))
        XCTAssertTrue(DoneCheck.containsNumber("Last Expression 144 ÷ 12", "12"))
        XCTAssertTrue(DoneCheck.containsNumber("Pages 1-9", "9"))
        XCTAssertTrue(DoneCheck.containsNumber("row 12 34", "12"))
        XCTAssertTrue(DoneCheck.containsNumber("row 12 34", "34"))
        XCTAssertTrue(DoneCheck.containsNumber("Edit field 1.641", "1,641"))
        XCTAssertFalse(DoneCheck.contains("Edit field 120", "Edit field 12"))
        XCTAssertTrue(DoneCheck.contains("Edit field 12\nnext", "edit field 12"))
        XCTAssertTrue(DoneCheck.contains("Saved v2.1 (beta)", "v2.1"))
        XCTAssertFalse(DoneCheck.contains("Page 112 of 300", "12 of 300"))
        XCTAssertTrue(DoneCheck.contains("a+b (x)", "+b (x"))
        XCTAssertTrue(DoneCheck.containsNumber("Date 19.11.2026", "19.11.2026"))
        XCTAssertTrue(DoneCheck.containsNumber("Host 192.168.1.1 up", "192.168.1.1"))
        XCTAssertTrue(DoneCheck.containsNumber("Edit field 0,25", "0,25"))
        XCTAssertFalse(DoneCheck.containsNumber("Host 192.168.1.10", "192.168.1.1"))
        XCTAssertTrue(DoneCheck.containsNumber("Sum,1.641", "1641"))
        XCTAssertFalse(DoneCheck.containsNumber("Month 5", "05"))
        XCTAssertFalse(DoneCheck.containsNumber("Agent 7", "007"))
        XCTAssertFalse(DoneCheck.containsNumber("Step 1 641", "1641"))
        XCTAssertTrue(DoneCheck.isPlainNumber("1641"))
        XCTAssertFalse(DoneCheck.isPlainNumber("Edit field 12"))
        XCTAssertFalse(DoneCheck.isPlainNumber("12 x 34"))
        // Plain text targets keep the old substring check.
        let words = DoneCheck.check([.text("Message sent")], evidence: .init(screenText: "Status: Message sent!", pageURL: { nil }))
        if case .verified = words {} else { XCTFail("text target") }
        let number = DoneCheck.check([.text("12")], evidence: .init(screenText: "Edit field 120", pageURL: { nil }))
        if case .verified = number { XCTFail("12 must not match 120") }
    }

    func testProcessAndWindowMetadataCannotVerifyANumericGoal() {
        let state = "App=com.example.Calculator (pid 3962)\nWindow ID: 4765\nCGWindowID: 2657\n4 text Total 36"
        XCTAssertFalse(DoneCheck.containsNumber(state, "3962"))
        XCTAssertFalse(DoneCheck.containsNumber(state, "4765"))
        XCTAssertFalse(DoneCheck.containsNumber(state, "2657"))
        XCTAssertTrue(DoneCheck.containsNumber(state, "36"))
    }

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

    func testFieldChecksLabelAndPreservesLiteralValue() {
        XCTAssertFalse(DoneCheck.fieldEquals("Notes = Result = 42", label: "Result", value: "42"))
        XCTAssertFalse(DoneCheck.fieldEquals("Username = Ada", label: "Name", value: "Ada"))
        XCTAssertFalse(DoneCheck.fieldEquals("Result = Ready (pending)", label: "Result", value: "Ready"))
        XCTAssertTrue(DoneCheck.fieldEquals("Result = Ready (pending)", label: "Result", value: "Ready (pending)"))
        XCTAssertTrue(DoneCheck.fieldEquals("Name [focused] = a = b", label: "Name", value: "a = b"))
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

extension DoneCheckTests {
    func testRefereeLongHistoryCannotCrowdOutCurrentWebsiteEvidence() {
        let screen = "Page: Checkout\n1 button Submit [disabled]\n# Payment pending"
        let steps = (1...40).map { (step: "Step \($0) " + String(repeating: "history ", count: 25), result: "ok") }
        let summary = RefereeSummary.build(
            goal: "Check payment", steps: steps, repeatedFailures: 2, screenChanged: true,
            dialogOpen: false, changes: String(repeating: "old diff ", count: 60), screen: screen,
            maxCharacters: 1_200
        )
        XCTAssertLessThanOrEqual(summary.count, 1_200)
        XCTAssertTrue(summary.contains("40. Step 40"))
        XCTAssertTrue(summary.contains("Repeated failures: 2"))
        XCTAssertTrue(summary.hasSuffix("Screen:\n" + screen))
    }
}

extension DoneCheckTests {
    func testBrowserDecisionViewKeepsConfirmationAndAccessibleControlState() {
        let filler = (1...28).map { "\($0) link Related item \($0)" }.joined(separator: "\n")
        let input = "Page: Checkout\nControls:\n\(filler)\n29 button Submit [disabled]\n30 textbox Name [focused]\nText:\n# Order confirmed"
        let screen = RefereeSummary.screen(from: input)
        XCTAssertTrue(screen.hasPrefix("Page: Checkout"))
        XCTAssertTrue(screen.contains("# Order confirmed"))
        XCTAssertTrue(screen.contains("Submit [disabled]"))
        XCTAssertTrue(screen.contains("Name [focused]"))
        XCTAssertLessThanOrEqual(screen.count, RefereeSummary.screenCharacterLimit)
    }

    func testDecisionBudgetMatchesHelperUnicodeCounting() {
        let screen = "Page: Rapport\n# Opgeslagen"
        let complex = String(repeating: "👩🏽‍💻e\u{301}", count: 100)
        let view = RefereeSummary.build(goal: complex, steps: [(complex, "ok")], repeatedFailures: 0,
                                        screenChanged: true, dialogOpen: false, changes: complex, screen: screen)
        XCTAssertLessThanOrEqual(view.unicodeScalars.count, 1_200)
        XCTAssertTrue(view.hasSuffix("Screen:\n" + screen))
    }

    func testBrowserLookAgainHintUsesTheSameTab() {
        let verdict = Referee.Verdict(label: "look_again", confidence: 1, milliseconds: 1)
        let browserHint = Referee.hint(for: verdict, browser: true) ?? ""
        XCTAssertTrue(browserHint.contains("browser wait_for"))
        XCTAssertTrue(browserHint.contains("same tab"))
        XCTAssertFalse(browserHint.contains("get_app_state"))
        XCTAssertTrue(Referee.hint(for: verdict)?.contains("get_app_state") == true)
    }
}
