import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for the smart steps: path parsing, label close match, the no-effect retry decision and
/// the dialog line. Nothing here touches an app, the accessibility tree or the file system.
final class SmartStepsTests: XCTestCase {
    private let home = "/Users/tester"

    // MARK: - Paths

    func testExpandHomeReplacesTildeOnly() {
        XCTAssertEqual(SmartSteps.expandHome("~/Desktop/a.txt", home: home), "/Users/tester/Desktop/a.txt")
        XCTAssertEqual(SmartSteps.expandHome("~", home: home), "/Users/tester")
        XCTAssertEqual(SmartSteps.expandHome("/tmp/a.txt", home: home), "/tmp/a.txt")
        XCTAssertEqual(SmartSteps.expandHome("~user/a.txt", home: home), "~user/a.txt")
    }

    func testSplitSavePathGivesFolderAndName() throws {
        let parts = try XCTUnwrap(SmartSteps.splitSavePath("/Users/tester/Desktop/notes.txt"))
        XCTAssertEqual(parts.folder, "/Users/tester/Desktop")
        XCTAssertEqual(parts.name, "notes.txt")
    }

    func testSplitSavePathAtRootAndRejectsBadPaths() throws {
        let root = try XCTUnwrap(SmartSteps.splitSavePath("/notes.txt"))
        XCTAssertEqual(root.folder, "/")
        XCTAssertEqual(root.name, "notes.txt")
        XCTAssertNil(SmartSteps.splitSavePath("notes.txt"), "relative paths are refused")
        XCTAssertNil(SmartSteps.splitSavePath("/Users/tester/Desktop/"), "a folder names no file")
        XCTAssertNil(SmartSteps.splitSavePath("/"))
    }

    func testOpenPlanPicksURLFileOrAppInThatOrder() {
        XCTAssertEqual(SmartSteps.openPlan(path: nil, url: "example.com", app: "Safari", home: home), .url("example.com"))
        XCTAssertEqual(
            SmartSteps.openPlan(path: "~/Desktop/a.pdf", url: nil, app: nil, home: home),
            .file(path: "/Users/tester/Desktop/a.pdf", app: nil)
        )
        XCTAssertEqual(
            SmartSteps.openPlan(path: "/tmp/a.pdf", url: nil, app: "Preview", home: home),
            .file(path: "/tmp/a.pdf", app: "Preview")
        )
        XCTAssertEqual(SmartSteps.openPlan(path: "https://x.test/a", url: nil, app: nil, home: home), .url("https://x.test/a"))
        XCTAssertEqual(SmartSteps.openPlan(path: nil, url: nil, app: "Notes", home: home), .app("Notes"))
        XCTAssertNil(SmartSteps.openPlan(path: "  ", url: "", app: nil, home: home))
    }

    func testAppBundleNameIgnoresCaseSpacesAndSuffix() {
        let installed = ["Google Chrome", "TextEdit", "Notes"]
        XCTAssertEqual(SmartSteps.appBundleName(query: "google chrome", candidates: installed), "Google Chrome")
        XCTAssertEqual(SmartSteps.appBundleName(query: "GoogleChrome.app", candidates: installed), "Google Chrome")
        XCTAssertEqual(SmartSteps.appBundleName(query: "textedit", candidates: installed), "TextEdit")
        XCTAssertNil(SmartSteps.appBundleName(query: "Pages", candidates: installed))
        XCTAssertNil(SmartSteps.appBundleName(query: "  ", candidates: installed))
    }

    // MARK: - Close match

    private func candidates(_ names: [String]) -> [SmartSteps.LabelCandidate] {
        names.enumerated().map { SmartSteps.LabelCandidate(index: $0.offset + 1, name: $0.element) }
    }

    func testCloseMatchIgnoresCaseSpacesPunctuationAndAccents() {
        let pool = candidates(["Café Latte", "Send"])
        XCTAssertEqual(
            SmartSteps.closeMatch(query: "cafe-latte", candidates: pool),
            .unique(SmartSteps.LabelCandidate(index: 1, name: "Café Latte"))
        )
        XCTAssertEqual(
            SmartSteps.closeMatch(query: "SEND!", candidates: pool),
            .unique(SmartSteps.LabelCandidate(index: 2, name: "Send"))
        )
    }

