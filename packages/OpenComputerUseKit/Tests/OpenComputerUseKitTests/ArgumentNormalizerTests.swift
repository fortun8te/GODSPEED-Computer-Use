import Dispatch
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for argument forgiveness. Nothing here touches accessibility or the screen:
/// corrective-error cases fail before any tool runs.
final class ArgumentNormalizerTests: XCTestCase {
    private func normalize(_ tool: String, _ arguments: [String: Any], lastApp: String? = nil) -> [String: Any] {
        ArgumentNormalizer.normalize(tool: tool, arguments: arguments, lastApp: lastApp)
    }

    // MARK: - Alias families

    func testElementNameAliasesBecomeLabel() {
        for key in ["element", "target", "name", "element_name", "visible_name"] {
            let out = normalize("click", ["app": "Notes", key: "Send"])
            XCTAssertEqual(out["label"] as? String, "Send", key)
            XCTAssertNil(out[key], "\(key) is consumed")
        }
    }

    func testTextForClickBecomesLabel() {
        let out = normalize("click", ["app": "Notes", "text": "Send"])
        XCTAssertEqual(out["label"] as? String, "Send")
        XCTAssertNil(out["text"])
    }

    func testNumericElementNameBecomesElementIndex() {
        let out = normalize("click", ["app": "Notes", "element": 12])
        XCTAssertEqual(out["element_index"] as? String, "12")
        XCTAssertNil(out["label"])
    }

    func testElementNumberAliasesBecomeElementIndex() {
        for key in ["index", "id", "element_id", "elementId", "elementIndex", "idx", "element_number"] {
            let out = normalize("set_value", ["app": "Notes", key: "14", "value": "x"])
            XCTAssertEqual(out["element_index"] as? String, "14", key)
            XCTAssertNil(out[key], key)
        }
    }

    func testNonNumericIdBecomesLabel() {
        let out = normalize("click", ["app": "Notes", "id": "send-button"])
        XCTAssertEqual(out["label"] as? String, "send-button")
        XCTAssertNil(out["element_index"])
    }

    func testHashedElementIndexLosesTheHash() {
        let out = normalize("scroll", ["app": "Notes", "element_index": "#12", "direction": "down"])
        XCTAssertEqual(out["element_index"] as? String, "12")
    }

    func testBrowserIndexAliasesBecomeIntegerIndex() {
        let out = normalize("browser", ["action": "click", "element_index": "3"])
        XCTAssertEqual(out["index"] as? Int, 3)
        XCTAssertNil(out["element_index"])
    }

    func testLabelListBecomesLabels() {
        let out = normalize("click", ["app": "Calculator", "label": ["+", "add"]])
        XCTAssertEqual(out["labels"] as? [String], ["+", "add"])
        XCTAssertNil(out["label"])
    }

    func testKeyAliasesBecomeKey() {
        for key in ["keys", "shortcut", "combo", "hotkey", "combination", "press"] {
            let out = normalize("press_key", ["app": "Notes", key: "cmd+s"])
            XCTAssertEqual(out["key"] as? String, "super+s", key)
            XCTAssertNil(out[key], key)
        }
    }

    func testContentAndValueBecomeTypedText() {
        for key in ["content", "value", "input"] {
            let out = normalize("type_text", ["app": "Notes", key: "hello"])
            XCTAssertEqual(out["text"] as? String, "hello", key)
        }
    }

    func testTextBecomesSetValue() {
        let out = normalize("set_value", ["app": "Notes", "label": "Title", "text": "Hi"])
        XCTAssertEqual(out["value"] as? String, "Hi")
        XCTAssertNil(out["text"])
    }

    func testMenuItemAliasesBecomePath() {
        for key in ["menu", "item", "label", "labels"] {
            let out = normalize("press_menu", ["app": "TextEdit", key: "File > Save"])
            XCTAssertEqual(out["path"] as? String, "File > Save", key)
        }
    }

    func testMenuPathArrayIsKept() {
        let out = normalize("press_menu", ["app": "TextEdit", "label": ["File", "Save"]])
        XCTAssertEqual(out["path"] as? [String], ["File", "Save"])
    }

