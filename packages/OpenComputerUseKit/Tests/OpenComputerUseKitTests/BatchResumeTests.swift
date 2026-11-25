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

    func testTypedAliasesAndCompareValuesRequireFreshSlots() throws {
        let steps = [
            BatchTool.Step(tool: "type_text", arguments: ["app": "Notes", "content": "private-body",
                                                        "message": "unused-private-alias"]),
            BatchTool.Step(tool: "set_value", arguments: ["app": "Notes", "label": "Name",
                                                        "newValue": "private-new", "expected_value": "private-old"]),
        ]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([], stop: .timeBudget, total: 2),
            goal: "", doneWhen: nil, app: "Notes", windowID: 42, processID: 7))
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        // Stored arguments are themselves Data in the record; inspect both layers.
        XCTAssertFalse(encoded.contains("private-"))
        XCTAssertTrue(record.pending.allSatisfy { !String(decoding: $0.arguments, as: UTF8.self).contains("private-") })
        XCTAssertEqual(record.slotNames, ["step-1-text", "step-2-expected_value", "step-2-value"])
        XCTAssertThrowsError(try BatchResume.steps(of: record, values: [:]))
        let work = try BatchResume.steps(of: record, values: [
            "step-1-text": "fresh body", "step-2-value": "fresh name", "step-2-expected_value": "fresh old name",
        ])
        XCTAssertEqual(work[0].arguments["text"] as? String, "fresh body")
        XCTAssertNil(work[0].arguments["content"])
        XCTAssertNil(work[0].arguments["message"])
        XCTAssertEqual(work[1].arguments["value"] as? String, "fresh name")
        XCTAssertEqual(work[1].arguments["expected_value"] as? String, "fresh old name")
        XCTAssertNil(work[1].arguments["newValue"])
        let legacy = BatchResume.Record(id: UUID().uuidString, createdAt: Date(), expiresAt: Date().addingTimeInterval(60),
            app: "Notes", goal: "", doneWhen: nil, windowID: 42, processID: 7, total: 1,
            pending: [.init(number: 1, tool: "type_text", arguments: Data(#"{"app":"Notes","content":"old-private-value"}"#.utf8), slots: [:])],
            sent: [])
        XCTAssertThrowsError(try BatchResume.steps(of: legacy, values: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("fresh-value slot"))
        }
    }

    func testBrowserTabAliasSurvivesWithoutItsPayload() throws {
        let stored = try XCTUnwrap(BatchResume.stored(.init(tool: "browser", arguments: [
            "action": "type", "tab": 42, "content": "private text", "url": "https://example.com/private",
        ]), number: 1, batchWindowID: nil))
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: stored.arguments) as? [String: Any])
        XCTAssertEqual(arguments.count, 1)
        XCTAssertEqual(arguments["tab_id"] as? Int, 42)
    }

    func testCompletionPayloadsAreSlottedWithoutLosingVerification() throws {
        let secret = "private-completion-body"
        let completion: [String: Any] = ["field": "Body", "equals": secret, "text": "Saved",
                                          "unused": ["text": "private-ignored-metadata"]]
        let record = try XCTUnwrap(BatchResume.record(
            steps: [.init(tool: "set_value", arguments: ["app": "Notes", "label": "Body", "value": secret])],
            receipt: receipt([], stop: .timeBudget, total: 1),
            goal: "Fill Body with \(secret)", doneWhen: completion, app: "Notes", windowID: 42, processID: 7))
        XCTAssertNil(record.doneWhen)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("private-ignored-metadata"))
        XCTAssertFalse(record.goal.contains(secret))
        XCTAssertEqual(record.slotNames, ["batch-done-1-equals", "batch-done-1-field", "batch-done-1-text", "step-1-value"])
        let reply = BatchResume.replyLines(for: record).joined(separator: "\n")
        XCTAssertTrue(reply.contains("batch-done-1-equals"))
        XCTAssertThrowsError(try BatchResume.completionArguments(of: record, values: [:]))
        XCTAssertThrowsError(try BatchResume.completionArguments(of: record, values: [
            "batch-done-1-field": "Body", "batch-done-1-equals": secret,
        ]), "A caller cannot omit one of the original completion predicates")
        let restored = try BatchResume.completionArguments(of: record, values: [
            "batch-done-1-field": "Body", "batch-done-1-equals": secret, "batch-done-1-text": "Saved",
        ])
        XCTAssertEqual(try DoneCheck.parse(restored), try DoneCheck.parse(completion))
    }

    func testCompletionTemplatesSurviveRepeatedResumeAndKeepTransitionOperator() throws {
        let first = try XCTUnwrap(BatchResume.record(
            steps: clicks(3), receipt: receipt([.acknowledged], stop: .timeBudget, total: 3),
            goal: "Update note", doneWhen: ["field": "Body", "value": "changed text", "since_start": "changed"],
            app: "Notes", windowID: 42, processID: 7))
        let supplied = ["batch-done-1-field": "Body", "batch-done-1-equals": "changed text"]
        let work = try BatchResume.steps(of: first, values: [:])
        let restored = try BatchResume.completionArguments(of: first, values: supplied)
        XCTAssertEqual(try DoneCheck.parse(restored), [.fieldChanged(label: "Body", equals: "changed text")])
        let next = try XCTUnwrap(BatchResume.record(
            steps: work, receipt: receipt([.acknowledged], stop: .timeBudget, total: 2),
            goal: first.goal, doneWhen: restored, app: "Notes", windowID: 42, processID: 7, continuing: first))
        XCTAssertNil(next.doneWhen)
        XCTAssertEqual(next.slotNames, first.slotNames)
        XCTAssertEqual(try DoneCheck.parse(BatchResume.completionArguments(of: next, values: supplied)),
                       [.fieldChanged(label: "Body", equals: "changed text")])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(next), as: UTF8.self).contains("changed text"))
    }

    func testLegacyCompletionRefusesBeforeClaimAndNestedHandoffValuesStayPrivate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            let legacy = BatchResume.Record(id: UUID().uuidString, createdAt: Date(), expiresAt: Date().addingTimeInterval(60),
                app: "NoSuchResumeApp", goal: "", doneWhen: Data(#"{"field":"Body","equals":"old-private-value"}"#.utf8),
                windowID: 42, processID: 7, total: 1,
                pending: [.init(number: 1, tool: "click", arguments: Data(#"{"label":"Next"}"#.utf8), slots: [:])], sent: [])
            try BatchResume.save(legacy)
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["resume": legacy.id])) { error in
                XCTAssertTrue(error.localizedDescription.contains("legacy completion values"))
            }
            XCTAssertNoThrow(try BatchResume.load(legacy.id))
        }
        let stored = try XCTUnwrap(BatchResume.stored(.init(tool: HandoffTool.name, arguments: [
            "app": "Notes", "goal": "Fill Body with private-body", "values": ["Body": "private-body"],
            "expected_values": ["Body": "private-before"], "done_when": ["field": "Body", "equals": "private-body"],
        ]), number: 1, batchWindowID: nil))
        XCTAssertFalse(String(decoding: stored.arguments, as: UTF8.self).contains("private-"))
        XCTAssertEqual(Set(stored.slots.keys), ["goal", "values", "expected_values", "done_when"])
    }

    func testUncertainObservationCannotBeDowngradedToPending() throws {
        var stopped = receipt([.notSent], stop: .stepFailure, total: 2)
        stopped.steps[0].observation = .outcomeUnknown
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(2), receipt: stopped, goal: "", doneWhen: nil,
            app: "Notes", windowID: 42, processID: 7))
        XCTAssertEqual(record.pending.map(\.number), [2])
        XCTAssertEqual(record.sent.map(\.state), [.outcomeUnknown])
        XCTAssertTrue(BatchResume.replyLines(for: record).contains("Inspect the uncertain step before sending any remaining actions."))
    }

    func testPendingHandoffKeepsOriginalWindowAfterUnpinnedBatch() throws {
        func checkpoint(window: UInt32?) throws -> BatchResume.Record {
            var arguments: [String: Any] = ["app": "Notes", "goal": "Click Next"]
            if let window { arguments["window_id"] = window }
            return try XCTUnwrap(BatchResume.record(
                steps: [.init(tool: HandoffTool.name, arguments: arguments)],
                receipt: receipt([], stop: .timeBudget, total: 1),
                goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 7, originalWindowID: 42))
        }
        let work = try BatchResume.steps(of: checkpoint(window: nil), values: [:])
        XCTAssertEqual(try validatedQueryWindowID(work[0].arguments["window_id"]), 42)
        XCTAssertThrowsError(try BatchResume.steps(of: checkpoint(window: 43), values: [:])) { error in
            guard case ComputerUseError.windowChanged(42, _) = error else { return XCTFail("\(error)") }
        }
    }

    func testCancelledOrExpiredResumeKeepsTokenUnclaimed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            let record = try XCTUnwrap(BatchResume.record(
                steps: clicks(2), receipt: receipt([.acknowledged], stop: .timeBudget, total: 2),
                goal: "", doneWhen: nil, app: "NoSuchResumeApp", windowID: 42, processID: 7))
            try BatchResume.save(record)
            let cancellation = RequestCancellation()
            cancellation.cancel()
            try RequestCancellation.$current.withValue(cancellation) {
                XCTAssertThrowsError(try BatchResume.claim(record.id)) { error in
                    XCTAssertEqual((error as? RequestCancellation.Cancelled)?.deliveryState, .notSent)
                }
                XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["resume": record.id])) { error in
                    XCTAssertEqual((error as? RequestCancellation.Cancelled)?.deliveryState, .notSent)
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime - 1
            XCTAssertThrowsError(try BatchResume.claim(record.id, deadline: deadline)) { error in
                XCTAssertTrue(error.localizedDescription.contains("deadline elapsed"))
            }
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["resume": record.id], inheritedDeadline: deadline)) { error in
                XCTAssertTrue(error.localizedDescription.contains("deadline elapsed"))
            }
            XCTAssertEqual(try BatchResume.load(record.id).id, record.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.id + ".claimed.json").path))
            XCTAssertNoThrow(try BatchResume.claim(record.id))
        }
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
        let launch = Date(timeIntervalSince1970: 1_700_000_000)
        let steps = [
            BatchTool.Step(tool: "click", arguments: ["app": "Notes", "element_index": 3]),
            BatchTool.Step(tool: "click", arguments: ["app": "Notes", "elementId": 4]),
        ]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([], stop: .windowChanged, total: 2),
            goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 7, originalWindowID: 42,
            processLaunchDate: launch))
        XCTAssertNoThrow(try BatchResume.check(record, now: Date(), liveProcessID: 7, liveWindowID: 42,
                                              liveProcessLaunchDate: launch))
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
        let launch = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            var stopped = receipt([.verified], stop: .timeBudget, total: 3)
            stopped.steps[0].verification = .effectSeen
            let first = try XCTUnwrap(BatchResume.record(
                steps: clicks(3), receipt: stopped,
                goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 7, originalWindowID: 42,
                processLaunchDate: launch))
            try BatchResume.save(first)
            let loaded = try BatchResume.load(first.id)
            let next = try XCTUnwrap(BatchResume.record(
                steps: try BatchResume.steps(of: loaded, values: [:]),
                receipt: receipt([], stop: .windowChanged, total: 2),
                goal: "", doneWhen: nil, app: "Notes", windowID: nil, processID: 8,
                originalWindowID: 43, continuing: loaded, processLaunchDate: launch.addingTimeInterval(60)))
            XCTAssertEqual(next.sent.map(\.number), [1])
            XCTAssertEqual(next.sent.map(\.state), [.verified])
            XCTAssertEqual(next.sent.first?.verification, "effect_seen")
            XCTAssertEqual(next.processID, 7)
            XCTAssertEqual(next.processLaunchDate, launch)
            XCTAssertEqual(next.originalWindowID, 42)
            XCTAssertThrowsError(try BatchResume.check(next, now: Date(), liveProcessID: 8, liveWindowID: 43))
        }
    }

    func testWindowOrProcessChangeIsRefused() throws {
        let start = Date()
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(3), receipt: receipt([.acknowledged], stop: .windowChanged, total: 3),
            goal: "", doneWhen: nil, app: "Notes", windowID: 42, processID: 7, now: start,
            processLaunchDate: start))
        try BatchResume.check(record, now: start, liveProcessID: 7, liveWindowID: 42, liveProcessLaunchDate: start)
        XCTAssertThrowsError(try BatchResume.check(record, now: start, liveProcessID: 7, liveWindowID: 43)) { error in
            guard case ComputerUseError.windowChanged(42, _) = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try BatchResume.check(record, now: start, liveProcessID: 8, liveWindowID: 42)) { error in
            guard case ComputerUseError.windowChanged(42, _) = error else { return XCTFail("\(error)") }
        }
    }

    func testReusedProcessAndWindowIdentifiersDoNotMatchRestartedApplication() throws {
        let launch = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(2), receipt: receipt([.acknowledged], stop: .timeBudget, total: 2),
            goal: "Finish the original document", doneWhen: nil, app: "Notes", windowID: 42, processID: 7,
            processLaunchDate: launch))
        let restored = try JSONDecoder().decode(BatchResume.Record.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.processLaunchDate, launch)
        XCTAssertNoThrow(try BatchResume.check(restored, now: Date(), liveProcessID: 7, liveWindowID: 42,
                                              liveProcessLaunchDate: launch))
        for currentLaunch in [launch.addingTimeInterval(1), nil] {
            XCTAssertThrowsError(try BatchResume.check(restored, now: Date(), liveProcessID: 7, liveWindowID: 42,
                                                      liveProcessLaunchDate: currentLaunch)) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent)
                XCTAssertTrue(error.localizedDescription.contains("application lifetime"))
            }
        }
    }

    func testResumedWindowBindingIncludesExplicitReadsAndInput() throws {
        let steps: [BatchTool.Step] = [
            .init(tool: "click", arguments: ["app": "Notes", "label": "Save"]),
            .init(tool: "get_app_state", arguments: ["app": "Notes"]),
            .init(tool: "query", arguments: ["app": "Notes", "text": "Saved"]),
            .init(tool: "wait", arguments: ["app": "Notes", "text": "Saved"]),
        ]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([], stop: .timeBudget, total: steps.count),
            goal: "Complete the original document", doneWhen: nil, app: "Notes", windowID: nil, processID: 7,
            originalWindowID: 42, processLaunchDate: Date()))
        let bound = try BatchTool.binding(BatchResume.steps(of: record, values: [
            "step-3-text": "Saved", "step-4-text": "Saved",
        ]), to: record.targetWindowID, app: record.app)
        for step in bound.prefix(3) {
            XCTAssertEqual(try validatedQueryWindowID(step.arguments["window_id"]), 42)
            XCTAssertEqual(step.arguments["app"] as? String, "Notes")
        }
        XCTAssertEqual(bound[3].arguments["app"] as? String, "Notes")
        XCTAssertEqual(bound[3].arguments["text"] as? String, "Saved")
    }

    func testResumedWindowBindingRefusesWindowSwitchesAndUnboundActions() {
        let invalid: [BatchTool.Step] = [
            .init(tool: "press_menu", arguments: ["app": "Notes", "path": ["File", "Open"]]),
            .init(tool: "wait", arguments: ["app": "Notes", "window": "Another document"]),
            .init(tool: "click", arguments: ["app": "Notes", "window_id": 43, "label": "Save"]),
            .init(tool: "get_app_state", arguments: ["app": "Mail"]),
        ]
        for step in invalid {
            XCTAssertThrowsError(try BatchTool.binding([step], to: 42, app: "Notes"))
        }
    }

    func testLegacyCheckpointWithoutLaunchIdentityStaysAvailableForInspection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            let record = try XCTUnwrap(BatchResume.record(
                steps: clicks(2), receipt: receipt([.verified], stop: .timeBudget, total: 2),
                goal: "Finish the original document", doneWhen: nil, app: "Notes", windowID: 42, processID: 7))
            try BatchResume.save(record)
            let restored = try BatchResume.load(record.id)
            XCTAssertNil(restored.processLaunchDate)
            XCTAssertThrowsError(try BatchResume.check(restored, now: Date(), liveProcessID: 7, liveWindowID: 42,
                                                      liveProcessLaunchDate: Date())) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent)
            }
            XCTAssertEqual(try BatchResume.load(record.id).sent.map(\.number), [1])
            let lines = BatchResume.replyLines(for: restored)
            XCTAssertTrue(lines.contains("Read the target and send the remaining steps explicitly."))
            XCTAssertFalse(lines.contains { $0.hasPrefix("Send batch with resume") })
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

    func testCheckpointInspectionSurvivesContextResetWithoutDispatchOrClaim() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try BatchResume.$directoryOverride.withValue(folder) {
            let record = try XCTUnwrap(BatchResume.record(
                steps: clicks(4), receipt: receipt([.verified, .acknowledged], stop: .timeBudget, total: 4),
                goal: "Finish the list", doneWhen: nil, app: "Notes", windowID: 42, processID: 7,
                processLaunchDate: Date()))
            try BatchResume.save(record)
            // A fresh dispatcher stands in for a new host turn with no history.
            for _ in 0..<2 {
                let reply = try dispatcher().callTool(name: "batch", arguments: ["inspect_resume": record.id])
                XCTAssertEqual(reply.deliveryState, .notSent)
                let object = try inspectionObject(reply)
                XCTAssertEqual(object["source"] as? String, "saved_checkpoint_not_live_state")
                XCTAssertEqual(object["actions_sent"] as? Int, 0)
                XCTAssertEqual(object["token_consumed"] as? Bool, false)
                XCTAssertEqual(object["next_action"] as? String, "resume_with_fresh_values")
                let progress = try XCTUnwrap(object["progress"] as? [String: Any])
                XCTAssertEqual(progress["pending_steps"] as? [Int], [3, 4])
                XCTAssertEqual(progress["dispatched_steps"] as? [Int], [1, 2])
                XCTAssertEqual(progress["verified_delivery_steps"] as? [Int], [1])
                XCTAssertEqual(try BatchResume.load(record.id).id, record.id)
            }
        }
    }

    func testCheckpointInspectionKeepsUncertaintySeparateFromPendingWork() throws {
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(3), receipt: receipt([.acknowledged, .outcomeUnknown], stop: .stepFailure, total: 3),
            goal: "Finish list", doneWhen: nil, app: "Notes", windowID: 42, processID: 7,
            processLaunchDate: Date()))
        let object = try inspectionObject(BatchResume.inspection(of: record))
        XCTAssertEqual(object["next_action"] as? String, "inspect_uncertain_delivery")
        let progress = try XCTUnwrap(object["progress"] as? [String: Any])
        XCTAssertEqual(progress["uncertain_steps"] as? [Int], [2])
        XCTAssertEqual(progress["pending_steps"] as? [Int], [3])
    }

    func testCheckpointInspectionDoesNotExposeStoredPayloadsOrCompletionValues() throws {
        let steps = [BatchTool.Step(tool: "type_text", arguments: ["app": "Notes", "text": "private-text-123"])]
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt([], stop: .timeBudget, total: 1),
            goal: "Insert private-text-123", doneWhen: ["text": "secret-outcome-456"],
            app: "Notes", windowID: 42, processID: 7, processLaunchDate: Date()))
        let reply = try BatchResume.inspection(of: record)
        XCTAssertFalse(reply.textContent.contains("private-text-123"))
        XCTAssertFalse(reply.textContent.contains("secret-outcome-456"))
        let object = try inspectionObject(reply)
        XCTAssertEqual(record.privacyVersion, 1)
        XCTAssertEqual(object["goal"] as? String, "Insert [value omitted]")
        XCTAssertEqual(Set(object["required_values"] as? [String] ?? []), Set(record.slotNames))
        XCTAssertFalse((object["pending_tools"] as? [[String: Any]] ?? []).contains { $0["arguments"] != nil })
    }

    func testCheckpointInspectionOmitsLegacyGoalsEvenWhenStructureIsOtherwiseResumable() throws {
        let privateValue = "private-legacy-value-789"
        let raw = try JSONSerialization.data(withJSONObject: ["app": "Notes", "text": privateValue])
        let slotted = try XCTUnwrap(BatchResume.stored(
            .init(tool: "type_text", arguments: ["app": "Notes", "text": privateValue]),
            number: 1, batchWindowID: 42))
        for pending in [BatchResume.Stored(number: 1, tool: "type_text", arguments: raw, slots: [:]), slotted] {
            for legacyCompletion in [nil, try JSONSerialization.data(withJSONObject: ["text": privateValue])] as [Data?] {
                let record = BatchResume.Record(
                    id: UUID().uuidString, createdAt: Date(), expiresAt: Date().addingTimeInterval(60),
                    app: "Notes", goal: "Insert \(privateValue)", doneWhen: legacyCompletion,
                    windowID: 42, processID: 7, total: 1, pending: [pending], sent: [], processLaunchDate: Date())
                let restored = try JSONDecoder().decode(BatchResume.Record.self, from: JSONEncoder().encode(record))
                XCTAssertNil(restored.privacyVersion)
                let reply = try BatchResume.inspection(of: restored)
                XCTAssertFalse(reply.textContent.contains(privateValue))
                XCTAssertNil(try inspectionObject(reply)["goal"])
            }
        }
    }

    func testContinuingLegacyCheckpointDoesNotMarkItsGoalAsPayloadRedacted() throws {
        let stored = try XCTUnwrap(BatchResume.stored(clicks(1)[0], number: 1, batchWindowID: 42))
        let legacy = BatchResume.Record(
            id: UUID().uuidString, createdAt: Date(), expiresAt: Date().addingTimeInterval(60),
            app: "Notes", goal: "An older goal containing private-previous-value", doneWhen: nil,
            windowID: 42, processID: 7, total: 1, pending: [stored], sent: [], processLaunchDate: Date())
        let continued = try XCTUnwrap(BatchResume.record(
            steps: try BatchResume.steps(of: legacy, values: [:]), receipt: receipt([], stop: .timeBudget, total: 1),
            goal: "Current goal", doneWhen: nil, app: "Notes", windowID: 42, processID: 7, continuing: legacy))
        XCTAssertNil(continued.privacyVersion)
        XCTAssertNil(try inspectionObject(BatchResume.inspection(of: continued))["goal"])
    }

    func testCheckpointInspectionDoesNotOfferUnboundOrLegacyContinuation() throws {
        for tool in ["browser", "press_menu"] {
            let step = BatchTool.Step(tool: tool, arguments: ["app": "Notes", "path": "File > New"])
            let record = try XCTUnwrap(BatchResume.record(
                steps: [step], receipt: receipt([], stop: .timeBudget, total: 1),
                goal: "", doneWhen: nil, app: "Notes", windowID: 42, processID: 7,
                processLaunchDate: Date()))
            let object = try inspectionObject(BatchResume.inspection(of: record))
            XCTAssertEqual(object["next_action"] as? String, "read_target_and_send_fresh_steps")
        }
        let legacy = try XCTUnwrap(BatchResume.record(
            steps: clicks(2), receipt: receipt([.verified], stop: .timeBudget, total: 2),
            goal: "", doneWhen: nil, app: "Notes", windowID: 42, processID: 7))
        XCTAssertEqual(try inspectionObject(BatchResume.inspection(of: legacy))["next_action"] as? String,
                       "read_target_and_send_fresh_steps")
    }

    func testCheckpointInspectionSharesStaleTargetAndLegacyPayloadRefusalsWithExecution() throws {
        let fixtures: [(String, [String: Any])] = [
            ("click", ["element_index": "12"]), ("click", ["index": 12]),
            ("click", ["ref": "native-old-reference"]), ("click", ["x": 20, "y": 30]),
            ("type_text", ["content": "old private text"]),
            ("handoff", ["values": ["Name": "old private value"]]),
        ]
        for (tool, payload) in fixtures {
            let arguments = payload.merging(["app": "Notes"]) { _, new in new }
            let stored = BatchResume.Stored(number: 1, tool: tool,
                arguments: try JSONSerialization.data(withJSONObject: arguments), slots: [:])
            let now = Date()
            let record = BatchResume.Record(id: UUID().uuidString, createdAt: now,
                expiresAt: now.addingTimeInterval(BatchResume.lifetime), app: "Notes", goal: "",
                doneWhen: nil, windowID: 42, processID: 7, total: 1, pending: [stored], sent: [],
                processLaunchDate: now)
            let object = try inspectionObject(BatchResume.inspection(of: record))
            XCTAssertEqual(object["next_action"] as? String, "read_target_and_send_fresh_steps", "\(tool): \(payload)")
            XCTAssertThrowsError(try BatchResume.steps(of: record, values: [:]))
        }
    }

    func testCheckpointInspectionWithNoPendingStepsRequiresOutcomeVerification() throws {
        let record = try XCTUnwrap(BatchResume.record(
            steps: clicks(1), receipt: receipt([.acknowledged], stop: .stepFailure, total: 1),
            goal: "", doneWhen: nil, app: "Notes", windowID: 42, processID: 7,
            processLaunchDate: Date()))
        let object = try inspectionObject(BatchResume.inspection(of: record))
        XCTAssertEqual(object["next_action"] as? String, "verify_current_state")
    }

    func testCheckpointInspectionRejectsMixedExecutionAndInvalidTokens() {
        let token = UUID().uuidString
        let executionArguments: [[String: Any]] = [["resume": token], ["steps": [["tool": "click", "label": "Send"]]],
                                                   ["app": "Notes"], ["values": ["text": "payload"]], ["foreground": true]]
        for extra in executionArguments {
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: extra.merging(["inspect_resume": token]) { _, new in new }))
        }
        let invalidTokens: [Any] = [123, "", "../etc/passwd"]
        for token in invalidTokens {
            XCTAssertThrowsError(try dispatcher().runBatch(arguments: ["inspect_resume": token]))
        }
    }

    func testCheckpointInspectionBoundsContextWithoutDiscardingStepNumbers() throws {
        let steps = (1...40).map { number in
            BatchTool.Step(tool: "click", arguments: ["app": "Notes", "label": String(repeating: "large label \(number)", count: 200)])
        }
        let record = try XCTUnwrap(BatchResume.record(
            steps: steps, receipt: receipt(Array(repeating: .acknowledged, count: 20), stop: .timeBudget, total: 40),
            goal: String(repeating: "long goal\n", count: 400), doneWhen: nil,
            app: "Notes", windowID: 42, processID: 7, processLaunchDate: Date()))
        let reply = try BatchResume.inspection(of: record)
        XCTAssertLessThan(reply.textContent.utf8.count, 4_096)
        let object = try inspectionObject(reply)
        let progress = try XCTUnwrap(object["progress"] as? [String: Any])
        XCTAssertEqual(progress["pending_steps"] as? [Int], Array(21...40))
        XCTAssertEqual(progress["dispatched_steps"] as? [Int], Array(1...20))
        XCTAssertFalse((object["goal"] as? String ?? "").contains("\n"))
    }

    private func inspectionObject(_ reply: ToolCallResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.textContent.utf8)) as? [String: Any])
    }

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
