import XCTest
@testable import OpenComputerUseKit

final class CompactVerifiedReplyTests: XCTestCase {
    func testFinalBrowserImageSuppressesOnlyTheImplicitRead() {
        XCTAssertFalse(BatchTool.needsTrailingBrowserRead(finalStepReturnedImage: true, hasFinalCheck: false,
                                                          explicitState: false, stopped: false))
        XCTAssertTrue(BatchTool.needsTrailingBrowserRead(finalStepReturnedImage: false, hasFinalCheck: false,
                                                         explicitState: false, stopped: false))
        XCTAssertTrue(BatchTool.needsTrailingBrowserRead(finalStepReturnedImage: true, hasFinalCheck: true,
                                                         explicitState: false, stopped: false))
        XCTAssertTrue(BatchTool.needsTrailingBrowserRead(finalStepReturnedImage: true, hasFinalCheck: false,
                                                         explicitState: true, stopped: false))
        XCTAssertTrue(BatchTool.needsTrailingBrowserRead(finalStepReturnedImage: true, hasFinalCheck: false,
                                                         explicitState: false, stopped: true))
    }

    func testExplicitCompactReceiptAggregatesOnlyFullyVerifiedSuccess() throws {
        var receipt = TrajectoryLog.BatchReceipt(totalSteps: 40)
        receipt.doneCheck = .verified
        receipt.steps = Array(repeating: .init(durationMs: 12, deliveryState: .verified), count: 40)
        func metadata(_ receipt: TrajectoryLog.BatchReceipt) throws -> [String: Any] {
            let result = ToolCallResult(content: [.text("Steps 1–40 ok")], isError: false,
                                        batchReceipt: receipt, deliveryState: receipt.deliveryState)
            return try XCTUnwrap((result.asDictionary["_meta"] as? [String: Any])?["godspeed/batch"] as? [String: Any])
        }
        let detailed = try metadata(receipt)
        receipt.wantsCompactMetadata = true
        let compact = try metadata(receipt)
        XCTAssertNil(compact["steps"])
        XCTAssertEqual(compact["step_summary"] as? [String: Int], ["completed": 40, "verified": 40])
        XCTAssertEqual(compact["completion"] as? String, "verified")
        let detailedBytes = try JSONSerialization.data(withJSONObject: detailed).count
        let compactBytes = try JSONSerialization.data(withJSONObject: compact).count
        XCTAssertLessThan(compactBytes * 4, detailedBytes)
        if ProcessInfo.processInfo.environment["GODSPEED_MEASURE_PAYLOADS"] == "1" {
            print("Godspeed 40-step receipt metadata bytes: \(detailedBytes) -> \(compactBytes)")
        }
        receipt.steps[39].deliveryState = .outcomeUnknown
        XCTAssertEqual(try (metadata(receipt)["steps"] as? [[String: Any]])?.count, 40)
    }

    func testCalculatorTimeoutNeedsSameWindowAndFreshExpression() {
        let header = "App=com.apple.calculator (pid 1)\nWindow: Calculator\nWindow ID: 9\n"
        let before = header + "5 text Description: Edit field 48 ÷ 6"
        let after = header + "35 text Description: Last Expression 48 ÷ 6\n5 text Description: Edit field 8"
        XCTAssertTrue(BatchTool.calculatorEqualsApplied(before: before, after: after))
        XCTAssertTrue(DoneCheck.fieldEquals(after, label: "Edit field", value: "8"))
        XCTAssertFalse(DoneCheck.fieldEquals(after, label: "Edit field", value: "6"))
        XCTAssertFalse(BatchTool.calculatorEqualsApplied(before: after, after: after))
        XCTAssertFalse(BatchTool.calculatorEqualsApplied(before: before, after: after.replacingOccurrences(of: "ID: 9", with: "ID: 10")))
        XCTAssertFalse(BatchTool.calculatorEqualsApplied(before: before, after: after.replacingOccurrences(of: "Last Expression 48 ÷ 6", with: "Last Expression 18 ÷ 6")))
    }

    func testCalculatorDisplayCanVerifyAnExactFieldTransition() {
        let header = "App=com.apple.calculator (pid 1)\nWindow ID: 9\n"
        let target = BatchCompletion.Target.native(pid: 1, launch: Date(), window: 9)
        func observation(_ value: String) -> BatchCompletion.Observation {
            BatchCompletion.Observation(target: target,
                screen: header + "5 text Description: Edit field " + value, canProveAbsence: true)
        }

        let checks: [DoneCheck.Condition] = [.field(label: "Edit field", equals: "118")]
        let before = observation("126 − 8")
        let after = observation("118")
        let evidence = DoneCheck.Evidence(screenText: after.screen, pageURL: { nil })
        let transition = BatchCompletion(conditions: checks, startedAt: Date(), before: before)
        XCTAssertEqual(DoneCheck.check(checks, evidence: evidence, baseline: transition, after: after),
                       .verified(met: ["Edit field = 118"]))

        let unchanged = BatchCompletion(conditions: checks, startedAt: Date(), before: after)
        XCTAssertEqual(DoneCheck.check(checks, evidence: evidence, baseline: unchanged, after: after),
                       .weak(met: ["Edit field = 118"]))
        XCTAssertNil(DoneCheck.exactFieldValue(
            "App=com.example.other (pid 1)\n5 text Description: Edit field 118", label: "Edit field"))
    }

    func testVerifiedCompactReplyCollapsesStepsAndDropsEffects() {
        let lines = ["1. click \"Clear\": ok", "   effect: 5 text 12→0", "2. click \"9\": ok", "3. click \"=\": ok",
                     "Done: verified (\"Edit field 6958\" is on screen)", "Saved these steps as the recipe."]
        XCTAssertEqual(BatchTool.compactSuccessfulLines(lines),
                       ["Steps 1–3 ok", "Done: verified (\"Edit field 6958\" is on screen)", "Saved these steps as the recipe."])
    }

    func testCalculatorReceiptKeepsReportedNoEffectAndGroupsRoutineClicks() {
        let noEffect = "1. click \"Clear\": ok - no effect seen"
        let warning = "   Verify the current display before repeating Clear."
        let lines = [
            noEffect, warning,
            "2. click \"8\": ok", "   effect: 12 display 0→8",
            "3. click \"+\": ok", "4. click \"8\": ok",
            "5. click \"=\": ok", "   effect: 12 display 8→16",
        ]
        XCTAssertEqual(BatchTool.compactSuccessfulLines(lines), [noEffect, warning, "Steps 2–5 ok"])
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

    func testVerifiedReplyOmitsTreeEvenWithAnAvailableDiff() {
        let before = "App=X\nWindow: w\nWindow ID: 9\n[w=settable]"
            + (1...30).map { "\n\($0) button Control \($0)" }.joined()
        let after = before.replacingOccurrences(of: "30 button Control 30", with: "30 button Updated")
        let memory = BatchObservationMemory()
        memory.recordShown(app: "X", text: before)

        let result = LeanOutput.batchNativeObservation(
            .text(after), memory: memory, app: "X", allowsDiff: true, compactVerified: true
        )

        XCTAssertTrue(result.textContent.contains("Window list omitted"))
        XCTAssertFalse(result.textContent.contains("30 button Updated"))
        XCTAssertNil(memory.shownText(app: "X"))
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
        XCTAssertEqual(BatchTool.compactSuccessfulLines([
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
