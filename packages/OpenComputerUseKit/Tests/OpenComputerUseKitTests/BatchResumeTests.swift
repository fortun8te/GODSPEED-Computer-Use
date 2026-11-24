import Foundation
import XCTest
@testable import OpenComputerUseKit

final class BatchResumeTests: XCTestCase {
    private func withJournal(_ body: (OperationJournal) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(OperationJournal(directory: folder))
    }

    /// Step 7 of a batch with a goal: the restart notice says where the unfinished intent was.
    func testRestartNoticeNamesStepAndGoal() throws {
        try withJournal { journal in
            _ = try journal.begin(tool: "click", requestID: UUID(), app: "Notes", step: 7, goal: "Send the report")
            XCTAssertEqual(RestartNoticeState(journal: journal).claim(),
                           "After a restart: click in Notes (step 7 of 'Send the report') may or may not have happened. Read the app before repeating it.")
        }
    }

    private func clicks(_ count: Int) -> [BatchTool.Step] {
        (1...count).map { BatchTool.Step(tool: "click", arguments: ["app": "Notes", "label": "Item \($0)"]) }
    }

    private func receipt(_ states: [DeliveryState], stop: TrajectoryLog.BatchReceipt.Stop?, total: Int = 10) -> TrajectoryLog.BatchReceipt {
        var receipt = TrajectoryLog.BatchReceipt(totalSteps: total)
        receipt.steps = states.map { TrajectoryLog.BatchReceipt.Step(deliveryState: $0) }
        receipt.stop = stop
        return receipt
    }