    func testAppAliasesBecomeApp() {
        for key in ["application", "app_name", "appName", "bundle_id", "bundleId", "target_app"] {
            let out = normalize("press_key", [key: "Notes", "key": "Return"])
            XCTAssertEqual(out["app"] as? String, "Notes", key)
            XCTAssertNil(out[key], key)
        }
    }

    func testDirAliasBecomesDirection() {
        let out = normalize("scroll", ["app": "Notes", "element_index": "4", "dir": "down"])
        XCTAssertEqual(out["direction"] as? String, "down")
        XCTAssertNil(out["dir"])
    }

    func testScrollAmountAliasesBecomePages() {
        for key in ["amount", "count", "times", "page"] {
            let out = normalize("scroll", ["app": "Notes", "element_index": "4", "direction": "down", key: "3"])
            XCTAssertEqual(out["pages"] as? Double, 3, key)
        }
    }

    func testClickCountAliasesBecomeClickCount() {
        for key in ["clicks", "count", "times"] {
            let out = normalize("click", ["app": "Notes", "label": "Ok", key: 2])
            XCTAssertEqual(out["click_count"] as? Int, 2, key)
        }
    }

    func testClickFlagsSetButtonAndCount() {
        let right = normalize("click", ["app": "Notes", "label": "Ok", "right_click": true])
        XCTAssertEqual(right["mouse_button"] as? String, "right")
        let double = normalize("click", ["app": "Notes", "label": "Ok", "double_click": "yes"])
        XCTAssertEqual(double["click_count"] as? Int, 2)
    }

    func testButtonWordIsMouseButtonAndOtherWordIsLabel() {
        let word = normalize("click", ["app": "Notes", "button": "Right"])
        XCTAssertEqual(word["mouse_button"] as? String, "right")
        XCTAssertNil(word["label"])
        let name = normalize("click", ["app": "Notes", "button": "Send"])
        XCTAssertEqual(name["label"] as? String, "Send")
    }

    func testDragPointObjectsAndCoordinateAliases() {
        let object = normalize("drag", ["app": "Notes", "from": ["x": 10, "y": 20], "to": ["x": "30", "y": 40]])
        XCTAssertEqual(object["from_x"] as? Double, 10)
        XCTAssertEqual(object["from_y"] as? Double, 20)
        XCTAssertEqual(object["to_x"] as? Double, 30)
        XCTAssertEqual(object["to_y"] as? Double, 40)
        XCTAssertNil(object["from"])

        let pairs = normalize("drag", ["app": "Notes", "x1": 1, "y1": 2, "x2": 3, "y2": 4])
        XCTAssertEqual(pairs["from_x"] as? Double, 1)
        XCTAssertEqual(pairs["to_y"] as? Double, 4)
    }

    func testBatchActionsAliasStepsAndScreenshotAliasWorks() {
        let batch = normalize("batch", ["actions": [["tool": "click", "label": "Send"]]])
        XCTAssertNotNil(batch["steps"] as? [Any])
        let state = normalize("get_app_state", ["app": "Notes", "screenshot": "yes"])
        XCTAssertEqual(state["include_screenshot"] as? Bool, true)
    }

    func testBrowserOperationAliasBecomesAction() {
        let out = normalize("browser", ["operation": "go", "href": "example.com"])
        XCTAssertEqual(out["action"] as? String, "go")
        XCTAssertEqual(out["url"] as? String, "example.com")
    }

    func testCanonicalNameWinsOverAlias() {
        let out = normalize("type_text", ["app": "Notes", "text": "real", "content": "alias"])
        XCTAssertEqual(out["text"] as? String, "real")
    }

    func testUnknownToolOnlyGetsGenericTreatment() {
        let out = normalize("no_such_tool", ["label": "\"Send\""])
        XCTAssertEqual(out["label"] as? String, "Send")
        XCTAssertNil(out["app"])
    }

    // MARK: - Coercion

    func testNumericStringsBecomeIntegers() {
        let out = normalize("click", ["app": "Notes", "label": "Ok", "click_count": "2"])
        XCTAssertEqual(out["click_count"] as? Int, 2)
        let limit = normalize("query", ["app": "Notes", "text": "x", "limit": "12"])
        XCTAssertEqual(limit["limit"] as? Int, 12)
    }

