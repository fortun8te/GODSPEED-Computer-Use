import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class BatchEffectsTests: XCTestCase {
    func testWaitTimeoutFromHugeOrNonFiniteSecondsIsClampedNotTrapped() throws {
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["window": "Save", "timeout_s": 1e30]).timeoutMs, BatchEffects.Wait.maxTimeoutMs)
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["window": "Save", "timeout_s": -1e30]).timeoutMs, 100)
        XCTAssertEqual(try BatchEffects.Wait(arguments: ["window": "Save", "timeout_s": 2]).timeoutMs, 2_000)
        XCTAssertThrowsError(try BatchEffects.Wait(arguments: ["window": "Save", "timeout_s": "nan"]))
        XCTAssertThrowsError(try BatchEffects.Wait(arguments: ["window": "Save", "timeout_s": "inf"]))
    }

    private func state(_ rows: [String], title: String = "Settings") -> String {
        (["App=com.example (pid 1)", "Window: \"\(title)\", App: Example.", "[legend]"] + rows).joined(separator: "\n")
    }

    func testWaitPollsCheaplyAndTakesOneFullReadOnReadiness() {
        var gate = BatchEffects.WaitReadGate(nextFullRead: 0.75)
        var probes = 0
        var fullReads = 0
        for time in [0.0, 0.2, 0.4] {
            if gate.shouldRead(at: time, probe: {
                probes += 1
                return time == 0.4
            }) { fullReads += 1 }
        }
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(fullReads, 1)
    }

    func testWaitStillTakesFullReadOnUnknownOrAtFallbackDeadline() {
        var gate = BatchEffects.WaitReadGate(nextFullRead: 0.75)
        XCTAssertTrue(gate.shouldRead(at: 0.2) { nil })
        XCTAssertFalse(gate.shouldRead(at: 0.5) { false })
        XCTAssertTrue(gate.shouldRead(at: 0.95) { false })
    }

    func testReusesChangedWindowEvidenceOnlyWithCompleteMatchingScope() {
        let head = "App=test.app (pid 42)\nWindow: \"Editor\", App: Test.\nWindow ID: 17\n"
        let before = head + "1 text field Title = old"
        let after = head + "1 text field Title = new"
        XCTAssertEqual(BatchEffects.Watch.reusableSignature(before: before, after: after, id: 17)?.id, 17)
        XCTAssertNil(BatchEffects.Watch.reusableSignature(before: before, after: before, id: 17))
        XCTAssertNil(BatchEffects.Watch.reusableSignature(before: before, after: after, id: 18))
        XCTAssertNil(BatchEffects.Watch.reusableSignature(before: before, after: after.replacingOccurrences(of: "42", with: "43"), id: 17))
        XCTAssertNil(BatchEffects.Watch.reusableSignature(before: before, after: after + "\n2 sheet Save", id: 17))
        XCTAssertNil(BatchEffects.Watch.reusableSignature(before: before, after: after + "\n[Accessibility tree truncated: omitted]", id: 17))
    }

    func testCheckboxChangeReadsAsOldToNew() {
        var gone = Set<Int>()
        let lines = BatchEffects.effectLines(
            before: state(["\t11 button Save", "\t12 checkbox Interface = 0"]),
            after: state(["\t11 button Save", "\t12 checkbox Interface = 1"]),
            reportedGone: &gone
        )
        XCTAssertEqual(lines, ["effect: 12 checkbox Interface = 0→1"])
    }

    func testNoVisibleChange() {
        var gone = Set<Int>()
        let rows = ["\t1 button Save Secondary Actions: Press", "\t2 text Hello"]
        XCTAssertEqual(BatchEffects.effectLines(before: state(rows), after: state(rows), reportedGone: &gone), ["no visible change"])
        // A moved frame alone is not a change.
        let moved = BatchEffects.effectLines(
            before: state(["\t1 button Go Frame: x=1, y=2, w=3, h=4"]),
            after: state(["\t1 button Go Frame: x=9, y=2, w=3, h=4"]),
            reportedGone: &gone
        )
        XCTAssertEqual(moved, ["no visible change"])
    }

    func testNewAndGoneElementsAreListedOnce() {
        var gone = Set<Int>()
        let first = BatchEffects.effectLines(
            before: state(["\t1 button A", "\t2 button B"]),
            after: state(["\t1 button A", "\t3 button C"]),
            reportedGone: &gone
        )
        XCTAssertEqual(first, ["new: 3 button C", "gone: 2 button B"])
        // Still gone in the next step: not named again.
        let second = BatchEffects.effectLines(
            before: state(["\t1 button A", "\t3 button C"]),
            after: state(["\t1 button A"]),
            reportedGone: &gone
        )
        XCTAssertEqual(second, ["gone: 3 button C"])
        let third = BatchEffects.effectLines(before: state(["\t1 button A"]), after: state(["\t1 button A"]), reportedGone: &gone)
        XCTAssertEqual(third, ["no visible change"])
    }

    func testBigRedrawIsOneLine() {
        var gone = Set<Int>()
        let before = state((0..<20).map { "\t\($0) text row \($0)" })
        let after = state((100..<120).map { "\t\($0) text row \($0)" })
        let lines = BatchEffects.effectLines(before: before, after: after, reportedGone: &gone)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("screen changed a lot"), lines[0])
    }

    func testWindowVerdicts() {
        let plain = BatchEffects.windowSig(state: state(["\t1 button A"]), id: 10)
        let withSheet = BatchEffects.windowSig(state: state(["\t1 button A", "\t2 sheet Save", "\t3 button Cancel"], title: "Save"), id: 11)
        XCTAssertEqual(withSheet.dialog, "sheet Save")
        XCTAssertEqual(BatchEffects.compare(bound: plain, now: plain), .same)
        XCTAssertEqual(BatchEffects.compare(bound: plain, now: withSheet), .dialog("windows: opened \"Save\" (sheet)"))
        XCTAssertEqual(BatchEffects.compare(bound: withSheet, now: plain), .dialog("windows: closed \"Save\" (sheet)"))
        // Same window id, new title (a document renamed itself): still the same window.
        var renamed = plain
        renamed.title = "Untitled 2"
        XCTAssertEqual(BatchEffects.compare(bound: plain, now: renamed), .same)
        // Another window id with no dialog change: the batch has left its window.
        let other = BatchEffects.WindowSig(id: 99, title: "Other", dialog: nil)
        XCTAssertEqual(BatchEffects.compare(bound: plain, now: other), .moved("Other"))
        // Without ids a title change is not proof (saving renames "Untitled" to "notes.txt"): stay.
        let noID = BatchEffects.WindowSig(id: nil, title: "Settings", dialog: nil)
        XCTAssertEqual(BatchEffects.compare(bound: noID, now: BatchEffects.WindowSig(id: nil, title: "Other", dialog: nil)), .same)
    }

    func testWindowTitleParsing() {
        XCTAssertEqual(BatchEffects.windowTitle(in: state([], title: "My \"Doc\"")), "My \"Doc\"")
        XCTAssertEqual(BatchEffects.dialog(in: state(["\t4 dialog (modal) Export As: Secondary Actions: Press"])), "dialog Export As:")
    }

    func testWaitConditions() throws {
        XCTAssertThrowsError(try BatchEffects.Wait(arguments: [:]))
        var window = try BatchEffects.Wait(arguments: ["window": "export"])
        XCTAssertFalse(window.isMet(state: state(["\t1 button A"])))
        XCTAssertTrue(window.isMet(state: state(["\t2 sheet Export"], title: "Export")))
        var text = try BatchEffects.Wait(arguments: ["text": "done", "timeout_ms": 999_999])
        XCTAssertEqual(text.timeoutMs, BatchEffects.Wait.maxTimeoutMs)
        XCTAssertTrue(text.isMet(state: state(["\t1 text Done!"])))
        var gone = try BatchEffects.Wait(arguments: ["gone": "Loading"])
        XCTAssertFalse(gone.isMet(state: state(["\t1 text Loading"])))
        XCTAssertTrue(gone.isMet(state: state(["\t1 text Ready"])))

        var settle = try BatchEffects.Wait(arguments: ["settle": true])
        let start = Date()
        let rows = state(["\t1 text Same"])
        XCTAssertFalse(settle.isMet(state: rows, now: start))
        XCTAssertFalse(settle.isMet(state: rows, now: start.addingTimeInterval(0.2)))
        XCTAssertTrue(settle.isMet(state: rows, now: start.addingTimeInterval(0.6)))
        // A change restarts the quiet period.
        XCTAssertFalse(settle.isMet(state: state(["\t1 text Other"]), now: start.addingTimeInterval(0.7)))
        XCTAssertFalse(settle.isMet(state: state(["\t1 text Other"]), now: start.addingTimeInterval(0.9)))
    }

    func testWaitStepParsesAndBatchAllows40Steps() throws {
        let steps = try BatchTool.parseSteps([["tool": "wait", "window": "Save", "timeout_ms": 2000]], defaultApp: "Notes")
        XCTAssertEqual(steps.first?.tool, "wait")
        XCTAssertEqual(steps.first?.arguments["app"] as? String, "Notes")
        XCTAssertEqual(BatchTool.describe(try XCTUnwrap(steps.first)), "wait window \"Save\"")
        // A bare wait is a short pause (settle), not an error.
        XCTAssertEqual(try BatchTool.parseSteps([["tool": "wait"]], defaultApp: "Notes").first?.arguments["settle"] as? Bool, true)
        let forty = Array(repeating: ["tool": "press_key", "key": "Down"] as [String: Any], count: 40)
        XCTAssertEqual(try BatchTool.parseSteps(forty, defaultApp: "Notes").count, 40)
        XCTAssertThrowsError(try BatchTool.parseSteps(forty + forty.prefix(1), defaultApp: "Notes"))
    }
}