    func testCloseMatchAcceptsAUniquePrefix() {
        let pool = candidates(["Save As…", "Share", "Print"])
        XCTAssertEqual(
            SmartSteps.closeMatch(query: "Sav", candidates: pool),
            .unique(SmartSteps.LabelCandidate(index: 1, name: "Save As…"))
        )
    }

    func testCloseMatchAcceptsAUniqueContainsHitOfThreeOrMore() {
        let pool = candidates(["Export as PDF", "Print"])
        XCTAssertEqual(
            SmartSteps.closeMatch(query: "as pdf", candidates: pool),
            .unique(SmartSteps.LabelCandidate(index: 1, name: "Export as PDF"))
        )
    }

    func testCloseMatchListsSeveralHitsInsteadOfGuessing() {
        let pool = candidates(["Save", "Save As…", "Save Copy"])
        // "Save" is an exact match for one of them, but the same normalized text appears twice here.
        let twins = candidates(["Add", "Add"])
        XCTAssertEqual(SmartSteps.closeMatch(query: "add", candidates: twins), .ambiguous(["Add"]))

        // A prefix that starts three controls lists all three.
        if case .ambiguous(let names) = SmartSteps.closeMatch(query: "sav", candidates: pool) {
            XCTAssertEqual(names, ["Save", "Save As…", "Save Copy"])
        } else {
            XCTFail("expected an ambiguous result")
        }
        // Two letters are too short to match by prefix ("No" must not find "Notifications").
        XCTAssertEqual(SmartSteps.closeMatch(query: "sa", candidates: pool), .none)
        XCTAssertEqual(SmartSteps.closeMatch(query: "No", candidates: candidates(["Notifications", "Send"])), .none)
        // A longer label does not fall back to a much shorter name.
        XCTAssertEqual(SmartSteps.closeMatch(query: "Delete draft now", candidates: candidates(["Delete", "Send"])), .none)
    }

    func testCloseMatchRefusesTooShortOrUnrelatedLabels() {
        let pool = candidates(["Send", "Cancel"])
        XCTAssertEqual(SmartSteps.closeMatch(query: "x", candidates: pool), .none)
        XCTAssertEqual(SmartSteps.closeMatch(query: "Delete", candidates: pool), .none)
    }

    func testCloseMatchSkipsUnnamedControlsAndDuplicateIndexes() {
        let pool = [
            SmartSteps.LabelCandidate(index: 1, name: ""),
            SmartSteps.LabelCandidate(index: 2, name: "Done"),
            SmartSteps.LabelCandidate(index: 2, name: "Done"),
        ]
        XCTAssertEqual(
            SmartSteps.closeMatch(query: "done", candidates: pool),
            .unique(SmartSteps.LabelCandidate(index: 2, name: "Done"))
        )
    }

    // MARK: - No-effect retry