    func testCoordinatesBecomeDoubles() {
        let out = normalize("click", ["app": "Notes", "x": "120", "y": " 45.5 "])
        XCTAssertEqual(out["x"] as? Double, 120)
        XCTAssertEqual(out["y"] as? Double, 45.5)
        XCTAssertEqual(normalize("click", ["app": "Notes", "x": "120px"])["x"] as? Double, 120)
    }

    func testBooleanWordsBecomeBooleans() {
        for word in ["true", "yes", "on", "1", "Y"] {
            XCTAssertEqual(normalize("get_app_state", ["app": "A", "include_ax": word])["include_ax"] as? Bool, true, word)
        }
        for word in ["false", "no", "off", "0", "N"] {
            XCTAssertEqual(normalize("get_app_state", ["app": "A", "include_ax": word])["include_ax"] as? Bool, false, word)
        }
        XCTAssertEqual(normalize("batch", ["steps": [], "remember": 1])["remember"] as? Bool, true)
        XCTAssertEqual(normalize("query", ["app": "A", "text": "x", "exact": "TRUE"])["exact"] as? Bool, true)
    }

    func testUnreadableBooleanIsLeftAlone() {
        let out = normalize("query", ["app": "A", "text": "x", "exact": "maybe"])
        XCTAssertEqual(out["exact"] as? String, "maybe")
    }

    func testNumbersBecomeStringsWhereAStringIsExpected() {
        let out = normalize("type_text", ["app": "Calculator", "text": 42])
        XCTAssertEqual(out["text"] as? String, "42")
        let flag = normalize("type_text", ["app": "Calculator", "text": true])
        XCTAssertEqual(flag["text"] as? String, "true")
        let index = normalize("select_text", ["app": "Notes", "element_index": 14, "text": "x"])
        XCTAssertEqual(index["element_index"] as? String, "14")
    }

    func testTypedTextKeepsItsSpaces() {
        let out = normalize("type_text", ["app": "Notes", "text": "  hi  "])
        XCTAssertEqual(out["text"] as? String, "  hi  ")
    }

    func testEnumValuesAreLowercased() {
        let out = normalize("scroll", ["app": "Notes", "element_index": "4", "direction": " DOWN "])
        XCTAssertEqual(out["direction"] as? String, "down")
        XCTAssertEqual(normalize("scroll", ["app": "Notes", "direction": "page down"])["direction"] as? String, "down")
        XCTAssertEqual(normalize("click", ["app": "Notes", "label": "Ok", "mouse_button": "Right"])["mouse_button"] as? String, "right")
        XCTAssertEqual(normalize("get_app_state", ["app": "Notes", "text_limit": "Max"])["text_limit"] as? String, "max")
    }

    func testSidewaysDirectionIsLeftForTheDispatcherToRefuse() {
        XCTAssertEqual(normalize("scroll", ["app": "Notes", "direction": "Sideways"])["direction"] as? String, "sideways")
    }

    func testLabelQuotesAreStripped() {
        for raw in ["\"Send\"", "'Send'", "“Send”", "  Send  ", "`Send`"] {
            XCTAssertEqual(normalize("click", ["app": "Notes", "label": raw])["label"] as? String, "Send", raw)
        }
        XCTAssertEqual(normalize("click", ["app": "Notes", "labels": ["\"+\"", "add"]])["labels"] as? [String], ["+", "add"])
    }

    func testAppQuotesAreStripped() {
        XCTAssertEqual(normalize("press_key", ["app": "\"Notes\"", "key": "Return"])["app"] as? String, "Notes")
    }

    // MARK: - Key names

    func testKeySpellingsBecomeXdotoolCombos() {
        let cases: [(String, String)] = [
            ("CMD+S", "super+s"),
            ("Command-S", "super+s"),
            ("cmd s", "super+s"),
            ("⌘S", "super+s"),
            ("⌘⇧Z", "super+shift+z"),
            ("Ctrl+Shift+Z", "ctrl+shift+z"),
            ("option+Left", "alt+Left"),
            ("shift+tab", "shift+Tab"),
            ("cmd+-", "super+-"),
            ("cmd++", "super++"),
            ("A", "a"),
            ("F1", "f1"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ArgumentNormalizer.normalizeKey(raw), expected, raw)
        }
    }

