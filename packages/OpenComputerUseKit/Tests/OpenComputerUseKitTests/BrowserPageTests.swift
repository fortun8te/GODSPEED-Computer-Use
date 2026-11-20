import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for the browser actions: key combinations, option matching, reply parsing, read
/// rendering from synthetic accessibility JSON, and label matching. The peek fixture uses a shell helper
/// in place of Chrome and OBU.
final class BrowserPageTests: XCTestCase {
    func testFindHintsSkipUnrelatedDuplicatesAndKeepIconOnlyControls() {
        var parse = BrowserAXParse()
        parse.controls = (1...24).map { BrowserNode(index: $0, role: "button", name: "Edit", value: "", backendNodeID: $0) }
        parse.controls.append(.init(index: 25, role: "button", name: "Save", value: "", backendNodeID: 25))
        parse.controls.append(.init(index: 26, role: "button", name: "", value: "", backendNodeID: 26))
        XCTAssertEqual(BrowserPage.hintCandidates(in: parse, find: "Save"), [25])
        XCTAssertEqual(BrowserPage.hintCandidates(in: parse, find: "trash").first, 25)
    }

    func testHintProbesResolveTogetherAndShareOneRuntimeRead() {
        var waves: [[String]] = []
        let hints = BrowserPage.readHints(Array(1...24)) { commands in
            waves.append(commands.map(\.0))
            switch commands.first?.0 {
            case "DOM.resolveNode":
                return commands.map { _, params in
                    ["object": ["objectId": "handle-\(params["backendNodeId"] as? Int ?? 0)"]]
                }
            case "Runtime.callFunctionOn":
                XCTAssertEqual((commands[0].1["arguments"] as? [[String: String]])?.count, 24)
                return [["result": ["value": (1...24).map { "hint-\($0)" }]]]
            default:
                return []
            }
        }
        XCTAssertEqual(waves, [Array(repeating: "DOM.resolveNode", count: 24), ["Runtime.callFunctionOn"], ["Runtime.releaseObjectGroup"]])
        XCTAssertEqual(hints.count, 24)
        XCTAssertEqual(hints[24], "hint-24")
    }

    func testRememberedBrowserControlsRequireTheOriginalHelperAndLoaders() throws {
        let memory = BrowserPageMemory()
        let first = BrowserBridge(sessionID: "test-first")
        let second = BrowserBridge(sessionID: "test-second")
        let observation = try XCTUnwrap(BrowserDocumentIdentity(tree: [
            "frame": ["id": "root", "loaderId": "one"],
            "childFrames": [["frame": ["id": "child", "loaderId": "one"]]],
        ]))
        let replacedFrame = try XCTUnwrap(BrowserDocumentIdentity(tree: [
            "frame": ["id": "root", "loaderId": "one"],
            "childFrames": [["frame": ["id": "child", "loaderId": "two"]]],
        ]))
        memory.store([], bridge: first, tab: 9, document: observation, generation: first.referenceGeneration)
        XCTAssertNotNil(memory.observation(bridge: first, tab: 9, document: observation))
        XCTAssertNil(memory.observation(bridge: second, tab: 9, document: observation))
        XCTAssertNil(memory.observation(bridge: first, tab: 9, document: replacedFrame))
        memory.forgetTab(bridge: first, tab: 9)
        XCTAssertNil(memory.observation(bridge: first, tab: 9, document: observation))
    }

