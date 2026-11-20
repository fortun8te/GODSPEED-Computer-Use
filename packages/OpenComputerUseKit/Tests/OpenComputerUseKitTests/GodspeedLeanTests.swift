import AppKit
import Foundation
import ImageIO
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for the lean batch/referee/browser helpers. Nothing here opens a window,
/// touches accessibility, the network or a child process.
final class GodspeedLeanTests: XCTestCase {
    // MARK: - Helpers

    private func parse(_ raw: Any?, app: String? = nil) throws -> [BatchTool.Step] {
        try BatchTool.parseSteps(raw, defaultApp: app)
    }

    /// Asserts that parsing `raw` throws ComputerUseError.invalidArguments containing `needle`.
    private func assertInvalid(
        _ raw: Any?,
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let steps = try parse(raw)
            XCTFail("expected an error containing '\(needle)', got \(steps.count) steps", file: file, line: line)
        } catch let error as ComputerUseError {
            guard case .invalidArguments(let message) = error else {
                return XCTFail("expected invalidArguments, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(needle), "message was: \(message)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    private func uniqueApp(_ label: String = "app") -> String {
        "godspeed-\(label)-\(UUID().uuidString)"
    }

    /// A PNG encoded in memory with ImageIO; nothing is written to disk.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpaceCreateDeviceRGB() as CGColorSpace?)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: - BatchTool.parseSteps: spellings and aliases

    func testToolAliasesCanonicalise() throws {
        let aliases: [(String, String)] = [
            ("type", "type_text"), ("write", "type_text"), ("input", "type_text"), ("enter_text", "type_text"),
            ("key", "press_key"), ("press", "press_key"), ("keypress", "press_key"),
            ("hotkey", "press_key"), ("shortcut", "press_key"),
            ("set", "set_value"), ("fill", "set_value"),
            ("state", "get_app_state"), ("look", "get_app_state"), ("observe", "get_app_state"), ("read", "get_app_state"),
            ("find", "query"), ("search", "query"),
            ("secondary_action", "perform_secondary_action"),
            ("tap", "click"), ("left_click", "click"), ("press_button", "click"),
            ("apps", "list_apps"),
        ]
        for (alias, expected) in aliases {
            XCTAssertEqual(BatchTool.canonicalToolName(alias), expected, "alias \(alias)")
            let steps = try parse([["tool": alias]], app: "Notes")
            XCTAssertEqual(steps.first?.tool, expected, "parsed alias \(alias)")
        }
    }

    func testCanonicalToolNameTrimsAndLowercases() {
        XCTAssertEqual(BatchTool.canonicalToolName("  Tap \n"), "click")
        XCTAssertEqual(BatchTool.canonicalToolName("TYPE"), "type_text")
        XCTAssertEqual(BatchTool.canonicalToolName("Click"), "click")
    }

    func testToolNameCanBeGivenAsNameOrAction() throws {
        let byName = try parse([["name": "Type", "text": "hi"]], app: "Notes")
        XCTAssertEqual(byName.first?.tool, "type_text")
        XCTAssertEqual(byName.first?.arguments["text"] as? String, "hi")

        let byAction = try parse([["action": "tap", "label": "OK"]], app: "Notes")
        XCTAssertEqual(byAction.first?.tool, "click")
        XCTAssertNil(byAction.first?.arguments["action"], "the action key is consumed, not passed on")
        XCTAssertEqual(byAction.first?.arguments["label"] as? String, "OK")

        let look = try parse([["action": "look"]], app: "Notes")
        XCTAssertEqual(look.first?.tool, "get_app_state")
    }

    func testActionThatIsNotAToolIsNotUsedAsTool() {
        assertInvalid([["action": "dance"]], contains: "needs a tool")
    }

    // MARK: - BatchTool.parseSteps: arguments

    func testNestedArgsAreUsedAndInlineArgsOverrideThem() throws {
        let steps = try parse([
            ["tool": "click", "args": ["label": "Send", "app": "Mail"], "label": "Override"],
        ])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].tool, "click")
        XCTAssertEqual(steps[0].arguments["label"] as? String, "Override", "inline wins over nested")
        XCTAssertEqual(steps[0].arguments["app"] as? String, "Mail", "nested value kept when not overridden")
    }

    func testArgumentsSpellingWorksLikeArgs() throws {
        let steps = try parse([["tool": "click", "arguments": ["label": "Go"]]], app: "Notes")
        XCTAssertEqual(steps[0].arguments["label"] as? String, "Go")
        XCTAssertNil(steps[0].arguments["arguments"], "the wrapper key itself is not copied into arguments")
        XCTAssertNil(steps[0].arguments["args"])
    }

    func testInlineArgsAreCopiedAndToolKeysAreNot() throws {
        let steps = try parse([["tool": "press_key", "key": "Return"]], app: "Notes")
        XCTAssertEqual(steps[0].arguments["key"] as? String, "Return")
        XCTAssertNil(steps[0].arguments["tool"])
        XCTAssertNil(steps[0].arguments["name"])
    }

    func testDefaultAppIsInjectedOnlyWhenMissing() throws {
        let steps = try parse([
            ["tool": "click", "label": "Send"],
            ["tool": "click", "label": "X", "app": "Mail"],
        ], app: "Notes")
        XCTAssertEqual(steps[0].arguments["app"] as? String, "Notes")
        XCTAssertEqual(steps[1].arguments["app"] as? String, "Mail")
    }

    func testNoDefaultAppMeansNoAppKey() throws {
        let steps = try parse([["tool": "click", "label": "Send"]], app: nil)
        XCTAssertNil(steps[0].arguments["app"])
    }

    // MARK: - BatchTool.parseSteps: refusals

    func testUnknownToolErrorListsRealToolsAndNotBatch() {
        do {
            _ = try parse([["tool": "teleport"]], app: "Notes")
            XCTFail("expected unknown-tool error")
        } catch let error as ComputerUseError {
            guard case .invalidArguments(let message) = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
            XCTAssertTrue(message.contains("step 1"), message)
            XCTAssertTrue(message.contains("unknown tool 'teleport'"), message)
            XCTAssertTrue(message.contains("Use one of:"), message)
            XCTAssertTrue(message.contains("click"), message)
            XCTAssertTrue(message.contains("get_app_state"), message)
            XCTAssertTrue(message.contains("press_key"), message)
            XCTAssertFalse(message.contains("batch"), "batch must not be offered as a step: \(message)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUnknownToolReportsStepNumber() {
        assertInvalid([["tool": "click"], ["tool": "teleport"]], contains: "step 2: unknown tool")
    }

    func testNestedBatchIsRefused() {
        assertInvalid([["tool": "batch"]], contains: "cannot contain another batch")
        assertInvalid([["tool": "Batch"]], contains: "cannot contain another batch")
        assertInvalid([["name": "BATCH"]], contains: "cannot contain another batch")
    }

    func testMoreThanFortyStepsIsRefused() throws {
        let forty = Array(repeating: ["tool": "click", "label": "x"] as [String: Any], count: 40)
        XCTAssertEqual(try parse(forty, app: "Notes").count, 40, "exactly 40 steps are allowed")
        XCTAssertEqual(BatchTool.maxSteps, 40)

        let fortyOne = Array(repeating: ["tool": "click", "label": "x"] as [String: Any], count: 41)
        assertInvalid(fortyOne, contains: "at most 40 entries")
    }

    func testEmptyOrMissingStepsAreRefused() {
        assertInvalid([Any](), contains: "steps must be a non-empty array")
        assertInvalid(nil, contains: "steps must be a non-empty array")
        assertInvalid("click", contains: "steps must be a non-empty array")
    }

    func testStepThatIsNotAnObjectIsRefused() {
        assertInvalid(["click"], contains: "step 1 must be an object")
    }

    func testShorthandStepsAreRead() throws {
        let steps = try BatchTool.parseSteps([["key": "cmd+a"], ["type_text": "69104"], ["label": "Send"], ["press_key": "cmd+s"]], defaultApp: "TextEdit")
        XCTAssertEqual(steps.map(\.tool), ["press_key", "type_text", "click", "press_key"])
        XCTAssertEqual(steps[1].arguments["text"] as? String, "69104")
        XCTAssertEqual(steps[3].arguments["key"] as? String, "cmd+s")
    }

    func testStepWithoutToolIsRefused() {
        assertInvalid([["foo": "Send"]], contains: "step 1 needs a tool")
        assertInvalid([["tool": ""]], contains: "step 1 needs a tool")
    }

    // MARK: - BatchTool.describe

    func testDescribeLabelAndTextAndKey() {
        let click = BatchTool.Step(tool: "click", arguments: ["label": "Send"])
        XCTAssertEqual(BatchTool.describe(click), "click \"Send\"")

        let type = BatchTool.Step(tool: "type_text", arguments: ["text": "running late"])
        XCTAssertEqual(BatchTool.describe(type), "type_text \"running late\"")

        let key = BatchTool.Step(tool: "press_key", arguments: ["key": "Return"])
        XCTAssertEqual(BatchTool.describe(key), "press_key Return")
    }

    func testDescribeClipsLongLabels() {
        let long = String(repeating: "a", count: 50)
        let step = BatchTool.Step(tool: "click", arguments: ["label": long])
        XCTAssertEqual(BatchTool.describe(step), "click \"" + String(repeating: "a", count: 40) + "…\"")
    }

    func testDescribeJoinsLabelsWithSlash() {
        let step = BatchTool.Step(tool: "click", arguments: ["labels": ["A", "B"]])
        XCTAssertEqual(BatchTool.describe(step), "click \"A / B\"")
    }

    func testDescribeElementIndexAndCoordinates() {
        let indexed = BatchTool.Step(tool: "scroll", arguments: ["element_index": 12, "direction": "down"])
        XCTAssertEqual(BatchTool.describe(indexed), "scroll #12 down")

        let point = BatchTool.Step(tool: "click", arguments: ["x": 10, "y": 20])
        XCTAssertEqual(BatchTool.describe(point), "click at 10,20")
    }

    func testDescribeValueAndBrowserAction() {
        let set = BatchTool.Step(tool: "set_value", arguments: ["label": "Name", "value": "Ada"])
        XCTAssertEqual(BatchTool.describe(set), "set_value \"Name\" = \"Ada\"")

        let go = BatchTool.Step(tool: "browser", arguments: ["action": "go", "url": "https://example.com"])
        XCTAssertEqual(BatchTool.describe(go), "browser go https://example.com")

        let browserClick = BatchTool.Step(tool: "browser", arguments: ["action": "click", "label": "Sign in"])
        XCTAssertEqual(BatchTool.describe(browserClick), "browser click \"Sign in\"")
    }

    // MARK: - BatchTool.firstLine and clipped

    func testFirstLineSkipsBlankLinesAndTrims() {
        XCTAssertEqual(BatchTool.firstLine("\n   \n  first  \nsecond"), "first")
        XCTAssertEqual(BatchTool.firstLine(""), "no details")
        XCTAssertEqual(BatchTool.firstLine(" \n \n\t"), "no details")
    }

    func testFirstLineClipsWithEllipsis() {
        XCTAssertEqual(BatchTool.firstLine("aaaaaaaaaa", limit: 4), "aaaa…")
        XCTAssertEqual(BatchTool.firstLine("abcd", limit: 4), "abcd", "exactly at the limit is not clipped")
    }

    func testClippedKeepsShortTextAndCutsLongText() {
        XCTAssertEqual(BatchTool.clipped("abc", limit: 3), "abc")
        XCTAssertEqual(BatchTool.clipped("abcdef", limit: 3), "abc\n… (cut; use query for more)")
    }

    // MARK: - LeanDefaults and AX compact default (env-dependent: skipped when the variable is set)

    func testIncludeScreenshotDefaultsToFalse() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT"] != nil,
            "OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT is set in this environment"
        )
        XCTAssertFalse(LeanDefaults.includeScreenshot)
    }

    func testAXCompactIsOnByDefault() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_AX_COMPACT"] != nil,
            "OPEN_COMPUTER_USE_AX_COMPACT is set in this environment"
        )
        XCTAssertTrue(AXTreeTextFormatting.compactByDefault)
    }

    // MARK: - BatchObservationMemory

    func testRecordOutcomeCountsRepeatedFailuresOnTheSameStep() {
        let app = uniqueApp("outcome")
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: app, failedStep: "click \"Send\""), 1)
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: app, failedStep: "click \"Send\""), 2)
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: app, failedStep: "click \"Send\""), 3)
    }

    func testRecordOutcomeResetsWhenStepChangesOrBatchSucceeds() {
        let app = uniqueApp("reset")
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: app, failedStep: "click \"Send\""), 1)
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: app, failedStep: "click \"Other\""), 1,
                       "a different failing step starts again at 1")
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: app, failedStep: nil), 0, "success returns 0")
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: app, failedStep: "click \"Other\""), 1,
                       "after a success the streak is gone")
    }

    func testRecordOutcomeKeepsAppsSeparate() {
        let first = uniqueApp("first")
        let second = uniqueApp("second")
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: first, failedStep: "click \"A\""), 1)
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: second, failedStep: "click \"A\""), 1)
        XCTAssertEqual(BatchObservationMemory.shared.recordOutcome(app: first, failedStep: "click \"A\""), 2)
    }

    func testExchangeReturnsPreviousHashPerApp() {
        let app = uniqueApp("exchange")
        let other = uniqueApp("exchange-other")
        XCTAssertNil(BatchObservationMemory.shared.exchange(app: app, hash: 111), "first look has no previous")
        XCTAssertEqual(BatchObservationMemory.shared.exchange(app: app, hash: 222), 111)
        XCTAssertEqual(BatchObservationMemory.shared.exchange(app: app, hash: 222), 222, "same state again")
        XCTAssertNil(BatchObservationMemory.shared.exchange(app: other, hash: 9), "other app is untouched")
    }

    // MARK: - Referee

    private func verdict(_ label: String, _ confidence: Double) -> Referee.Verdict {
        Referee.Verdict(label: label, confidence: confidence, milliseconds: 0)
    }

    func testRefereeHintForDoneStuckAndLookAgain() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE"] != nil,
            "referee threshold overridden in this environment"
        )
        XCTAssertEqual(Referee.minimumConfidence, 0.6, accuracy: 0.0001)

        let done = try XCTUnwrap(Referee.hint(for: verdict("done", 0.9)))
        XCTAssertTrue(done.hasPrefix("Check: the goal may be reached (90% sure)"), done)

        let stuck = try XCTUnwrap(Referee.hint(for: verdict("stuck", 0.75)))
        XCTAssertTrue(stuck.hasPrefix("Check: this looks stuck (75% sure)"), stuck)

        let again = try XCTUnwrap(Referee.hint(for: verdict("look_again", 0.6)))
        XCTAssertTrue(again.hasPrefix("Check: the state may be stale or still loading (60% sure)"), again)
        XCTAssertTrue(again.contains("get_app_state"), again)
    }

    func testRefereeConfidenceThresholdIsInclusiveAtSixTenths() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE"] != nil,
            "referee threshold overridden in this environment"
        )
        XCTAssertNotNil(Referee.hint(for: verdict("stuck", 0.6)), "0.6 is kept")
        XCTAssertNil(Referee.hint(for: verdict("stuck", 0.59)), "just below 0.6 is left out")
        // "done" needs 0.86 (dev-split tuning, see Referee.doneConfidence): a wrong done is worse than no hint.
        XCTAssertNil(Referee.hint(for: verdict("done", 0.8)))
        XCTAssertNil(Referee.hint(for: verdict("done", 0.85)), "0.85 is below the done threshold of 0.86")
        XCTAssertNotNil(Referee.hint(for: verdict("done", 0.86)))
        XCTAssertNil(Referee.hint(for: verdict("stuck", 0.1)))
    }

    func testRefereeRejectsInvalidConfidence() {
        for confidence in [Double.infinity, -Double.infinity, Double.nan, -0.1, 1.1] {
            XCTAssertNil(Referee.hint(for: verdict("stuck", confidence)))
        }
    }

    func testRefereeActAndUnknownLabelsAddNothing() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE"] != nil,
            "referee threshold overridden in this environment"
        )
        XCTAssertNil(Referee.hint(for: verdict("act", 0.99)), "act means nothing extra to say")
        XCTAssertNil(Referee.hint(for: verdict("banana", 0.99)), "unknown labels add nothing")
    }

    // MARK: - ComputerUseToolDispatcher browser helpers (BrowserBridge.swift)

    func testBrowserURLAddsSchemeOnlyWhenMissing() {
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("example.com"), "https://example.com")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("  example.com/a  "), "https://example.com/a")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("http://x.test/p"), "http://x.test/p")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("https://x.test"), "https://x.test")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("about:blank"), "about:blank")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("chrome://settings"), "chrome://settings")
        XCTAssertEqual(ComputerUseToolDispatcher.browserURL("file:///tmp/a.html"), "file:///tmp/a.html")
    }

    func testBrowserURLRejectsEmptyAndNonStrings() {
        XCTAssertNil(ComputerUseToolDispatcher.browserURL(nil))
        XCTAssertNil(ComputerUseToolDispatcher.browserURL(""))
        XCTAssertNil(ComputerUseToolDispatcher.browserURL("   "))
        XCTAssertNil(ComputerUseToolDispatcher.browserURL(42))
    }

    func testBrowserTabIDParsesNumbersAndNumericStrings() {
        XCTAssertEqual(ComputerUseToolDispatcher.browserTabID(NSNumber(value: 4)), 4)
        XCTAssertEqual(ComputerUseToolDispatcher.browserTabID("  12 "), 12)
        XCTAssertEqual(ComputerUseToolDispatcher.browserTabID("7"), 7)
    }

    func testBrowserTabIDRejectsBooleansAndJunk() {
        XCTAssertNil(ComputerUseToolDispatcher.browserTabID(true), "a JSON true is not tab 1")
        XCTAssertNil(ComputerUseToolDispatcher.browserTabID(false))
        XCTAssertNil(ComputerUseToolDispatcher.browserTabID("abc"))
        XCTAssertNil(ComputerUseToolDispatcher.browserTabID(nil))
    }

    func testFileChooserIDReadsKnownKeysInOrder() {
        XCTAssertEqual(ComputerUseToolDispatcher.fileChooserID(in: #"{"file_chooser_id":"abc"}"#), "abc")
        XCTAssertEqual(ComputerUseToolDispatcher.fileChooserID(in: #"{"fileChooserId":"xyz"}"#), "xyz")
        // A top-level `id` is OBU's JSON-RPC request id, never the chooser id.
        XCTAssertNil(ComputerUseToolDispatcher.fileChooserID(in: #"{"id":42}"#))
        XCTAssertEqual(
            ComputerUseToolDispatcher.fileChooserID(in: #"{"jsonrpc":"2.0","id":"cli-1","result":{"fileChooserId":"fc-7"}}"#),
            "fc-7"
        )
        XCTAssertEqual(ComputerUseToolDispatcher.fileChooserID(in: #"{"id":"cli-1","result":{"id":42}}"#), "42")
        XCTAssertEqual(
            ComputerUseToolDispatcher.fileChooserID(in: #"{"id":"second","file_chooser_id":"first"}"#),
            "first",
            "file_chooser_id is preferred over id"
        )
    }

    func testFileChooserIDReturnsNilWhenAbsentOrNotJSON() {
        XCTAssertNil(ComputerUseToolDispatcher.fileChooserID(in: #"{"other":"x"}"#))
        XCTAssertNil(ComputerUseToolDispatcher.fileChooserID(in: "not json at all"))
        XCTAssertNil(ComputerUseToolDispatcher.fileChooserID(in: #"["id"]"#))
    }

    func testBrowserLabelPrefersLabelThenFirstOfLabels() {
        XCTAssertEqual(ComputerUseToolDispatcher.browserLabel(["label": "Sign in"]), "Sign in")
        XCTAssertEqual(ComputerUseToolDispatcher.browserLabel(["labels": ["A", "B"]]), "A")
        XCTAssertEqual(
            ComputerUseToolDispatcher.browserLabel(["label": "Primary", "labels": ["Other"]]),
            "Primary",
            "label wins over labels"
        )
    }

    func testBrowserLabelIgnoresEmptyValues() {
        XCTAssertNil(ComputerUseToolDispatcher.browserLabel([:]))
        XCTAssertNil(ComputerUseToolDispatcher.browserLabel(["label": ""]))
        XCTAssertEqual(ComputerUseToolDispatcher.browserLabel(["label": "", "labels": ["Fallback"]]), "Fallback")
        XCTAssertNil(ComputerUseToolDispatcher.browserLabel(["labels": [] as [String]]))
    }

    func testRecipeGoalKeyPreservesOrderAndSingleCharacterWords() {
        XCTAssertNotEqual(BatchRecipes.goalKey("move A to B"), BatchRecipes.goalKey("move B to A"))
        XCTAssertEqual(BatchRecipes.goalKey("Open, Mail!"), BatchRecipes.goalKey("open mail"))
    }

    // MARK: - BrowserPage static helpers (BrowserPage.swift)

    func testBrowserPageFindLocatesKeyInNestedObjects() {
        let threeDeep: [String: Any] = ["a": ["b": ["c": ["nodes": [1, 2]]]]]
        XCTAssertEqual(BrowserPage.find("nodes", in: threeDeep) as? [Int], [1, 2])

        let direct: [String: Any] = ["value": "top"]
        XCTAssertEqual(BrowserPage.find("value", in: direct) as? String, "top")
    }

    func testBrowserPageFindStopsAtDepthLimit() {
        // Default depth is 4: a key only 4 objects down is out of reach, 3 down is found.
        let fourDeep: [String: Any] = ["a": ["b": ["c": ["d": ["key": "far"]]]]]
        XCTAssertNil(BrowserPage.find("key", in: fourDeep))
        let threeDeep: [String: Any] = ["a": ["b": ["c": ["key": "near"]]]]
        XCTAssertEqual(BrowserPage.find("key", in: threeDeep) as? String, "near")
    }

    func testBrowserPageFindIgnoresNonDictionaries() {
        XCTAssertNil(BrowserPage.find("key", in: [["key": "in an array"]]))
        XCTAssertNil(BrowserPage.find("key", in: "plain string"))
        XCTAssertNil(BrowserPage.find("missing", in: ["key": 1]))
    }

    func testBrowserPageAXValueReadsStringsAndNumbers() {
        XCTAssertEqual(BrowserPage.axValue(["value": "hello"]), "hello")
        XCTAssertEqual(BrowserPage.axValue(["value": NSNumber(value: 3)]), "3")
        XCTAssertEqual(BrowserPage.axValue(["value": NSNumber(value: 2.5)]), "2.5")
    }

    func testBrowserPageAXValueReturnsNilForMissingOrOtherTypes() {
        XCTAssertNil(BrowserPage.axValue(nil))
        XCTAssertNil(BrowserPage.axValue(["type": "string"]))
        XCTAssertNil(BrowserPage.axValue(["value": ["nested"]]))
        XCTAssertNil(BrowserPage.axValue("not a dictionary"))
    }

    func testBrowserPageCollapseNormalisesWhitespace() {
        XCTAssertEqual(BrowserPage.collapse("  hello \n  world\t "), "hello world")
        XCTAssertEqual(BrowserPage.collapse(""), "")
        XCTAssertEqual(BrowserPage.collapse("one"), "one")
    }

    func testBrowserPageNormalizeLowercasesAndDropsWhitespace() {
        XCTAssertEqual(BrowserPage.normalize("Sign In  Now"), "signinnow")
        XCTAssertEqual(BrowserPage.normalize(" A\tB\nC "), "abc")
        XCTAssertEqual(BrowserPage.normalize("Sign In"), BrowserPage.normalize("sign in"))
    }

    func testVisionLocationRejectsWrongJSONTypesAndOutOfBoundsPoints() throws {
        func point(_ json: String) throws -> CGPoint? {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return VisionFallback.location(in: object)
        }
        XCTAssertEqual(try point(#"{"found":true,"x":0.25,"y":1}"#), CGPoint(x: 0.25, y: 1))
        XCTAssertNil(try point(#"{"found":1,"x":0.25,"y":1}"#))
        XCTAssertNil(try point(#"{"found":true,"x":true,"y":0.25}"#))
        XCTAssertNil(try point(#"{"found":true,"x":0.25,"y":1.2}"#))
        XCTAssertNil(try point(#"{"found":false,"x":0.25,"y":0.25}"#))
    }

    // MARK: - VisionFallback.pixelSize

    func testPixelSizeReadsEncodedPNGDimensions() throws {
        let png = try makePNG(width: 7, height: 5)
        XCTAssertEqual(VisionFallback.pixelSize(of: png), CGSize(width: 7, height: 5))
    }

    func testPixelSizeReturnsNilForGarbage() {
        XCTAssertNil(VisionFallback.pixelSize(of: Data("definitely not an image".utf8)))
        XCTAssertNil(VisionFallback.pixelSize(of: Data()))
    }

    func testStateTextIgnoresSettleNotes() {
        let a = ToolCallResult.text("App=TextEdit\n1 button Save\nSettled: the window was unchanged for 1500 ms (waited 12 ms).")
        let b = ToolCallResult.text("App=TextEdit\n1 button Save\nSettled: the window was unchanged for 1500 ms (waited 97 ms).")
        XCTAssertEqual(BatchTool.stateText(of: a), BatchTool.stateText(of: b))
        XCTAssertFalse(BatchTool.stateText(of: a).contains("Settled"))
    }

    func testPositionalStepsAreNotRecipeSafe() throws {
        let labelled = try BatchTool.parseSteps([["tool": "click", "label": "Save"]], defaultApp: "TextEdit")
        XCTAssertFalse(BatchTool.usesPositionalTargets(labelled))
        let numbered = try BatchTool.parseSteps([["tool": "click", "element_index": "7"]], defaultApp: "TextEdit")
        XCTAssertTrue(BatchTool.usesPositionalTargets(numbered))
        let pixels = try BatchTool.parseSteps([["tool": "click", "x": 10, "y": 20]], defaultApp: "TextEdit")
        XCTAssertTrue(BatchTool.usesPositionalTargets(pixels))
    }

    func testFillExpandsToSetValuesAndSubmitClick() throws {
        let steps = try BatchTool.parseSteps(
            [["tool": "fill", "fields": [["label": "To", "value": "sam@x.com"], ["label": "Subject", "value": "Hi"]], "submit": "Send"]],
            defaultApp: "Mail"
        )
        XCTAssertEqual(steps.map(\.tool), ["set_value", "set_value", "click"])
        XCTAssertEqual(steps[0].arguments["label"] as? String, "To")
        XCTAssertEqual(steps[0].arguments["value"] as? String, "sam@x.com")
        XCTAssertEqual(steps[2].arguments["label"] as? String, "Send")
        XCTAssertEqual(steps[2].arguments["app"] as? String, "Mail")
    }

    func testFillWithoutFieldsIsRefused() {
        XCTAssertThrowsError(try BatchTool.parseSteps([["tool": "form"]], defaultApp: "Mail"))
        // A plain "fill" without fields is still the set_value alias.
        XCTAssertEqual(try BatchTool.parseSteps([["tool": "fill", "label": "To", "value": "x"]], defaultApp: "Mail").first?.tool, "set_value")
    }

    func testSettingsFileMapsToEnvironmentVariables() {
        let vars = GodspeedSettings.mappedVariables(from: [
            "cursor_visible": false, "cursor_color": "#2F6FDE", "cursor_speed": "fast",
            "screenshots_by_default": true, "decision_hints": true, "find_on_screen": false,
            "recipes": false, "browser": true,
        ])
        XCTAssertEqual(vars["OPEN_COMPUTER_USE_VISUAL_CURSOR"], "0")
        XCTAssertEqual(vars["OPEN_COMPUTER_USE_CURSOR_COLOR"], "#2F6FDE")
        XCTAssertEqual(vars["OPEN_COMPUTER_USE_CURSOR_SPEED"], "8")
        XCTAssertEqual(vars["OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT"], "1")
        XCTAssertEqual(vars["OPEN_COMPUTER_USE_REFEREE_URL"], "http://127.0.0.1:8765")
        XCTAssertNil(vars["OPEN_COMPUTER_USE_VISION_URL"])
        XCTAssertEqual(vars["OPEN_COMPUTER_USE_RECIPES"], "0")
        XCTAssertEqual(vars["OPEN_COMPUTER_USE_BROWSER"], "1")
        XCTAssertNil(GodspeedSettings.mappedVariables(from: ["cursor_color": "default"])["OPEN_COMPUTER_USE_CURSOR_COLOR"])
    }

    func testEnvironmentWinsOverSettingsFile() {
        let merged = GodspeedSettings.merged(["OPEN_COMPUTER_USE_CURSOR_SPEED": "2"])
        XCTAssertEqual(merged["OPEN_COMPUTER_USE_CURSOR_SPEED"], "2")
    }

    func testCursorColorParsesHex() {
        let blue = CursorColor(hex: "#2F6FDE")
        XCTAssertNotNil(blue)
        XCTAssertEqual(blue?.red ?? 0, 47.0 / 255, accuracy: 0.001)
        XCTAssertNil(CursorColor(hex: "blue"))
        XCTAssertNil(CursorColor(hex: nil))
    }

    func testDiffAlwaysAppliesWithStableNumbers() throws {
        // A new element takes a new number; the old ones keep theirs, so the diff lists only what changed.
        let before = "App=X\nWindow: w\n[legend]\n\t1 button Save\n\t2 text field To = a (w:str)"
            + (10...25).map { "\n\t\($0) button Another control \($0)" }.joined()
        let after = before + "\n\t3 button New"
        let observation = ToolCallResult(content: [.text(after)], isError: false)
        let diffed = LeanOutput.diffed(observation, previous: before)
        XCTAssertTrue(diffed.textContent.contains("+ \t3 button New"), diffed.textContent)
        XCTAssertFalse(diffed.textContent.contains("button Save"), diffed.textContent)
        XCTAssertEqual(LeanOutput.leadingIndex("\t\t12 button Send"), "12")
        XCTAssertNil(LeanOutput.leadingIndex("Window: w"))
    }

    func testIndexMatchingTreatsAReplacedElementAsAChange() throws {
        let keep = (10..<20).map { "\t\($0) button Keep \($0)" }.joined(separator: "\n")
        let before = "\t1 button Delete\n" + keep
        let after = "\t5 button Delete\n" + keep
        // Indexes ignored: reads as unchanged. Indexes matched: the new number is shown, the old one is listed as removed.
        XCTAssertEqual(AXStateDiff.diff(previous: before, current: after), AXStateDiff.noChangesMessage)
        let matched = try XCTUnwrap(AXStateDiff.diff(previous: before, current: after, matchIndexes: true))
        XCTAssertTrue(matched.contains("- 1 button Delete"), matched)
        XCTAssertTrue(matched.contains("+ \t5 button Delete"), matched)
    }

    func testIndexOnlyActionStepStaysNativeWhenAppIsKnown() throws {
        let steps = try BatchTool.parseSteps([["action": "click", "index": 3]], defaultApp: "Finder")
        XCTAssertEqual(steps.first?.tool, "click")
    }
}

extension GodspeedLeanTests {
    func testCompactRepeatedSuccessesPreservesNotesAndStepBoundaries() {
        XCTAssertEqual(BatchTool.compactRepeatedSuccesses([
            "1. type: ok", "2. type: ok", "3. query: ok\nResult",
            "4. type: ok", "   effect: changed", "5. type: ok", "6. type: ok - outcome unknown",
            "Done: verified"
        ]), [
            "1–2. type: ok", "3. query: ok\nResult",
            "4. type: ok", "   effect: changed", "5. type: ok", "6. type: ok - outcome unknown",
            "Done: verified"
        ])
    }
}

extension GodspeedLeanTests {
    func testCompactRepeatedSuccessesKeepsAnAnnotatedStepSeparate() {
        XCTAssertEqual(BatchTool.compactRepeatedSuccesses([
            "1. type: ok", "2. type: ok", "3. type: ok", "   effect: opened a dialog",
        ]), ["1–2. type: ok", "3. type: ok", "   effect: opened a dialog"])
    }
}
