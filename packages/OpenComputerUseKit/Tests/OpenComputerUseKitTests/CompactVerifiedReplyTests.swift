import XCTest
@testable import OpenComputerUseKit

final class CompactVerifiedReplyTests: XCTestCase {
    func testVerifiedCompactReplyCollapsesStepsAndDropsEffects() {
        let lines = ["1. click \"Clear\": ok", "   effect: 5 text 12→0", "2. click \"9\": ok", "3. click \"=\": ok",
                     "Done: verified (\"Edit field 6958\" is on screen)", "Saved these steps as the recipe."]
        XCTAssertEqual(BatchTool.compactVerifiedLines(lines),
                       ["Steps 1–3 ok", "Done: verified (\"Edit field 6958\" is on screen)", "Saved these steps as the recipe."])
    }

    func testHeaderOnlyKeepsAppAndWindow() {
        let state = "App=com.apple.calculator (pid 1)\nWindow: \"Calculator\", App: Calculator.\nWindow ID: 9\n[w=settable]\n0 standard window Calculator"
            + (1...9).map { "\n\($0) button \($0)" }.joined()
        let result = LeanOutput.headerOnly(ToolCallResult(content: [.text(state)]))
        let text = result.content.first?.dictionary["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("App=com.apple.calculator"), text)
        XCTAssertFalse(text.contains("standard window"), text)
    }

    func testSmallStateKeepsTheShorterFullReply() {
        let before = "App=X\nWindow: w\nWindow ID: 9\n1 button Save\n2 button Cancel"
        let after = before + "\n3 button New"
        let result = LeanOutput.diffed(.text(after), previous: before)
        XCTAssertEqual(result.textContent, after)
    }

    func testStateOmittedForVerifiedGoalIsNeverUsedAsDiffBaseline() {
        let state = "App=X\nWindow: w\nWindow ID: 9\n[w=settable]"
            + (1...12).map { "\n\($0) button Control \($0)" }.joined()
        let result = ToolCallResult.text(state)
        let memory = BatchObservationMemory()
        let compact = LeanOutput.batchNativeObservation(result, memory: memory, app: "X", allowsDiff: true, compactVerified: true)
        XCTAssertTrue(compact.textContent.contains("Window list omitted"))
        XCTAssertNil(memory.shownText(app: "X"))

        let next = LeanOutput.batchNativeObservation(result, memory: memory, app: "X", allowsDiff: true, compactVerified: false)
        XCTAssertEqual(next.textContent, state)
        XCTAssertEqual(memory.shownText(app: "X"), state)
    }

    func testVerifiedWindowFixtureShrinksFirstReply() {
        let state = "App=Example\nWindow: Preferences\nWindow ID: 9\n[w=settable]"
            + (1...80).map { "\n\($0) button Preference \($0)" }.joined()
        let observation = ToolCallResult.text(state)
        let compact = LeanOutput.batchNativeObservation(
            observation, memory: BatchObservationMemory(), app: "Example", allowsDiff: true, compactVerified: true
        )
        XCTAssertLessThan(compact.textContent.utf8.count, state.utf8.count / 10)
        XCTAssertTrue(compact.textContent.contains("Window ID: 9"))
    }

    func testVerifiedSummaryKeepsUncertainStepsAndWindowNotesInOrder() {
        let note = "   windows: now \"Other\", not the window this batch started in"
        let uncertain = "2. click \"Save\": ok - no effect seen"
        let done = "Done: verified (\"Saved\" is on screen)"
        XCTAssertEqual(BatchTool.compactVerifiedLines([
            "1. click \"Open\": ok", uncertain, note, "3. click \"OK\": ok", done,
        ]), ["Step 1 ok", uncertain, note, "Step 3 ok", done])
    }

    func testObservationOnlyAliasesDontCountAsMutations() {
        let steps: [BatchTool.Step] = [
            .init(tool: "get_app_state", arguments: [:]),
            .init(tool: "wait", arguments: [:]),
            .init(tool: "browser", arguments: ["action": " Page_Info "]),
            .init(tool: "browser", arguments: ["action": "wait_for_text"]),
            .init(tool: "clipboard", arguments: ["action": "read"]),
            .init(tool: "browser", arguments: ["action": "click"]),
            .init(tool: "clipboard", arguments: ["action": "write"]),
        ]
        XCTAssertEqual(steps.map(\.isReadOnly), [true, true, true, true, true, false, false])
    }
}