    /// A batch of ten clicks that stopped after five: steps 6-10 are pending and nothing else is.
    func testStopAtStepFiveOfTenResumesSixToTen() throws {
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(10), receipt: receipt(Array(repeating: .acknowledged, count: 5), stop: .timeBudget),
            goal: "Fill the list", doneWhen: nil, app: "Notes", windowID: 42, processID: 7))
        XCTAssertEqual(record.pending.map(\.number), [6, 7, 8, 9, 10])
        XCTAssertEqual(record.sent.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(record.total, 10)
        XCTAssertEqual(BatchResume.ranges(record.pending.map(\.number)), "6-10")
        let resumed = try BatchResume.steps(of: record, values: [:])
        XCTAssertEqual(resumed.map { $0.arguments["label"] as? String }, ["Item 6", "Item 7", "Item 8", "Item 9", "Item 10"])
    }

    func testRepeatedResumeKeepsOriginalStepNumbersAndSlots() throws {
        let steps = clicks(4) + [.init(tool: "type_text", arguments: ["app": "Notes", "text": "draft"])]
        let first = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([.acknowledged, .outcomeUnknown], stop: .stepFailure, total: 5),
            goal: "Edit note", doneWhen: nil, app: "Notes", windowID: 9, processID: 7))
        let work = try BatchResume.steps(of: first, values: ["step-5-text": "draft"])
        let second = try XCTUnwrap(BatchResume.record(
            steps: work, receipt: receipt([.acknowledged, .notSent], stop: .timeBudget, total: 3),
            goal: first.goal, doneWhen: nil, app: first.app, windowID: first.windowID, processID: first.processID,
            continuing: first))
        XCTAssertEqual(second.total, 5)
        XCTAssertEqual(second.sent.map(\.number), [1, 2, 3])
        XCTAssertEqual(second.sent[1].state, .outcomeUnknown)
        XCTAssertEqual(second.pending.map(\.number), [4, 5])
        XCTAssertEqual(second.slotNames, ["step-5-text"])
    }

    /// A step that may have been sent is never resumed, and the reply names it.
    func testUnknownStepIsExcludedAndNamed() throws {
        var states = Array(repeating: DeliveryState.acknowledged, count: 5)
        states[2] = .outcomeUnknown
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(10), receipt: receipt(states, stop: .stepFailure),
            goal: "Fill the list", doneWhen: nil, app: "Notes", windowID: 42, processID: 7))
        XCTAssertFalse(record.pending.contains { $0.number == 3 })
        XCTAssertEqual(record.sent.first { $0.number == 3 }?.state, .outcomeUnknown)
        let reply = BatchResume.replyLines(for: record).joined(separator: "\n")
        XCTAssertTrue(reply.contains("step 3 click (outcome unknown)"), reply)
        XCTAssertTrue(reply.contains("Resume \(record.id)"), reply)
    }

    func testUncertainEffectRequiresInspectionAndKeepsCheckpoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            var stopped = receipt([.acknowledged], stop: .stepFailure, total: 2)
            stopped.steps[0].observation = .outcomeUnknown
            let record = try XCTUnwrap(BatchResume.record(
                steps: clicks(2), receipt: stopped, goal: "", doneWhen: nil,
                app: "Notes", windowID: 42, processID: 7))
            try BatchResume.save(record)
            XCTAssertEqual(record.sent.first?.state, .outcomeUnknown)
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["resume": record.id])) { error in
                XCTAssertTrue(error.localizedDescription.contains("Inspect the saved step"))
            }
            XCTAssertNoThrow(try BatchResume.load(record.id))
        }
    }

    /// A step refused before any input was sent is pending again, so the batch can carry on from it.
    func testStepRefusedBeforeSendingIsPending() throws {
        var states = Array(repeating: DeliveryState.acknowledged, count: 4)
        states.append(.notSent)
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(10), receipt: receipt(states, stop: .stepFailure),
            goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: nil))
        XCTAssertEqual(record.pending.map(\.number), [5, 6, 7, 8, 9, 10])
    }

    func testTypedTextIsStoredAsASlotNotAsText() throws {
        let steps = [
            BatchTool.Step(tool: "click", arguments: ["app": "Notes", "label": "Password"]),
            BatchTool.Step(tool: "type_text", arguments: ["app": "Notes", "window_id": UInt32(42), "text": "hunter2-secret"]),
        ]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([.acknowledged], stop: .timeBudget, total: 2),
            goal: "Sign in", doneWhen: nil, app: "Notes", windowID: 42, processID: 7))
        let typing = try XCTUnwrap(record.pending.first { $0.tool == "type_text" })
        XCTAssertEqual(typing.slots, ["text": "step-2-text"])
        XCTAssertFalse(String(decoding: typing.arguments, as: UTF8.self).contains("hunter2-secret"))
        let storedArguments = try XCTUnwrap(JSONSerialization.jsonObject(with: typing.arguments) as? [String: Any])
        XCTAssertNil(storedArguments["window_id"])
        XCTAssertThrowsError(try BatchResume.steps(of: record, values: [:]))
        let resumed = try BatchResume.steps(of: record, values: ["step-2-text": "hunter2-secret"])
        XCTAssertEqual(resumed.last?.arguments["text"] as? String, "hunter2-secret")
    }

    func testPerStepWindowSurvivesAnUnpinnedBatchResume() throws {
        let steps = [BatchTool.Step(tool: "click", arguments: ["app": "Notes", "window_id": 42, "label": "Save"])]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([], stop: .timeBudget, total: 1),
            goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 7))
        let resumed = try XCTUnwrap(BatchResume.steps(of: record, values: [:]).first)
        XCTAssertEqual(try validatedQueryWindowID(resumed.arguments["window_id"]), 42)
    }

    func testBrowserCheckpointKeepsTabProofAndRequiresInspection() throws {
        let steps = [
            BatchTool.Step(tool: "browser", arguments: ["action": "open"]),
            BatchTool.Step(tool: "browser", arguments: ["action": "type", "tab_id": 42, "text": "private"]),
        ]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([.verified], stop: .timeBudget, total: 2),
            goal: "", doneWhen: nil, app: nil, windowID: nil, processID: nil, browserTabs: [0: 42]))
        XCTAssertEqual(record.sent.first?.tabID, "42")
        XCTAssertEqual(record.sent.first?.state, .verified)
        XCTAssertFalse(String(decoding: record.pending[0].arguments, as: UTF8.self).contains("private"))
        XCTAssertThrowsError(try BatchResume.steps(of: record, values: [:]))
    }

    func testStaleRawIndexIsRefusedEvenWhenWindowMatches() throws {
        let steps = [
            BatchTool.Step(tool: "click", arguments: ["app": "Notes", "element_index": 3]),
            BatchTool.Step(tool: "click", arguments: ["app": "Notes", "elementId": 4]),
        ]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([], stop: .windowChanged, total: 2),
            goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 7, originalWindowID: 42))
        XCTAssertNoThrow(try BatchResume.check(record, now: Date(), liveProcessID: 7, liveWindowID: 42))
        XCTAssertThrowsError(try BatchResume.check(record, now: Date(), liveProcessID: 7, liveWindowID: 43))
        XCTAssertThrowsError(try BatchResume.steps(of: record, values: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("old snapshot"))
        }
        let alias = try XCTUnwrap(BatchResume.record(
            steps: Array(steps.suffix(1)), receipt: receipt([], stop: .windowChanged, total: 1),
            goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 7, originalWindowID: 42))
        XCTAssertThrowsError(try BatchResume.steps(of: alias, values: [:]))
    }

    func testVerifiedMilestoneSurvivesStorageAndReplacementProcess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            var stopped = receipt([.verified], stop: .timeBudget, total: 3)
            stopped.steps[0].verification = .effectSeen
            let first = try XCTUnwrap(BatchResume.record(
                steps: clicks(3), receipt: stopped,
                goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 7, originalWindowID: 42))
            try BatchResume.save(first)
            let loaded = try BatchResume.load(first.id)
            let next = try XCTUnwrap(BatchResume.record(
                steps: try BatchResume.steps(of: loaded, values: [:]),
                receipt: receipt([], stop: .windowChanged, total: 2),
                goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 8,
                originalWindowID: 43, continuing: loaded))
            XCTAssertEqual(next.sent.map(\.number), [1])
            XCTAssertEqual(next.sent.map(\.state), [.verified])
            XCTAssertEqual(next.sent.first?.verification, "effect_seen")
            XCTAssertEqual(next.processID, 7)
            XCTAssertEqual(next.originalWindowID, 42)
            XCTAssertThrowsError(try BatchResume.check(next, now: Date(), liveProcessID: 8, liveWindowID: 43))
        }
    }

    func testWindowOrProcessChangeIsRefused() throws {
        let start = Date()
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(3), receipt: receipt([.acknowledged], stop: .windowChanged, total: 3),
            goal: "", doneWhen: nil, app: "Notes", windowID: 42, processID: 7, now: start))
        try BatchResume.check(record, now: start, liveProcessID: 7, liveWindowID: 42)
        XCTAssertThrowsError(try BatchResume.check(record, now: start, liveProcessID: 7, liveWindowID: 43)) { error in
            guard case ComputerUseError.windowChanged(42, _) = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try BatchResume.check(record, now: start, liveProcessID: 8, liveWindowID: 42)) { error in
            guard case ComputerUseError.windowChanged(42, _) = error else { return XCTFail("\(error)") }
        }
    }

    func testTokenExpiresAfterTwentyFourHoursAndIsConsumedOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            let start = Date()
            let record = try XCTUnwrap(BatchResume.record(
                steps: clicks(3), receipt: receipt([.acknowledged], stop: .timeBudget, total: 3),
                goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: nil, now: start))
            try BatchResume.save(record, now: start)
            XCTAssertThrowsError(try BatchResume.consume(record.id, now: start.addingTimeInterval(24 * 60 * 60 + 1))) { error in
                XCTAssertTrue(error.localizedDescription.contains("RESUME_EXPIRED"), "\(error)")
            }
            try BatchResume.save(record, now: start)
            XCTAssertEqual(try BatchResume.consume(record.id, now: start.addingTimeInterval(60)).id, record.id)
            let archived = folder.appendingPathComponent(record.id + ".claimed.json")
            let claimed = try JSONDecoder().decode(BatchResume.Record.self, from: Data(contentsOf: archived))
            XCTAssertEqual(claimed.sent.map(\.number), [1])
            XCTAssertThrowsError(try BatchResume.consume(record.id, now: start)) { error in
                XCTAssertTrue(error.localizedDescription.contains("RESUME_NOT_FOUND"), "\(error)")
            }
            XCTAssertThrowsError(try BatchResume.consume("../etc/passwd", now: start))
        }
    }

    private func dispatcher() -> ComputerUseToolDispatcher { ComputerUseToolDispatcher(service: ComputerUseService()) }

    /// Unknown and expired tokens are refused before any step is sent, and the stored token survives a refusal.
    func testUnknownAndExpiredTokensAreRefusedBeforeAnyStepRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["resume": UUID().uuidString])) { error in
                XCTAssertTrue(error.localizedDescription.contains("RESUME_NOT_FOUND"), "\(error)")
            }
            let old = Date().addingTimeInterval(-25 * 60 * 60)
            let record = try XCTUnwrap(BatchResume.record(
                steps: clicks(3), receipt: receipt([.acknowledged], stop: .timeBudget, total: 3),
                goal: "", doneWhen: nil, app: nil, windowID: nil, processID: nil, now: old))
            try BatchResume.save(record, now: old)
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["resume": record.id])) { error in
                XCTAssertTrue(error.localizedDescription.contains("RESUME_EXPIRED"), "\(error)")
            }
        }
    }

    /// The app's process is gone, so the pinned window cannot be the same one: refused as WINDOW_CHANGED.
    func testResumeRefusesWhenTheAppProcessChanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            let record = try XCTUnwrap(BatchResume.record(
                steps: clicks(3), receipt: receipt([.acknowledged], stop: .windowChanged, total: 3),
                goal: "", doneWhen: nil, app: "OpenComputerUseNoSuchApp", windowID: 42, processID: 999_999))
            try BatchResume.save(record)
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["resume": record.id])) { error in
                XCTAssertTrue(error.localizedDescription.contains("WINDOW_CHANGED"), "\(error)")
            }
            XCTAssertNoThrow(try BatchResume.load(record.id), "a refused resume keeps its token")
        }
    }

    /// A batch whose first step cannot reach its app stops before sending anything. Its reply carries a token
    /// for all three steps.
    func testStoppedBatchReplyCarriesAResumeToken() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            let reply = try StrictBackground.$requested.withValue(true) {
                try dispatcher().runBatch(arguments: [
                    "app": "OpenComputerUseNoSuchApp", "goal": "Send the report",
                    "steps": [["tool": "click", "label": "A"], ["tool": "click", "label": "B"], ["tool": "click", "label": "C"]],
                ])
            }
            XCTAssertTrue(reply.isError, reply.textContent)
            let regex = try NSRegularExpression(pattern: "Resume ([0-9A-F-]{36})")
            let text = reply.textContent
            let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            let token = String(text[Range(match.range(at: 1), in: text)!])
            let record = try BatchResume.load(token)
            XCTAssertEqual(record.pending.map(\.number), [1, 2, 3], text)
            XCTAssertEqual(record.goal, "Send the report")
        }
    }
}