final class ElementNumberingTests: XCTestCase {
    func testNumbersStayPutAndAreNeverReused() {
        let numbering = ElementNumbering()
        let me = AXUIElementCreateApplication(getpid())
        let other = AXUIElementCreateApplication(1)

        numbering.beginSnapshot()
        let first = numbering.number(for: me, role: "AXButton")
        let second = numbering.number(for: other, role: "AXButton")
        let synthetic = numbering.number(for: me, role: "AXSyntheticText")
        numbering.endSnapshot()
        XCTAssertEqual([first, second, synthetic], [0, 1, 2])

        // The next read shows a new element first; the others keep their numbers.
        numbering.beginSnapshot()
        let newcomer = numbering.number(for: AXUIElementCreateApplication(2), role: "AXButton")
        XCTAssertEqual(numbering.number(for: other, role: "AXButton"), second)
        XCTAssertEqual(numbering.number(for: me, role: "AXButton"), first)
        // The same element twice in one read is two numbers, never one shared.
        XCTAssertNotEqual(numbering.number(for: me, role: "AXButton"), first)
        numbering.endSnapshot()
        XCTAssertEqual(newcomer, 3)

        // An element unseen for several reads is dropped, and returns under a new number.
        for _ in 0..<(ElementNumbering.keptGenerations + 1) {
            numbering.beginSnapshot()
            _ = numbering.number(for: me, role: "AXWindow")
            numbering.endSnapshot()
        }
        numbering.beginSnapshot()
        let back = numbering.number(for: other, role: "AXButton")
        numbering.endSnapshot()
        XCTAssertGreaterThan(back, newcomer)
        XCTAssertEqual(numbering.highWater, back + 1)
    }
}

extension BatchEffectsTests {
    func testRepeatedFailedReadsExhaustTheObservationBudget() {
        var budget = BatchEffects.ReadBudget()
        var attempts = 0
        for _ in 0..<20 where !budget.exhausted {
            attempts += 1
            budget.record(seconds: 1, settleMs: 600, observed: false)
        }
        XCTAssertEqual(attempts, 8)
        XCTAssertEqual(budget.elapsed, 8)
    }

    func testSettleCreditOnlyAppliesToSuccessfulReads() {
        var failed = BatchEffects.ReadBudget()
        failed.record(seconds: 2.7, settleMs: 600, observed: false)
        XCTAssertTrue(failed.exhausted)

        var successful = BatchEffects.ReadBudget()
        successful.record(seconds: 2.7, settleMs: 600, observed: true)
        XCTAssertFalse(successful.exhausted)
        XCTAssertEqual(successful.elapsed, 2.7)
    }
}