    func testRetryOnlyForASucceededActionInTheBackgroundWithNoChange() {
        let same = ["button \"Go\""]
        let changed = ["button \"Go\"", "text \"Done\""]

        XCTAssertTrue(SmartSteps.shouldRetryWithoutEffect(
            actionSucceeded: true, before: same, after: same,
            appIsFrontmost: false, borrowingAllowed: true, alreadyBorrowed: false
        ))
        XCTAssertFalse(SmartSteps.shouldRetryWithoutEffect(
            actionSucceeded: true, before: same, after: changed,
            appIsFrontmost: false, borrowingAllowed: true, alreadyBorrowed: false
        ), "the read-back changed, so the action had an effect")
        XCTAssertFalse(SmartSteps.shouldRetryWithoutEffect(
            actionSucceeded: false, before: same, after: same,
            appIsFrontmost: false, borrowingAllowed: true, alreadyBorrowed: false
        ), "a failed action is not retried here")
        XCTAssertFalse(SmartSteps.shouldRetryWithoutEffect(
            actionSucceeded: true, before: same, after: same,
            appIsFrontmost: true, borrowingAllowed: true, alreadyBorrowed: false
        ), "a front window is not a background one")
        XCTAssertFalse(SmartSteps.shouldRetryWithoutEffect(
            actionSucceeded: true, before: same, after: same,
            appIsFrontmost: false, borrowingAllowed: false, alreadyBorrowed: false
        ), "OPEN_COMPUTER_USE_FOCUS_BORROW=0 turns the retry off")
        XCTAssertFalse(SmartSteps.shouldRetryWithoutEffect(
            actionSucceeded: true, before: same, after: same,
            appIsFrontmost: false, borrowingAllowed: true, alreadyBorrowed: true
        ), "a borrow already open means the action ran in front")
        XCTAssertFalse(SmartSteps.shouldRetryWithoutEffect(
            actionSucceeded: true, before: nil, after: same,
            appIsFrontmost: false, borrowingAllowed: true, alreadyBorrowed: false
        ), "without a before read there is nothing to compare")
    }

    // MARK: - Dialog line

    func testDialogLineFormatsTitleFieldsAndButtons() {
        XCTAssertEqual(
            SmartSteps.formatDialogLine(title: "Save As", fields: ["Save As", "Tags"], buttons: ["Cancel", "Save"]),
            "A dialog opened: Save As. Its fields: Save As, Tags. buttons: Cancel, Save. To save under a name and folder in one step, use save_as {app, path}."
        )
        XCTAssertEqual(
            SmartSteps.formatDialogLine(title: "  ", fields: [], buttons: ["OK"]),
            "A dialog opened: untitled. Its fields: none. buttons: OK."
        )
    }

    func testFormatDialogLineCapsLongListsAndNames() {
        let many = (1...20).map { "f\($0)" }
        let line = SmartSteps.formatDialogLine(title: "Export", fields: many, buttons: [String(repeating: "x", count: 200)])
        XCTAssertTrue(line.contains("f12"))
        XCTAssertFalse(line.contains("f13"))
        XCTAssertTrue(line.hasSuffix("buttons: \(String(repeating: "x", count: 80))."))
    }