    func testPointerDragReleasesOnceWhenMovementFails() throws {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 60, y: 50)
        var sent: [(String, CGPoint, Int)] = []
        let deliver = {
            try BrowserCallBudget.withDeadline(BrowserCallBudget.deadline()) {
                try BrowserPage.deliverDrag(from: start, to: end) { kind, point, buttons, _ in
                    sent.append((kind, point, buttons))
                    if sent.count == 4 { throw ComputerUseError.stateUnavailable("interrupted fixture") }
                }
            }
        }
        XCTAssertThrowsError(try deliver())
        XCTAssertEqual(sent.map { $0.0 }, ["mouseMoved", "mousePressed", "mouseMoved", "mouseMoved", "mouseReleased"])
        XCTAssertEqual(sent.map { $0.2 }, [0, 1, 1, 1, 0])
        XCTAssertEqual(sent.last?.1, CGPoint(x: 30, y: 32))
    }

    func testMCPListResolvesBrowserAvailabilityForEachRequest() throws {
        let server = StdioMCPServer()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#

        func listsBrowser(environment: [String: String]) throws -> Bool {
            let reply = try XCTUnwrap(server.handle(line: request, toolListingEnvironment: environment))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let result = try XCTUnwrap(payload["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.contains { $0["name"] as? String == "browser" }
        }

        let enabled = [
            "OPEN_COMPUTER_USE_BROWSER": "1",
            "OPEN_COMPUTER_USE_OBU_BIN": "/usr/bin/true",
        ]
        let disabled = enabled.merging(["OPEN_COMPUTER_USE_BROWSER": "0"]) { _, value in value }
        let unavailable = enabled.merging(["OPEN_COMPUTER_USE_OBU_BIN": "/dev/null/obu"]) { _, value in value }
        XCTAssertFalse(try listsBrowser(environment: disabled))
        XCTAssertTrue(try listsBrowser(environment: enabled))
        XCTAssertFalse(try listsBrowser(environment: unavailable))
        XCTAssertTrue(try listsBrowser(environment: enabled))
    }

    // MARK: - Helpers

    /// A synthetic accessibility node in the shape `Accessibility.getFullAXTree` returns.
    private func ax(
        _ role: String,
        _ name: String = "",
        backend: Int? = nil,
        value: String? = nil,
        ignored: Bool = false,
        frame: String = "main"
    ) -> [String: Any] {
        var node: [String: Any] = [
            "role": ["type": "role", "value": role],
            "name": ["type": "computedString", "value": name],
            "ignored": ignored,
            "frameId": frame,
        ]
        if let value { node["value"] = ["type": "string", "value": value] }
        if let backend { node["backendDOMNodeId"] = NSNumber(value: backend) }
        return node
    }

    private func node(_ index: Int, _ role: String, _ name: String, backend: Int = 1) -> BrowserNode {
        BrowserNode(index: index, role: role, name: name, value: "", backendNodeID: backend)
    }

    private func page() -> [[String: Any]] {
        [
            ax("RootWebArea", "Demo", frame: "main"),
            ax("heading", "Welcome"),
            ax("link", "Home", backend: 11),
            ax("textbox", "Email", backend: 12, value: "sam@x.com"),
            ax("button", "Hidden", backend: 13, ignored: true),
            ax("button", "", backend: 14),
            ax("StaticText", "Hello there"),
            ax("button", "Pay", backend: 15, frame: "child-frame"),
        ]
    }

    // MARK: - Read rendering from synthetic AX JSON

    func testParseNumbersControlsAndSkipsIgnoredAndUnnamed() {
        let parse = BrowserPage.parseAX(page())
        // The icon-only button is kept (labelled later by a hint); the ignored one is not.
        XCTAssertEqual(parse.controls.map(\.name), ["Home", "Email", "", "Pay"])
        XCTAssertEqual(parse.controls.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(parse.controls.map(\.backendNodeID), [11, 12, 14, 15])
        XCTAssertEqual(parse.controls[1].value, "sam@x.com")
        XCTAssertEqual(parse.texts, ["# Welcome", "  Hello there"])
    }

    func testParseMarksControlsInsideAnotherFrame() {
        let parse = BrowserPage.parseAX(page())
        XCTAssertEqual(parse.controls.map(\.inFrame), [false, false, false, true])
        XCTAssertEqual(parse.framedControls, 1)
    }

    func testCompactBrowserSnapshotCarriesObservedControlStates() {
        func property(_ name: String, _ value: Any) -> [String: Any] {
            ["name": name, "value": ["value": value]]
        }
        var checkbox = ax("checkbox", "Include files", backend: 12)
        checkbox["properties"] = [property("focused", true), property("checked", "mixed"), property("disabled", false)]
        var button = ax("button", "More", backend: 13)
        button["properties"] = [property("expanded", false), property("disabled", true)]
        let lines = BrowserPage.parseAX([checkbox, button], textBudget: 0).controls.map(\.line)
        XCTAssertEqual(lines, ["1 checkbox Include files [focused, mixed]", "2 button More [collapsed, disabled]"])
        var field = ax("textbox", "Name", backend: 14, value: "Ada")
        field["properties"] = [property("focused", true)]
        let line = BrowserPage.parseAX([field], textBudget: 0).controls.first?.line ?? ""
        XCTAssertTrue(DoneCheck.fieldEquals(line, label: "Name", value: "Ada"))
    }

    func testClippedBrowserFieldCannotVerifyItsPrefix() throws {
        let prefix = String(repeating: "a", count: 80)
        func line(_ value: String) throws -> String {
            try XCTUnwrap(BrowserPage.parseAX([
                ax("textbox", "Name", backend: 14, value: value),
            ]).controls.first).line
        }
        XCTAssertTrue(DoneCheck.fieldEquals(try line(prefix), label: "Name", value: prefix))
        XCTAssertFalse(DoneCheck.fieldEquals(try line(prefix + "b"), label: "Name", value: prefix))
    }

    func testRenderPutsControlsBeforeTextAndAddsAddress() {
        let text = BrowserPage.renderRead(
            BrowserPage.parseAX(page()), href: "https://demo.test/", title: "Demo", readyState: "complete"
        )
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Page: Demo — https://demo.test/")
        XCTAssertEqual(lines[1], "Controls:")
        XCTAssertEqual(lines[2], "1 link Home")
        XCTAssertEqual(lines[3], "2 textbox Email = sam@x.com")
        XCTAssertEqual(lines[4], "3 button (no label)")
        XCTAssertEqual(lines[5], "4 button Pay")
        XCTAssertTrue(lines.contains { $0.hasPrefix("(1 of these sit inside an iframe") })
        let textIndex = lines.firstIndex(of: "Text:")
        XCTAssertNotNil(textIndex)
        XCTAssertGreaterThan(textIndex ?? 0, 4, "text must come after every control")
        XCTAssertEqual(lines.last, "  Hello there")
    }

    func testRenderSaysWhenPageIsStillLoading() {
        let text = BrowserPage.renderRead(BrowserPage.parseAX([ax("RootWebArea", "")]), href: "https://a.test", title: "", readyState: "loading")
        XCTAssertTrue(text.hasPrefix("Page: https://a.test (still loading)"))
        XCTAssertTrue(text.contains("no readable content yet"))
    }

    func testRenderCapsControlsAndTextAndSaysHowManyWereLeftOut() {
        var raw = [ax("RootWebArea", "Big")]
        for number in 0..<50 { raw.append(ax("button", "Button number \(number) with a long name", backend: 100 + number)) }
        for number in 0..<40 { raw.append(ax("StaticText", "Paragraph line \(number) that is fairly long so text fills up")) }
        let parse = BrowserPage.parseAX(raw, controlBudget: 300, textBudget: 200)
        XCTAssertLessThan(parse.controls.count, 50)
        XCTAssertGreaterThan(parse.droppedControls, 0)
        XCTAssertLessThanOrEqual(parse.texts.reduce(0) { $0 + $1.count }, 200 + 170)
        let text = BrowserPage.renderRead(parse, href: "https://big.test", title: "Big", readyState: "complete")
        XCTAssertTrue(text.contains("more controls not listed"))
    }

    func testStaticTextThatRepeatsAControlNameIsNotListedTwice() {
        let raw = [ax("RootWebArea", ""), ax("link", "Sign in", backend: 5), ax("StaticText", "Sign in")]
        let parse = BrowserPage.parseAX(raw)
        XCTAssertEqual(parse.texts, [])
    }

    func testIconOnlyClickablesAreKeptAndOtherEmptyControlsAreNot() {
        let raw = [ax("button", "", backend: 1), ax("textbox", "", backend: 2, value: "typed"), ax("slider", "", backend: 3)]
        let parse = BrowserPage.parseAX(raw)
        XCTAssertEqual(parse.controls.map(\.role), ["button", "textbox"])
        XCTAssertEqual(parse.unnamedControls, 1)
        XCTAssertEqual(parse.controls.first?.renderedLine(numbered: true), "1 button (no label)")
        var hinted = parse.controls[0]
        hinted.hint = "icon:trash; in:Invoice 12"
        XCTAssertEqual(hinted.renderedLine(numbered: true), "1 button (icon:trash; in:Invoice 12)")
        XCTAssertTrue(BrowserPage.hint(hinted.hint, matches: BrowserPage.normalize("trash")))
        XCTAssertTrue(BrowserPage.hint(hinted.hint, matches: BrowserPage.normalize("icon:trash")))
        XCTAssertFalse(BrowserPage.hint(hinted.hint, matches: BrowserPage.normalize("invoice")))
    }

    // MARK: - Label matching

    func testNamedCandidatesKeepInteractiveUnignoredNodesWithANode() {
        let raw = [
            ax("link", "Home", backend: 3),
            ax("heading", "Home", backend: 4),
            ax("button", "Home", backend: 5, ignored: true),
            ax("button", "Home"),
        ]
        let candidates = BrowserPage.namedCandidates(raw)
        XCTAssertEqual(candidates.map(\.role), ["link"])
    }

    func testPickNamedPrefersClickableOverFieldWithSameName() {
        let nodes = [node(0, "textbox", "Search"), node(0, "button", "search", backend: 9)]
        let hit = BrowserPage.pickNamed(nodes, wanted: BrowserPage.normalize("Search"))
        XCTAssertEqual(hit?.role, "button")
        XCTAssertEqual(hit?.backendNodeID, 9)
    }

    func testPickFuzzyUsesWholeWordWhenSeveralContainTheLabel() throws {
        let nodes = [node(1, "button", "Send feedback"), node(2, "button", "Resend email")]
        let hit = try BrowserPage.pickFuzzy(nodes, label: "Send")
        XCTAssertEqual(hit?.name, "Send feedback")
    }

    func testPickFuzzyRefusesToGuessBetweenSeveralWholeWordMatches() {
        let nodes = [node(1, "button", "Save draft"), node(2, "button", "Save and close")]
        XCTAssertThrowsError(try BrowserPage.pickFuzzy(nodes, label: "Save")) { error in
            XCTAssertTrue(((error as? LocalizedError)?.errorDescription ?? "").contains("matches several"))
        }
    }

    func testPickFuzzyNeedsAtLeastThreeCharactersForPartialMatches() throws {
        let nodes = [node(1, "button", "Checkout now")]
        XCTAssertNil(try BrowserPage.pickFuzzy(nodes, label: "Ch"))
        XCTAssertEqual(try BrowserPage.pickFuzzy(nodes, label: "Checkout")?.name, "Checkout now")
    }

    func testContainsWordsMatchesWholeWordsInOrder() {
        XCTAssertTrue(BrowserPage.containsWords(["send", "feedback"], ["send"]))
        XCTAssertFalse(BrowserPage.containsWords(["resend"], ["send"]))
        XCTAssertTrue(BrowserPage.containsWords(["a", "b", "c"], ["b", "c"]))
        XCTAssertFalse(BrowserPage.containsWords(["a", "c", "b"], ["b", "c"]))
        XCTAssertFalse(BrowserPage.containsWords(["a"], []))
    }

    // MARK: - Keys and modifiers

    func testNamedKeysMapToCDPCodes() throws {
        let enter = try XCTUnwrap(BrowserKeyCombo.parse("Enter"))
        XCTAssertEqual(enter.key, "Enter")
        XCTAssertEqual(enter.code, "Enter")
        XCTAssertEqual(enter.virtualKey, 13)
        XCTAssertEqual(enter.text, "\r")
        XCTAssertEqual(enter.modifiers, 0)

        let arrow = try XCTUnwrap(BrowserKeyCombo.parse("ArrowDown"))
        XCTAssertEqual(arrow.virtualKey, 40)
        XCTAssertNil(arrow.text)
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("down")).key, "ArrowDown")
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("esc")).key, "Escape")
    }

    func testCmdAIsSelectAllWithTheMetaBitAndMacCommand() throws {
        let combo = try XCTUnwrap(BrowserKeyCombo.parse("Cmd+A"))
        XCTAssertEqual(combo.key, "a")
        XCTAssertEqual(combo.code, "KeyA")
        XCTAssertEqual(combo.virtualKey, 65)
        XCTAssertEqual(combo.modifiers, BrowserKeyCombo.meta)
        XCTAssertEqual(combo.commands, ["selectAll"])
        XCTAssertNil(combo.text, "a shortcut must not type the letter")
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("super+a")).modifiers, BrowserKeyCombo.meta)
    }

    func testCtrlShiftZCombinesBitsAndTypesNothing() throws {
        let combo = try XCTUnwrap(BrowserKeyCombo.parse("ctrl+shift+z"))
        XCTAssertEqual(combo.modifiers, BrowserKeyCombo.control | BrowserKeyCombo.shift)
        XCTAssertEqual(combo.key, "Z")
        XCTAssertEqual(combo.code, "KeyZ")
        XCTAssertNil(combo.text)
        XCTAssertEqual(combo.commands, [])
    }

    func testCmdShiftZIsRedo() throws {
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("cmd+shift+z")).commands, ["redo"])
    }

    func testShiftLetterTypesUppercase() throws {
        let combo = try XCTUnwrap(BrowserKeyCombo.parse("Shift+a"))
        XCTAssertEqual(combo.key, "A")
        XCTAssertEqual(combo.text, "A")
        XCTAssertEqual(combo.modifiers, BrowserKeyCombo.shift)
    }

    func testCmdArrowMovesToLineEdgeAndShiftSelects() throws {
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("cmd+arrowleft")).commands, ["moveToBeginningOfLine"])
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("cmd+shift+arrowleft")).commands, ["moveToBeginningOfLineAndModifySelection"])
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("cmd+arrowdown")).commands, ["moveToEndOfDocument"])
    }

    func testDigitsAndAltOption() throws {
        let five = try XCTUnwrap(BrowserKeyCombo.parse("Cmd+5"))
        XCTAssertEqual(five.code, "Digit5")
        XCTAssertEqual(five.virtualKey, 53)
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.parse("option+a")).modifiers, BrowserKeyCombo.alt)
    }

    func testUnknownKeysAndModifiersAreRefused() {
        XCTAssertNil(BrowserKeyCombo.parse("F13"))
        XCTAssertNil(BrowserKeyCombo.parse("Hyper+a"))
        XCTAssertNil(BrowserKeyCombo.parse(""))
        XCTAssertNil(BrowserKeyCombo.parse("Cmd+"))
        XCTAssertNil(BrowserKeyCombo.parse("Ctrl+/"))
        XCTAssertNil(BrowserKeyCombo.parse("Cmd+é"))
    }

    // MARK: - Options (select)

    func testOptionExactTextWinsOverContains() {
        let options: [(text: String, value: String)] = [("Canada", "ca"), ("Canada Day", "day")]
        XCTAssertEqual(BrowserRules.matchOption("canada", options: options), .found(0))
    }

    func testOptionMatchesByValueWhenTextDiffers() {
        let options: [(text: String, value: String)] = [("United States", "us"), ("Uruguay", "uy")]
        XCTAssertEqual(BrowserRules.matchOption("uy", options: options), .found(1))
    }

    func testOptionContainsWhenUnique() {
        let options: [(text: String, value: String)] = [("Select a country", ""), ("Germany", "de")]
        XCTAssertEqual(BrowserRules.matchOption("germ", options: options), .found(1))
    }

    func testOptionAmbiguousIsNeverAGuess() {
        let options: [(text: String, value: String)] = [("New York", ""), ("New Jersey", "")]
        XCTAssertEqual(BrowserRules.matchOption("new", options: options), .ambiguous([0, 1]))
    }

    func testOptionWhitespaceIsCollapsedAndEmptyOrMissingIsNone() {
        let options: [(text: String, value: String)] = [("New   York", "ny")]
        XCTAssertEqual(BrowserRules.matchOption("  new york ", options: options), .found(0))
        XCTAssertEqual(BrowserRules.matchOption("", options: options), .none)
        XCTAssertEqual(BrowserRules.matchOption("Mars", options: options), .none)
    }

    func testOptionRowsReadTheListingJSON() {
        let rows = BrowserRules.optionRows(#"[["Canada","ca"],["Germany",""]]"#)
        XCTAssertEqual(rows?.map(\.text), ["Canada", "Germany"])
        XCTAssertEqual(rows?.map(\.value), ["ca", ""])
        XCTAssertNil(BrowserRules.optionRows("not json"))
    }

    // MARK: - Typing read-back

    func testFieldReadBackReplaceNeedsTheWholeValue() {
        XCTAssertTrue(BrowserRules.fieldMatches(actual: "a  b", typed: "a b", replaced: true))
        XCTAssertFalse(BrowserRules.fieldMatches(actual: "old text", typed: "new", replaced: true))
        XCTAssertTrue(BrowserRules.fieldMatches(actual: "", typed: "", replaced: true), "clearing an empty field is fine")
    }

    func testFieldReadBackAppendNeedsTheTextInside() {
        XCTAssertTrue(BrowserRules.fieldMatches(actual: "hello world", typed: "world", replaced: false))
        XCTAssertFalse(BrowserRules.fieldMatches(actual: "", typed: "x", replaced: false))
    }

    // MARK: - Scroll and history

    func testScrollDirectionAcceptsWordsAndRefusesTheRest() {
        XCTAssertEqual(BrowserRules.scrollDirection("Page Down"), "down")
        XCTAssertEqual(BrowserRules.scrollDirection("up"), "up")
        XCTAssertEqual(BrowserRules.scrollDirection("start"), "top")
        XCTAssertEqual(BrowserRules.scrollDirection("end"), "bottom")
        XCTAssertNil(BrowserRules.scrollDirection("sideways"))
    }

    func testScrollSummaryUsesWordsNotNumbers() {
        XCTAssertEqual(BrowserRules.scrollSummary(direction: "down", top: 0, bottom: 0), "nothing to scroll: the page fits on screen")
        XCTAssertEqual(BrowserRules.scrollSummary(direction: "up", top: 0, bottom: 1000), "scrolled up; at the top")
        XCTAssertEqual(BrowserRules.scrollSummary(direction: "down", top: 1000, bottom: 1000), "scrolled down; at the bottom")
        XCTAssertEqual(BrowserRules.scrollSummary(direction: "down", top: 500, bottom: 1000), "scrolled down; 50% of the way down the page")
    }

    func testHistoryTargetStepsBackAndForwardWithinTheList() {
        XCTAssertEqual(BrowserRules.historyTarget(current: 2, count: 3, forward: false), 1)
        XCTAssertEqual(BrowserRules.historyTarget(current: 0, count: 3, forward: true), 1)
        XCTAssertNil(BrowserRules.historyTarget(current: 0, count: 3, forward: false))
        XCTAssertNil(BrowserRules.historyTarget(current: 2, count: 3, forward: true))
        XCTAssertNil(BrowserRules.historyTarget(current: 0, count: 0, forward: true))
    }

    // MARK: - Literals and addresses

    func testJSLiteralEscapesQuotesAndNewlines() {
        XCTAssertEqual(BrowserRules.jsLiteral("a\"b\n"), "\"a\\\"b\\n\"")
        XCTAssertEqual(BrowserRules.jsLiteral(""), "\"\"")
    }

    func testSameAddressIgnoresCaseAndTrailingSlash() {
        XCTAssertTrue(BrowserRules.sameAddress("https://x.com/", "https://X.com"))
        XCTAssertTrue(BrowserRules.sameAddress("https://x.com/a", "https://x.com"))
        XCTAssertFalse(BrowserRules.sameAddress("https://y.com", "https://x.com"))
        XCTAssertFalse(BrowserRules.sameAddress("https://x.com.example.test", "https://x.com"))
        XCTAssertFalse(BrowserRules.sameAddress("https://x.com/cartoon", "https://x.com/cart"))
        XCTAssertFalse(BrowserRules.sameAddress("https://x.com/Cart", "https://x.com/cart"))
        XCTAssertFalse(BrowserRules.sameAddress("https://x.com?q=Wrong", "https://x.com?q=Right"))
    }

    func testURLNormalisationKeepsPathsAndTrimsSpaces() {
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("EXAMPLE.com/Path"), "https://EXAMPLE.com/Path")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("localhost:3000"), "https://localhost:3000")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("  https://x.test/a?q=1 "), "https://x.test/a?q=1")
    }

    func testFlagAndTabIDParsing() {
        XCTAssertTrue(ComputerUseToolDispatcher.browserFlag(true))
        XCTAssertTrue(ComputerUseToolDispatcher.browserFlag("yes"))
        XCTAssertFalse(ComputerUseToolDispatcher.browserFlag("no"))
        XCTAssertFalse(ComputerUseToolDispatcher.browserFlag(nil))
        XCTAssertEqual(ComputerUseToolDispatcher.browserTabID("12"), 12)
        XCTAssertEqual(ComputerUseToolDispatcher.browserTabID(NSNumber(value: 4)), 4)
        XCTAssertNil(ComputerUseToolDispatcher.browserTabID(NSNumber(value: true)))
    }

    // MARK: - Replies from OBU and Chrome

    func testTabIDsComeFromListingEntriesWithAnAddressOrTitle() {
        let listing = #"{"result":[{"id":3,"url":"https://a.com","title":"A","active":true},{"id":9,"url":"chrome://x"},{"id":4}]}"#
        XCTAssertEqual(BrowserReply.tabIDs(in: listing), [3, 9])
        XCTAssertEqual(BrowserReply.tabIDs(in: "not json"), [])
    }

    func testReadyTabRequiresExactTabAddressAndCompletion() {
        let listing = #"{"result":[{"id":9,"url":"https://example.test/form","status":"complete"},{"id":10,"url":"https://example.test/form","status":"loading"}]}"#
        XCTAssertTrue(BrowserReply.completedTab(in: listing, id: 9, expectedURL: "https://example.test/form"))
        XCTAssertFalse(BrowserReply.completedTab(in: listing, id: 10, expectedURL: "https://example.test/form"))
        XCTAssertFalse(BrowserReply.completedTab(in: listing, id: 9, expectedURL: "https://example.test/other"))
    }

    func testOpenedTabIDReadsTheTabObject() {
        let reply = #"{"result":{"tab":{"id":12,"url":"about:blank"},"navigate":{"result":{}}}}"#
        XCTAssertEqual(BrowserReply.openedTabID(in: reply), 12)
        XCTAssertNil(BrowserReply.openedTabID(in: #"{"result":{"navigate":{}}}"#))
    }

    func testTabLinesShowIdTitleAndAddress() {
        let listing = #"{"result":[{"id":3,"url":"https://a.com","title":"A"},{"id":5,"url":"https://b.com","title":""}]}"#
        XCTAssertEqual(BrowserReply.tabLines(in: listing, limit: 10), ["3 A — https://a.com", "5 https://b.com"])
        XCTAssertEqual(BrowserReply.tabLines(in: listing, limit: 1).count, 1)
    }

    func testNavigationErrorIsFoundOnlyWhenPresent() {
        XCTAssertEqual(BrowserReply.navigationError(in: #"{"result":{"errorText":"net::ERR_NAME_NOT_RESOLVED"}}"#), "net::ERR_NAME_NOT_RESOLVED")
        XCTAssertNil(BrowserReply.navigationError(in: #"{"result":{"frameId":"abc"}}"#))
    }

    /// A link that would open a new tab is opened in the background; a link that stays in its tab is clicked as before.
    func testNewTabLinksAreOpenedInTheBackgroundAndOtherLinksAreClicked() {
        XCTAssertEqual(BrowserRules.newTabLinkURL(href: "https://example.com/a", target: "_blank"), "https://example.com/a")
        XCTAssertEqual(BrowserRules.newTabLinkURL(href: "https://example.com/a", target: " _BLANK "), "https://example.com/a")
        XCTAssertNil(BrowserRules.newTabLinkURL(href: "https://example.com/a", target: ""), "same tab")
        XCTAssertNil(BrowserRules.newTabLinkURL(href: "https://example.com/a", target: "_self"))
        XCTAssertNil(BrowserRules.newTabLinkURL(href: "javascript:void(0)", target: "_blank"), "only web addresses")
        XCTAssertNil(BrowserRules.newTabLinkURL(href: "", target: "_blank"), "no address, click as before")
    }

    func testExplainNamesADetachedLinkAndAClosedTab() {
        XCTAssertTrue(BrowserReply.explain("Detached while handling command.").contains("lost the link"))
        XCTAssertTrue(BrowserReply.explain("No tab with id: 42.").hasPrefix("that tab is closed"))
        XCTAssertFalse(BrowserReply.explain("No tab with id: 42.").contains("\n"))
    }

    func testLanesAreKeptAndNamedPerAgentScope() {
        let main = BrowserBridge.lane(0)
        XCTAssertTrue(main.sessionID.hasSuffix("-lane1-main"))
        XCTAssertTrue(main === BrowserBridge.lane(0), "a lane is created once and kept")
        let alpha = ClientScope.with("alpha") { BrowserBridge.lane(0) }
        let beta = ClientScope.with("beta") { BrowserBridge.lane(0) }
        XCTAssertTrue(alpha.sessionID.hasSuffix("-lane1-alpha"), alpha.sessionID)
        XCTAssertTrue(beta.sessionID.hasSuffix("-lane1-beta"), beta.sessionID)
        XCTAssertFalse(alpha === beta)
        XCTAssertFalse(alpha.sessionID == main.sessionID)
        let otherClient = ClientScope.with("alpha-lane1") { BrowserBridge.shared.sessionID }
        XCTAssertNotEqual(alpha.sessionID, otherClient)
    }

    func testRequestEnvironmentReachesEveryPeekLaneAndRestoresTheCaller() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("obu")
        let script = """
        #!/bin/sh
        IFS= read -r initialization
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        printf '{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"%s %s %s %s"}]}}\n' "$2" "$3" "$5" "$PEEK_TEST_VALUE"
        IFS= read -r finalize
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{}}'
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = [
            "OPEN_COMPUTER_USE_BROWSER": "1",
            "OPEN_COMPUTER_USE_OBU_BIN": helper.path,
            "OPEN_COMPUTER_USE_BROWSER_SESSION": "fixture",
            "OPEN_COMPUTER_USE_BROWSER_PROFILE": "fixture-profile",
            "OPEN_COMPUTER_USE_BROWSER_APP": "Fixture Chrome",
            "PEEK_TEST_VALUE": "fixture-env",
        ]
        let originalApp = BrowserBridge.browserApp
        ClientScope.with("peek-environment-test") {
            withBrowserRequestEnvironment(environment) {
                XCTAssertTrue(BrowserBridge.isAvailable)
                XCTAssertEqual(BrowserBridge.browserApp, "Fixture Chrome")
                XCTAssertTrue(BrowserBridge.lane(0) === BrowserBridge.lane(0))
                let shared = BrowserBridge.shared
                withBrowserRequestEnvironment(environment.merging(["UNRELATED_FIXTURE_VALUE": "new"]) { _, new in new }) {
                    XCTAssertTrue(BrowserBridge.shared === shared)
                }
                withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_BROWSER": "0"]) {
                    XCTAssertFalse(BrowserBridge.isAvailable)
                }
                let report = ComputerUseToolDispatcher.peekPages(["https://first.test", "https://second.test"])
                for lane in 1...2 {
                    XCTAssertTrue(report.contains(
                        "--session-id fixture-lane\(lane)-peek-environment-test fixture-profile fixture-env"
                    ), report)
                }
            }
        }
        XCTAssertEqual(BrowserBridge.browserApp, originalApp)
        XCTAssertNil(BrowserRequestContext.current)
    }

    func testCloseVerifiesAnUncertainReplyWithoutResending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("obu")
        let script = #"""
        #!/bin/sh
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"result\":{\"tab\":{\"id\":12}}}"}]}}'
        IFS= read -r request
        case "$request" in *Page.close*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"isError":true,"content":[{"type":"text","text":"close acknowledgement lost"}]}}'
        IFS= read -r request
        case "$request" in *'"name":"tabs"'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"result\":[{\"id\":12}]}"}]}}'
        IFS= read -r request
        case "$request" in *'"name":"tabs"'*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"{\"result\":[]}"}]}}'
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let bridge = BrowserBridge(sessionID: "close-ack-test", launchEnvironment: [
            "OPEN_COMPUTER_USE_BROWSER": "1", "OPEN_COMPUTER_USE_OBU_BIN": helper.path,
        ])
        let opened = try bridge.callTool("open_tab", arguments: [:], timeout: 3)
        XCTAssertFalse(opened.isError)
        bridge.currentTab = 12
        try bridge.closeOpenedTab(12)
        XCTAssertNil(bridge.currentTab)
    }

    func testPeekWorkersApplyRequestValidationBeforeLaunchingTheirHelpers() throws {
        let environment = [
            "OPEN_COMPUTER_USE_BROWSER": "1",
            "OPEN_COMPUTER_USE_OBU_BIN": "/usr/bin/true",
        ]
        try ClientScope.with("peek-validation-test") {
            try withBrowserRequestEnvironment(environment, validate: {
                throw ComputerUseError.stateUnavailable("fixture revoked browser access")
            }) {
                let report = ComputerUseToolDispatcher.peekPages(["https://first.test", "https://second.test"])
                XCTAssertEqual(report.components(separatedBy: "fixture revoked browser access").count, 3, report)
            }
        }
    }

    func testDeadlineIsLocalAndRestoredAfterNestedCall() {
        BrowserCallBudget.withDeadline(BrowserCallBudget.deadline(after: 90)) {
            let work = DispatchWorkItem {
                XCTAssertNil(BrowserCallBudget.activeRemaining)
            }
            DispatchQueue(label: "budget-test").async(execute: work)
            work.wait()
            BrowserCallBudget.withDeadline(BrowserCallBudget.deadline(after: 1)) {
                XCTAssertLessThanOrEqual(BrowserCallBudget.remaining(), 1)
            }
            XCTAssertGreaterThan(BrowserCallBudget.remaining(), 80)
        }
        XCTAssertNil(BrowserCallBudget.activeRemaining)
    }

    func testExplainGivesOneLineWithTheNextStep() {
        XCTAssertTrue(BrowserReply.explain("No node with given id found").contains("browser read"))
        XCTAssertTrue(BrowserReply.explain("Debugger unattached").contains("lost the link"))
        XCTAssertTrue(BrowserReply.explain("Could not compute box model.").contains("hidden"))
        XCTAssertFalse(BrowserReply.explain("Some\nlong\nerror").contains("\n"))
        XCTAssertEqual(BrowserReply.explain("Weird failure"), "Weird failure")
        XCTAssertFalse(BrowserReply.explain("").isEmpty)
    }

    func testFindKeepsOnlyMatchingLinesAndTheirIndexes() {
        var parse = BrowserAXParse()
        parse.controls = [
            BrowserNode(index: 1, role: "link", name: "Pricing", value: "", backendNodeID: 11, inFrame: false),
            BrowserNode(index: 2, role: "button", name: "Add to cart", value: "", backendNodeID: 12, inFrame: false),
            BrowserNode(index: 3, role: "link", name: "Cart (2)", value: "", backendNodeID: 13, inFrame: true),
        ]
        parse.texts = ["# Pricing plans", "  Free shipping over $50"]
        let cart = BrowserPage.filtered(parse, find: "cart")
        XCTAssertEqual(cart.controls.map(\.index), [2, 3])
        XCTAssertEqual(cart.framedControls, 1)
        XCTAssertTrue(cart.texts.isEmpty)
        XCTAssertEqual(BrowserPage.filtered(parse, find: "pricing PLANS").texts, ["# Pricing plans"])
    }

    func testSparsePageSuggestsAScreenshot() {
        var parse = BrowserAXParse()
        parse.controls = [BrowserNode(index: 1, role: "button", name: "Zoom in", value: "", backendNodeID: 1, inFrame: false)]
        XCTAssertTrue(BrowserPage.renderRead(parse, href: "https://maps.example", title: "Map", readyState: "complete").contains("browser screenshot"))
    }

    // MARK: - Change line, new marks, typing, fingerprint

    func testChangeLineSaysNavigatedChangedOrNoChange() {
        XCTAssertEqual(BrowserRules.change(["href": "https://b.test/x", "seenHref": "https://a.test", "mut": 5, "seen": 5]), .navigated("https://b.test/x"))
        XCTAssertEqual(BrowserRules.change(["href": "https://a.test", "seenHref": "https://a.test", "mut": 7, "seen": 5]), .changed)
        XCTAssertEqual(BrowserRules.change(["href": "https://a.test", "seenHref": "https://a.test", "mut": 5, "seen": 5]), .none)
        // No baseline address: never called a navigation.
        XCTAssertEqual(BrowserRules.change(["href": "https://a.test", "mut": 1, "seen": 0]), .changed)
        XCTAssertEqual(BrowserChange.navigated("https://b.test").line, "navigated to https://b.test")
        XCTAssertEqual(BrowserChange.changed.line, "page changed")
        XCTAssertEqual(BrowserChange.none.line, "no change")
    }

    func testNewControlsAreMarkedWithAStarOnlyOnTheSamePage() {
        let before = [node(1, "button", "Open"), node(2, "link", "Home")]
        let keys = BrowserRules.controlKeys(before)
        let after = [node(1, "button", "Open"), node(2, "button", "Save"), node(3, "link", "Home")]
        let marked = BrowserRules.markNew(after, previousKeys: keys)
        XCTAssertEqual(marked.map(\.isNew), [false, true, false])
        XCTAssertEqual(marked[1].line, "2* button Save")
        XCTAssertEqual(BrowserRules.markNew(after, previousKeys: nil).filter(\.isNew).count, 0)
        // A whole new page marks nothing.
        XCTAssertEqual(BrowserRules.markNew([node(1, "button", "X")], previousKeys: keys).filter(\.isNew).count, 0)
        var parse = BrowserAXParse()
        parse.controls = marked
        parse.newControls = 1
        XCTAssertTrue(BrowserPage.renderRead(parse, href: "https://a.test", title: "A", readyState: "complete").contains("* = new since your last read"))
    }

    func testTypingSendsTheLastCharacterAsAKeyEvent() throws {
        let split = BrowserRules.splitForTyping("hello")
        XCTAssertEqual(split.head, "hell")
        XCTAssertEqual(split.last, "o")
        XCTAssertNil(BrowserRules.splitForTyping("a\n").last)
        XCTAssertNil(BrowserRules.splitForTyping("").last)
        let o = try XCTUnwrap(BrowserKeyCombo.forTypedCharacter("o"))
        XCTAssertEqual(o.text, "o")
        XCTAssertEqual(o.code, "KeyO")
        let capital = try XCTUnwrap(BrowserKeyCombo.forTypedCharacter("Q"))
        XCTAssertEqual(capital.text, "Q")
        XCTAssertEqual(capital.modifiers, BrowserKeyCombo.shift)
        XCTAssertEqual(try XCTUnwrap(BrowserKeyCombo.forTypedCharacter(" ")).text, " ")
        let odd = try XCTUnwrap(BrowserKeyCombo.forTypedCharacter("é"))
        XCTAssertEqual(odd.text, "é")
        XCTAssertEqual(odd.code, "")
    }

    func testTypeReplyEchoesFieldAndOptions() {
        var outcome = BrowserTypeOutcome()
        outcome.change = .changed
        outcome.options = ["Amsterdam", "Amstelveen"]
        outcome.note = "(field now shows \"Ams\")"
        XCTAssertEqual(
            outcome.reply(verb: "typed into", target: "combobox \"City\""),
            "typed into combobox \"City\"; (field now shows \"Ams\"); page changed; options: Amsterdam | Amstelveen"
        )
        XCTAssertEqual(BrowserTypeOutcome(picked: "chose \"Canada\" in \"Country\"; no change").reply(verb: "typed into", target: "x"),
                       "chose \"Canada\" in \"Country\"; no change")
    }

    func testFingerprintCatchesRenamedAndChangedElements() {
        let button = BrowserNode(index: 1, role: "button", name: "Add to cart", value: "A", backendNodeID: 1)
        XCTAssertEqual(BrowserRules.fingerprint(button, nowName: "Add to cart", nowValue: "A"), .same)
        XCTAssertEqual(BrowserRules.fingerprint(button, nowName: "Remove", nowValue: "A"), .renamed("Remove"))
        XCTAssertEqual(BrowserRules.fingerprint(button, nowName: "Add to cart", nowValue: "B"), .valueChanged("B"))
        let field = BrowserNode(index: 2, role: "textbox", name: "Email", value: "a", backendNodeID: 2)
        XCTAssertEqual(BrowserRules.fingerprint(field, nowName: "Email", nowValue: "abc"), .same)
    }

    func testContextIsTheTextBeforeAControlWithoutDigits() {
        XCTAssertEqual(BrowserRules.contextText("  Blue   Mug ", excluding: "Add"), "Blue Mug")
        XCTAssertEqual(BrowserRules.contextText("Cart (2)", excluding: "Checkout"), "")
        XCTAssertEqual(BrowserRules.contextText("Add", excluding: "Add"), "")
        let parse = BrowserPage.parseAX([
            ax("RootWebArea", "Shop"),
            ax("StaticText", "Blue Mug"),
            ax("button", "Add to cart", backend: 5),
            ax("textbox", "Search", backend: 6),
        ])
        XCTAssertEqual(parse.controls.first?.context, "Blue Mug")
        XCTAssertEqual(parse.controls.last?.context, "")
    }

    func testHiddenTextLinesAreDropped() {
        XCTAssertEqual(BrowserPage.keepVisible(["# A", "  B", "  C"], flags: [true, false, true]), ["# A", "  C"])
        XCTAssertEqual(BrowserPage.keepVisible(["# A"], flags: []), ["# A"])
    }

    func testLinkThatStaysInThePageIsNotFollowed() {
        XCTAssertFalse(BrowserRules.leadsElsewhere(href: "#top"))
        XCTAssertFalse(BrowserRules.leadsElsewhere(href: "javascript:void(0)"))
        XCTAssertTrue(BrowserRules.leadsElsewhere(href: "https://a.test/x"))
        XCTAssertTrue(BrowserRules.coveredMessage(role: "button", name: "Pay", by: "Cookies").contains("covered"))
    }

    func testSettleScriptCarriesTheCap() {
        XCTAssertTrue(BrowserPage.settleJS(cap: 800).contains("quiet:"))
        XCTAssertFalse(BrowserPage.settleJS(cap: 800).contains("Promise"))
        XCTAssertTrue(BrowserPage.pageStateJS.contains("beforeunload"))
    }
}

extension BrowserPageTests {
    func testUploadVerificationRejectsWrongFilesWithSameCount() {
        let expected = [BrowserPage.UploadFile(name: "fixture.txt", size: 4)]
        XCTAssertTrue(BrowserPage.matchesUploadSelection([["fixture.txt", 4]], expected: expected))
        XCTAssertFalse(BrowserPage.matchesUploadSelection([["wrong.txt", 4]], expected: expected))
        XCTAssertFalse(BrowserPage.matchesUploadSelection([["fixture.txt", 5]], expected: expected))
        XCTAssertFalse(BrowserPage.matchesUploadSelection(nil, expected: expected))
    }
}
