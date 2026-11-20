import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class BatchReviewR2Tests: XCTestCase {
    private func state(_ rows: [String], title: String = "Untitled") -> String {
        (["App=com.example (pid 1)", "Window: \"\(title)\", App: Example.", "[legend]"] + rows).joined(separator: "\n")
    }

    // Window continuity

    func testTitleChangeAfterSaveInSameWindowDoesNotMove() {
        let bound = BatchEffects.windowSig(state: state(["\t1 button Save"], title: "Untitled"), id: 7)
        let now = BatchEffects.windowSig(state: state(["\t1 button Save"], title: "notes.txt"), id: 7)
        XCTAssertEqual(BatchEffects.compare(bound: bound, now: now), .same)
    }

    func testTitleChangeWithoutWindowIDsDoesNotStopTheBatch() {
        let bound = BatchEffects.windowSig(state: state([], title: "Untitled"), id: nil)
        let now = BatchEffects.windowSig(state: state([], title: "notes.txt"), id: nil)
        XCTAssertEqual(BatchEffects.compare(bound: bound, now: now), .same)
    }

    func testSheetOpenedByTheStepIsFollowedAndAnotherWindowStops() {
        let bound = BatchEffects.windowSig(state: state(["\t1 button Save"]), id: 7)
        let sheet = BatchEffects.windowSig(state: state(["\t1 button Save", "\t2 sheet Save", "\t\t3 button Cancel"]), id: 7)
        XCTAssertEqual(BatchEffects.compare(bound: bound, now: sheet), .dialog("windows: opened \"Save\" (sheet)"))
        let other = BatchEffects.windowSig(state: state([], title: "Other"), id: 9)
        XCTAssertEqual(BatchEffects.compare(bound: bound, now: other), .moved("Other"))
    }

    // Wait budget

    func testWaitNeverPollsPastTheBatchBudget() throws {
        let wait = try BatchEffects.Wait(arguments: ["window": "Export", "timeout_ms": 30_000])
        XCTAssertEqual(wait.pollSeconds(elapsedInBatch: 0, budget: 75), 30, accuracy: 0.001)
        XCTAssertEqual(wait.pollSeconds(elapsedInBatch: 60, budget: 75), 15, accuracy: 0.001)
        XCTAssertEqual(wait.pollSeconds(elapsedInBatch: 75, budget: 75), 0)
        XCTAssertEqual(wait.pollSeconds(elapsedInBatch: 80, budget: 75), 0)
    }

    // Receipts

    func testGenericFailuresStayUncertainDespitePhrases() {
        let result = ToolCallResult.failure(ComputerUseError.message("no text was sent. Example: retry"))
        XCTAssertEqual(result.deliveryState, .outcomeUnknown)
        XCTAssertEqual(result.deliveryState.safeRetry, .reconcileFirst)
    }

    // Numbering

    func testRelaunchedAppNeverReusesOldNumbers() {
        let saved = ElementNumbering.isProcessAlive
        defer { ElementNumbering.isProcessAlive = saved }
        var alive: Set<pid_t> = [100, 200]
        ElementNumbering.isProcessAlive = { alive.contains($0) }

        let agent = ElementNumbering.PerAgent()
        let old = agent.numbering(for: 100)
        old.beginSnapshot()
        for pid in 1...5 { _ = old.number(for: AXUIElementCreateApplication(pid_t(pid)), role: "AXButton") }
        old.endSnapshot()
        XCTAssertEqual(old.highWater, 5)
        XCTAssertTrue(agent.numbering(for: 100) === old)

        // The app quits and comes back under a new pid: its numbers start above everything it had shown.
        alive = [200, 300]
        let relaunched = agent.numbering(for: 300)
        XCTAssertEqual(relaunched.highWater, 5)
        relaunched.beginSnapshot()
        XCTAssertEqual(relaunched.number(for: AXUIElementCreateApplication(1), role: "AXButton"), 5)
        XCTAssertFalse(agent.numbering(for: 100) === old, "the dead app's registry was dropped")
    }

    // Condenser

    func testRowsHoldingOnlyACheckboxAreNeverFolded() {
        var lines = ["0 window Settings"]
        for i in 1...14 { lines.append("\t\(i) row\n\t\t\(100 + i) checkbox Option \(i) = 0") }
        let output = AXTreeCondenser.condense(lines.joined(separator: "\n"))
        for i in 1...14 { XCTAssertTrue(output.contains("checkbox Option \(i) "), "option \(i) lost") }
        XCTAssertFalse(output.contains("more row"))
    }

    func testTextFieldValueAndLoneButtonSurvive() {
        let input = [
            "App=x (pid 1)", "Window: \"W\", App: X.", "[legend]",
            "0 window W", "\t1 group", "\t\t2 group", "\t\t\t3 text field Name = Ada Lovelace (settable)", "\t\t\t4 button Done",
        ].joined(separator: "\n")
        let output = AXTreeCondenser.condense(input)
        XCTAssertTrue(output.contains("3 text field Name = Ada Lovelace"))
        XCTAssertTrue(output.contains("4 button Done"))
    }
}