    func testNamedKeysGetTheirCanonicalNames() {
        let cases: [(String, String)] = [
            ("enter", "Return"),
            ("Return", "Return"),
            ("esc", "Escape"),
            ("escape", "Escape"),
            ("backspace", "BackSpace"),
            ("arrowdown", "Down"),
            ("space", "space"),
            ("Tab", "Tab"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ArgumentNormalizer.normalizeKey(raw), expected, raw)
        }
    }

    func testLoneSignKeysAreKept() {
        XCTAssertEqual(ArgumentNormalizer.normalizeKey("-"), "-")
        XCTAssertEqual(ArgumentNormalizer.normalizeKey("+"), "+")
    }

    func testPressKeyNormalisesTheKeyArgument() {
        XCTAssertEqual(normalize("press_key", ["app": "Notes", "key": "CMD+S"])["key"] as? String, "super+s")
        XCTAssertEqual(normalize("press_key", ["app": "Notes", "key": ["cmd", "s"]])["key"] as? String, "super+s")
    }

    func testBrowserKeysAreNotRewritten() {
        XCTAssertEqual(normalize("browser", ["action": "key", "key": "Enter"])["key"] as? String, "Enter")
    }

    // MARK: - Last app

    func testMissingAppIsFilledFromLastApp() {
        let out = normalize("press_key", ["key": "cmd+s"], lastApp: "Notes")
        XCTAssertEqual(out["app"] as? String, "Notes")
    }

    func testEmptyAppIsFilledFromLastApp() {
        let out = normalize("click", ["app": "", "label": "Send"], lastApp: "Mail")
        XCTAssertEqual(out["app"] as? String, "Mail")
    }

    func testNamedAppIsKeptOverLastApp() {
        let out = normalize("click", ["app": "Mail", "label": "Send"], lastApp: "Notes")
        XCTAssertEqual(out["app"] as? String, "Mail")
    }

    func testNoAppIsGuessedWithoutLastApp() {
        XCTAssertNil(normalize("press_key", ["key": "cmd+s"], lastApp: nil)["app"])
    }

    func testBrowserAndBatchNeverGetAppFilled() {
        XCTAssertNil(normalize("browser", ["action": "read"], lastApp: "Notes")["app"])
        XCTAssertNil(normalize("batch", ["steps": [["tool": "click", "label": "Send"]]], lastApp: "Notes")["app"])
    }

    func testRecentAppMemoryKeepsTheLatestNonEmptyName() {
        let memory = RecentAppMemory()
        XCTAssertNil(memory.current)
        memory.remember("Notes")
        memory.remember("   ")
        XCTAssertEqual(memory.current, "Notes")
        memory.remember(" Mail ")
        XCTAssertEqual(memory.current, "Mail")
    }