    func testDialogLineFindsTheSheetAndItsContentsByFrame() throws {
        let nodes = [
            SmartSteps.Node(index: 1, role: "AXWindow", subrole: nil, name: "Notes", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            SmartSteps.Node(index: 2, role: "AXButton", subrole: nil, name: "Outside", frame: CGRect(x: 10, y: 10, width: 40, height: 20)),
            SmartSteps.Node(index: 3, role: "AXSheet", subrole: nil, name: "Save As", frame: CGRect(x: 200, y: 100, width: 400, height: 200)),
            SmartSteps.Node(index: 4, role: "AXTextField", subrole: nil, name: "Save As:", frame: CGRect(x: 220, y: 140, width: 300, height: 24)),
            SmartSteps.Node(index: 5, role: "AXButton", subrole: nil, name: "Save", frame: CGRect(x: 500, y: 260, width: 80, height: 24)),
            SmartSteps.Node(index: 6, role: "AXButton", subrole: nil, name: "Cancel", frame: CGRect(x: 410, y: 260, width: 80, height: 24)),
        ]
        let line = try XCTUnwrap(SmartSteps.dialogLine(in: nodes))
        XCTAssertEqual(line, "A dialog opened: Save As. Its fields: Save As:. buttons: Save, Cancel. To save under a name and folder in one step, use save_as {app, path}.")
    }

    func testDialogLineIsNilWithoutASheetAlertOrDialog() {
        let nodes = [
            SmartSteps.Node(index: 1, role: "AXWindow", subrole: nil, name: "Notes", frame: nil),
            SmartSteps.Node(index: 2, role: "AXButton", subrole: nil, name: "Save", frame: nil),
        ]
        XCTAssertNil(SmartSteps.dialogLine(in: nodes))
    }

    func testDialogRecognisedBySubroleAndAlertRole() {
        let alert = [SmartSteps.Node(index: 1, role: "AXAlert", subrole: nil, name: "Replace?", frame: nil)]
        XCTAssertEqual(SmartSteps.dialogLine(in: alert), "A dialog opened: Replace?. Its fields: none. buttons: none.")

        let dialogWindow = [SmartSteps.Node(index: 1, role: "AXWindow", subrole: "AXDialog", name: "Preferences", frame: nil)]
        XCTAssertEqual(SmartSteps.dialogLine(in: dialogWindow), "A dialog opened: Preferences. Its fields: none. buttons: none.")
    }

    func testRoleKeyDropsTheAXPrefixAndCase() {
        XCTAssertEqual(SmartSteps.roleKey("AXPopUpButton"), "popupbutton")
        XCTAssertEqual(SmartSteps.roleKey("Text Field"), "textfield")
        XCTAssertEqual(SmartSteps.roleKey(nil), "")
    }

    // MARK: - Log

    func testSmartLogPutsNotesBeforeAndDialogAfterTheReply() {
        let log = SmartLog()
        log.note("Used close match.")
        log.tail("A dialog opened: Save. Its fields: none. buttons: none.")
        let out = log.apply(to: .text("ok"))
        XCTAssertEqual(out.content.compactMap { $0.dictionary["text"] as? String }, [
            "Used close match.", "ok", "A dialog opened: Save. Its fields: none. buttons: none.",
        ])
        XCTAssertFalse(out.isError)
    }

    func testSmartLogLeavesAResultAloneWhenItHasNoNotes() {
        let result = SmartLog().apply(to: .text("pressed File > Save", isError: true))
        XCTAssertEqual(result.textContent, "pressed File > Save")
        XCTAssertTrue(result.isError)
    }

    func testCaptionPicksTheSavePanelNameFieldOverButtons() {
        typealias N = SmartSteps.Node
        let nodes = [
            N(index: 0, role: "AXWindow", subrole: nil, name: "Untitled", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            N(index: 3, role: "AXSheet", subrole: nil, name: "save", frame: CGRect(x: 100, y: 0, width: 500, height: 300)),
            N(index: 4, role: "AXTextField", subrole: nil, name: nil, frame: CGRect(x: 200, y: 40, width: 200, height: 22)),
            N(index: 5, role: "AXTextField", subrole: nil, name: "Tags", frame: CGRect(x: 200, y: 70, width: 200, height: 22)),
            N(index: 9, role: "AXButton", subrole: nil, name: "Save", frame: CGRect(x: 500, y: 260, width: 80, height: 22)),
        ]
        XCTAssertEqual(SmartSteps.captionField(for: "Save As:", in: nodes), 4)
        XCTAssertEqual(SmartSteps.captionField(for: "Tags", in: nodes), 5)
        XCTAssertNil(SmartSteps.captionField(for: "Save", in: nodes.filter { $0.index != 3 }))
    }

    func testEscapeFallbackFindsTheDialogsCancelButton() {
        typealias N = SmartSteps.Node
        let nodes = [
            N(index: 0, role: "AXSheet", subrole: nil, name: "save", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            N(index: 7, role: "AXButton", subrole: nil, name: "Cancel", frame: CGRect(x: 200, y: 260, width: 80, height: 22)),
            N(index: 8, role: "AXButton", subrole: nil, name: "Save", frame: CGRect(x: 300, y: 260, width: 80, height: 22)),
        ]
        XCTAssertEqual(SmartSteps.dialogCancelButton(in: nodes), 7)
        XCTAssertNil(SmartSteps.dialogCancelButton(in: Array(nodes.dropFirst())))
        XCTAssertTrue(SmartSteps.isEscapeKey("Escape"))
        XCTAssertTrue(SmartSteps.isEscapeKey(" esc "))
        XCTAssertFalse(SmartSteps.isEscapeKey("cmd+w"))
    }

    func testSymbolKeysParseWithShiftWhereNeeded() throws {
        // Layout unknown: US positions.
        let us: (Character) -> KeyboardLayoutLookup.Key? = { _ in nil }
        let star = try KeyPressParser.parse("*", layout: us)
        XCTAssertTrue(star.modifiers.contains { $0.flag == .maskShift })
        let plus = try KeyPressParser.parse("+", layout: us)
        XCTAssertTrue(plus.modifiers.contains { $0.flag == .maskShift })
        let cmdPlus = try KeyPressParser.parse("cmd++", layout: us)
        XCTAssertEqual(cmdPlus.modifiers.count, 2)
        XCTAssertTrue(try KeyPressParser.parse("/", layout: us).modifiers.isEmpty)
        XCTAssertTrue(try KeyPressParser.parse("=", layout: us).modifiers.isEmpty)
        XCTAssertEqual(try KeyPressParser.parse("cmd+s", layout: us).modifiers.count, 1)
        XCTAssertThrowsError(try KeyPressParser.parse("cmd+nosuchkey", layout: us))
        // Another layout: the symbol's own key wins, letters and named keys are untouched.
        let other: (Character) -> KeyboardLayoutLookup.Key? = { $0 == "*" ? (CGKeyCode(30), false) : nil }
        let localStar = try KeyPressParser.parse("*", layout: other)
        XCTAssertEqual(localStar.keyCode, CGKeyCode(30))
        XCTAssertTrue(localStar.modifiers.isEmpty)
        XCTAssertEqual(try KeyPressParser.parse("cmd+s", layout: other).keyCode, try KeyPressParser.parse("cmd+s", layout: us).keyCode)
        // The real layout answers for the common symbols on any Latin keyboard.
        XCTAssertNoThrow(try KeyPressParser.parse("*"))
        XCTAssertNoThrow(try KeyPressParser.parse("cmd+-"))
    }

    func testSaveDialogLineSuggestsSaveAs() {
        XCTAssertTrue(SmartSteps.formatDialogLine(title: "save", fields: ["Save As:"], buttons: ["Cancel", "Save"]).contains("save_as"))
        XCTAssertFalse(SmartSteps.formatDialogLine(title: "Export", fields: [], buttons: ["OK"]).contains("save_as"))
    }

    func testLabelSpellingsCoverCalculatorKeys() {
        XCTAssertEqual(LabelSpellings.alternatives("1"), ["one"])
        XCTAssertEqual(LabelSpellings.alternatives("one"), ["1"])
        XCTAssertTrue(LabelSpellings.alternatives("+").contains("add"))
        XCTAssertTrue(LabelSpellings.alternatives("*").contains("multiply"))
        XCTAssertTrue(LabelSpellings.alternatives("(").contains("openparenthesis"))
        XCTAssertTrue(LabelSpellings.alternatives("send").isEmpty)
    }

    func testBatchRoutesBrowserActionNamesToTheBrowser() throws {
        try XCTSkipUnless(ToolDefinitions.all.contains { $0.name == "browser" }, "browser tool not listed in this environment")
        let steps = try BatchTool.parseSteps([
            ["tool": "select", "web": true, "label": "Plan", "option": "Team"],
            ["tool": "click", "web": true, "label": "Submit"],
            ["tool": "click", "label": "Send"],
        ], defaultApp: "Mail")
        XCTAssertEqual(steps.map(\.tool), ["browser", "browser", "click"])
        XCTAssertEqual(steps[0].arguments["action"] as? String, "select")
        XCTAssertNil(steps[0].arguments["app"])
        XCTAssertEqual(steps[2].arguments["app"] as? String, "Mail")
    }

    func testMenuAndItemBecomeOnePath() {
        let args = ArgumentNormalizer.normalize(tool: "press_menu", arguments: ["app": "TextEdit", "menu": "File", "item": "Save As…"], lastApp: nil)
        XCTAssertEqual(args["path"] as? [String], ["File", "Save As…"])
        XCTAssertNoThrow(try menuPathTitles("File"))
    }
}