    func testRecentAppMemoryIsSafeAcrossThreads() {
        let memory = RecentAppMemory()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            memory.remember("App \(index)")
            _ = memory.current
        }
        XCTAssertTrue(memory.current?.hasPrefix("App ") == true)
    }

    // MARK: - Corrective errors

    func testMissingKeyGivesOneCorrectiveLine() {
        XCTAssertEqual(
            ArgumentNormalizer.problem(tool: "press_key", arguments: ["app": "Notes"]),
            "press_key needs \"key\", e.g. \"cmd+s\". Example: press_key {\"app\": \"Notes\", \"key\": \"cmd+s\"}"
        )
    }

    func testMissingAppWithoutLastAppUsesAPlaceholder() {
        XCTAssertEqual(
            ArgumentNormalizer.problem(tool: "click", arguments: ["label": "Send"]),
            "click needs \"app\" (the app name). Example: click {\"app\": \"<app name>\", \"label\": \"Send\"}"
        )
    }

    func testClickNeedsLabelIndexOrCoordinates() {
        let message = ArgumentNormalizer.problem(tool: "click", arguments: ["app": "Notes"])
        XCTAssertEqual(
            message,
            "click needs \"label\" (its visible name), \"element_index\", or \"x\" and \"y\". Example: click {\"app\": \"Notes\", \"label\": \"Send\"}"
        )
        XCTAssertNil(ArgumentNormalizer.problem(tool: "click", arguments: ["app": "Notes", "x": 1.0]))
    }

    func testSetValueMayBeEmptyButNotAbsent() {
        XCTAssertNil(ArgumentNormalizer.problem(tool: "set_value", arguments: ["app": "Notes", "label": "Title", "value": ""]))
        XCTAssertNotNil(ArgumentNormalizer.problem(tool: "set_value", arguments: ["app": "Notes", "label": "Title"]))
    }

    func testEmptyTextIsMissing() {
        let message = ArgumentNormalizer.problem(tool: "type_text", arguments: ["app": "Notes", "text": ""])
        XCTAssertEqual(message, "type_text needs \"text\" (what to type). Example: type_text {\"app\": \"Notes\", \"text\": \"hello\"}")
    }

    func testCorrectionKeepsWhatTheCallerAlreadyGave() {
        XCTAssertEqual(
            ArgumentNormalizer.problem(tool: "set_value", arguments: ["app": "Notes", "label": "Subject"]),
            "set_value needs \"value\" (may be empty to clear). Example: set_value {\"app\": \"Notes\", \"label\": \"Subject\", \"value\": \"Hello\"}"
        )
        let drag = ArgumentNormalizer.problem(tool: "drag", arguments: ["app": "Notes", "from_x": 5.0, "from_y": 6.0, "to_x": 7.0])
        XCTAssertTrue(drag?.contains("\"from_x\": 5, \"from_y\": 6, \"to_x\": 7") == true, drag ?? "")
    }

    func testBatchNeedsStepsOrGoal() {
        XCTAssertNotNil(ArgumentNormalizer.problem(tool: "batch", arguments: [:]))
        XCTAssertNil(ArgumentNormalizer.problem(tool: "batch", arguments: ["goal": "Send the note"]))
    }

    func testEveryCorrectionIsOneLineWithAValidExample() throws {
        let tools = [
            "get_app_state", "query", "click", "drag", "type_text", "press_key", "press_menu",
            "set_value", "scroll", "select_text", "perform_secondary_action", "browser", "batch",
        ]
        for tool in tools {
            let message = try XCTUnwrap(ArgumentNormalizer.problem(tool: tool, arguments: [:]), tool)
            XCTAssertFalse(message.contains("\n"), tool)
            XCTAssertTrue(message.hasPrefix("\(tool) needs "), tool)
            let marker = "Example: \(tool) "
            let range = try XCTUnwrap(message.range(of: marker), tool)
            let json = String(message[range.upperBound...])
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            XCTAssertTrue(object is [String: Any], tool)
        }
    }

    func testAnswerFromTheDispatcherIsTheCorrection() {
        let result = ComputerUseToolDispatcher().callToolAsResult(name: "press_key", arguments: ["app": "Notes"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(
            result.primaryText,
            "press_key needs \"key\", e.g. \"cmd+s\". Example: press_key {\"app\": \"Notes\", \"key\": \"cmd+s\"}"
        )
    }

    func testCompleteCallHasNoProblem() {
        XCTAssertNil(ArgumentNormalizer.problem(tool: "press_key", arguments: ["app": "Notes", "key": "Return"]))
        XCTAssertNil(ArgumentNormalizer.problem(tool: "list_apps", arguments: [:]))
        XCTAssertNil(ArgumentNormalizer.problem(tool: "unknown_tool", arguments: [:]))
    }

    // MARK: - Browser url-only visits

    func testBrowserUrlWithoutActionIsAGo() {
        XCTAssertEqual(normalize("browser", ["url": "example.com"])["action"] as? String, "go")
        XCTAssertNil(ArgumentNormalizer.problem(tool: "browser", arguments: normalize("browser", ["url": "example.com"])))
        XCTAssertEqual(normalize("browser", ["action": "read", "url": "x.com"])["action"] as? String, "read")
    }
}
