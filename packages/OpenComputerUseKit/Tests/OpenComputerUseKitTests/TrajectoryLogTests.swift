import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Tests for the opt-in trajectory log. They write only into a temporary folder and never touch
/// accessibility, the screen or a running app.
final class TrajectoryLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trajectory-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWorkersInSameBenchmarkRunHaveSeparateStreams() {
        let first = makeLog()
        let second = makeLog()
        XCTAssertEqual(first.runID, second.runID)
        XCTAssertNotEqual(first.sessionID, second.sessionID)
    }

    private func makeLog(runID: String? = "bench-7", maxBytes: UInt64 = TrajectoryLog.defaultMaxBytes) -> TrajectoryLog {
        var environment = [TrajectoryLog.enabledVariable: "1", TrajectoryLog.contentVariable: "1"]
        if let runID { environment[TrajectoryLog.runIDVariable] = runID }
        return TrajectoryLog(environment: environment, directory: directory, maxBytes: maxBytes)
    }

    /// Every line of the session file, parsed as a JSON object, in order.
    private func records(_ log: TrajectoryLog) throws -> [[String: Any]] {
        log.flush()
        let data = try Data(contentsOf: directory.appendingPathComponent(log.sessionID + ".jsonl"))
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func started() -> Date {
        Date().addingTimeInterval(-0.25)
    }

    // MARK: - Opt-in switch

    func testLogIsOnByDefaultAndOffOnlyForExplicitFalseValues() {
        XCTAssertTrue(TrajectoryLog.isEnabled(environment: [:]))
        XCTAssertTrue(TrajectoryLog.isEnabled(environment: [TrajectoryLog.enabledVariable: ""]))
        XCTAssertFalse(TrajectoryLog.isEnabled(environment: [TrajectoryLog.enabledVariable: "0"]))
        XCTAssertFalse(TrajectoryLog.isEnabled(environment: [TrajectoryLog.enabledVariable: " Off "]))
        XCTAssertFalse(TrajectoryLog.isEnabled(environment: [TrajectoryLog.enabledVariable: "false"]))
        XCTAssertTrue(TrajectoryLog.isEnabled(environment: [TrajectoryLog.enabledVariable: "1"]))
        XCTAssertTrue(TrajectoryLog.isEnabled(environment: [TrajectoryLog.enabledVariable: " TRUE "]))
        XCTAssertTrue(TrajectoryLog.isEnabled(environment: [TrajectoryLog.enabledVariable: "on"]))
    }

    func testDisabledLogWritesNothingAndCreatesNoFolder() {
        let log = TrajectoryLog(environment: [TrajectoryLog.enabledVariable: "0"], directory: directory)
        log.recordToolCall(name: "click", arguments: ["label": "Save"], result: .text("ok"), startedAt: started())
        log.recordFailedToolCall(name: "click", arguments: [:], error: ComputerUseError.message("boom"), startedAt: started())
        log.sessionEnded()
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Record format

    func testAdmissionAttemptsRecordWaitSeparatelyFromDispatch() throws {
        let log = TrajectoryLog(environment: [:], directory: directory)
        log.recordToolCall(name: "browser", arguments: [:], result: .text("ok"), startedAt: started(), admissionMs: 12.34)
        log.recordAdmissionTimeout(name: "browser", admissionMs: 45_000)
        let lines = try records(log)
        XCTAssertEqual(lines[0]["admission_ms"] as? Double, 12.3)
        XCTAssertNil(lines[0]["admission_timed_out"])
        XCTAssertEqual(lines[1]["admission_ms"] as? Double, 45_000)
        XCTAssertEqual(lines[1]["admission_timed_out"] as? Bool, true)
        XCTAssertEqual(lines[1]["failure_code"] as? String, "timeout")
        XCTAssertNil(lines[1]["arguments"])
    }

    func testDefaultLogOmitsPrivateContentButRecordsFailedBatch() throws {
        let log = TrajectoryLog(environment: [:], directory: directory)
        let receipt = TrajectoryLog.BatchReceipt(
            totalSteps: 3,
            steps: [.init(observation: .outcomeUnknown), .init(failureCode: .staleState, observation: .notSent)],
            stop: .stepFailure,
            observation: .failed,
            doneCheck: .skipped
        )
        log.recordToolCall(
            name: "batch",
            arguments: ["goal": "PRIVATE_INPUT"],
            result: ToolCallResult(
                content: [.text("2. type PRIVATE_INPUT: FAILED: PRIVATE_RESULT")], isError: true, batchReceipt: receipt
            ),
            startedAt: started()
        )
        let record = try XCTUnwrap(records(log).first)
        XCTAssertEqual(record["capture_mode"] as? String, "metadata")
        XCTAssertEqual(record["batch_failed"] as? Bool, true)
        XCTAssertEqual(record["schema_version"] as? Int, 3)
        XCTAssertEqual(record["failure_code"] as? String, "stale_state")
        XCTAssertEqual(record["batch_stop_code"] as? String, "step_failure")
        XCTAssertEqual(record["batch_not_run"] as? Int, 1)
        XCTAssertEqual(record["batch_observation"] as? String, "failed")
        XCTAssertEqual(record["batch_done_check"] as? String, "skipped")
        let steps = try XCTUnwrap(record["batch_step_receipts"] as? [[String: Any]])
        XCTAssertEqual(steps[0]["status"] as? String, "ok")
        XCTAssertEqual(steps[0]["observation"] as? String, "outcome_unknown")
        XCTAssertEqual(steps[1]["n"] as? Int, 2)
        XCTAssertEqual(steps[1]["status"] as? String, "failed")
        XCTAssertEqual(steps[1]["failure_code"] as? String, "stale_state")
        XCTAssertNil(record["steps"])
        XCTAssertNil(record["arguments"])
        XCTAssertNil(record["result_text"])
        let contents = try String(contentsOf: directory.appendingPathComponent(log.sessionID + ".jsonl"), encoding: .utf8)
        XCTAssertFalse(contents.contains("PRIVATE_"))
    }

    func testTypedFailureCodeOmitsTheOriginalErrorMessage() throws {
        let log = TrajectoryLog(environment: [:], directory: directory)
        log.recordFailedToolCall(
            name: "get_app_state", arguments: ["app": "PRIVATE_APP"],
            error: ComputerUseError.permissionDenied("PRIVATE_MESSAGE"), startedAt: started()
        )
        let record = try XCTUnwrap(records(log).first)
        XCTAssertEqual(record["failure_code"] as? String, "permission_denied")
        XCTAssertFalse(String(describing: record).contains("PRIVATE_"))
    }

    func testDispatcherProducesReceiptWhenBatchStopsBeforeSendingInput() throws {
        let arguments: [String: Any] = [
            "steps": [["tool": "wait", "text": "PRIVATE_LABEL"], ["tool": "click", "label": "PRIVATE_BUTTON"]],
        ]
        let result = try ComputerUseToolDispatcher().runBatch(arguments: arguments)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(Set(result.asDictionary.keys), ["content", "isError", "_meta"])

        let log = TrajectoryLog(environment: [:], directory: directory)
        log.recordToolCall(name: "batch", arguments: arguments, result: result, startedAt: started())
        let record = try XCTUnwrap(records(log).first)
        XCTAssertEqual(record["failure_code"] as? String, "invalid_arguments")
        XCTAssertEqual(record["batch_not_run"] as? Int, 1)
        XCTAssertEqual(record["batch_observation"] as? String, "unavailable")
        let steps = try XCTUnwrap(record["batch_step_receipts"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?["observation"] as? String, "not_sent")
        XCTAssertFalse(String(describing: record).contains("PRIVATE_"))
    }

    func testRecordHasTheAgreedFieldsAndSessionEndMarker() throws {
        let log = makeLog()
        log.recordToolCall(
            name: "type_text",
            arguments: ["app": "Notes", "text": "Buy milk"],
            result: .text("Typed 8 characters."),
            startedAt: started()
        )
        log.sessionEnded()

        let lines = try records(log)
        XCTAssertEqual(lines.count, 2)

        let call = lines[0]
        XCTAssertEqual(call["event"] as? String, "tool_call")
        XCTAssertEqual(call["tool"] as? String, "type_text")
        XCTAssertEqual(call["session_id"] as? String, log.sessionID)
        XCTAssertEqual(call["run_id"] as? String, "bench-7")
        XCTAssertEqual(call["is_error"] as? Bool, false)
        XCTAssertEqual(call["result_text"] as? String, "Typed 8 characters.")
        XCTAssertEqual(call["result_truncated"] as? Bool, false)
        XCTAssertEqual(call["screenshot_returned"] as? Bool, false)
        XCTAssertGreaterThan(try XCTUnwrap(call["duration_ms"] as? Double), 0)
        let arguments = try XCTUnwrap(call["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["app"] as? String, "Notes")
        XCTAssertEqual(arguments["text"] as? String, "Buy milk", "typed text stays in ordinary fields")
        let timestamp = try XCTUnwrap(call["timestamp"] as? String)
        XCTAssertNotNil(parseFractionalISO8601(timestamp), "timestamp is ISO 8601: \(timestamp)")

        XCTAssertEqual(lines[1]["event"] as? String, "session_end")
    }

    func testRunIDIsNotRequiredAndSessionIdIsAUUIDThen() throws {
        let log = makeLog(runID: nil)
        log.recordToolCall(name: "list_apps", arguments: [:], result: .text("Apps"), startedAt: started())
        let lines = try records(log)
        XCTAssertNil(lines[0]["run_id"] as? String)
        XCTAssertTrue(lines[0]["run_id"] is NSNull)
        XCTAssertEqual(log.sessionID.count, 36, "a fresh UUID per process when no run id is set")
    }

    func testFailedCallIsRecordedAsErrorWithItsMessage() throws {
        let log = makeLog()
        log.recordFailedToolCall(
            name: "click",
            arguments: ["app": "Notes", "label": "Missing"],
            error: ComputerUseError.message("No element named Missing"),
            startedAt: started()
        )
        let call = try XCTUnwrap(records(log).first)
        XCTAssertEqual(call["is_error"] as? Bool, true)
        XCTAssertEqual(call["result_text"] as? String, "No element named Missing")
    }

    func testScreenshotBytesAreOmittedButNoted() throws {
        let log = makeLog()
        let result = ToolCallResult(content: [
            .text("Notes window: 3 elements"),
            .pngImage(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])),
        ])
        log.recordToolCall(name: "get_app_state", arguments: ["app": "Notes"], result: result, startedAt: started())

        let line = try XCTUnwrap(records(log).first)
        XCTAssertEqual(line["screenshot_returned"] as? Bool, true)
        XCTAssertEqual(line["result_text"] as? String, "Notes window: 3 elements")
        let raw = try String(contentsOf: directory.appendingPathComponent(log.sessionID + ".jsonl"), encoding: .utf8)
        XCTAssertFalse(raw.contains(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()))
    }

    func testLongResultTextIsCutToTheLimit() throws {
        let log = makeLog()
        let long = String(repeating: "a", count: TrajectoryLog.resultTextLimit + 2_000)
        log.recordToolCall(name: "get_app_state", arguments: ["app": "Notes"], result: .text(long), startedAt: started())

        let line = try XCTUnwrap(records(log).first)
        XCTAssertEqual((line["result_text"] as? String)?.count, TrajectoryLog.resultTextLimit)
        XCTAssertEqual(line["result_truncated"] as? Bool, true)
    }

    // MARK: - Password and secure-field redaction

    func testSecureTargetDropsTypedAndFilledValues() throws {
        let log = makeLog()
        log.recordToolCall(
            name: "set_value",
            arguments: ["app": "Login", "label": "Password", "value": "hunter2"],
            result: .text("Set."),
            startedAt: started()
        )
        log.recordToolCall(
            name: "type_text",
            arguments: ["app": "Login", "label": "Secure text field", "text": "correct horse"],
            result: .text("Typed."),
            startedAt: started()
        )
        let lines = try records(log)
        XCTAssertEqual((lines[0]["arguments"] as? [String: Any])?["value"] as? String, TrajectoryLog.redactedValue)
        XCTAssertEqual((lines[0]["arguments"] as? [String: Any])?["label"] as? String, "Password", "the target name stays")
        XCTAssertEqual((lines[1]["arguments"] as? [String: Any])?["text"] as? String, TrajectoryLog.redactedValue)

        let raw = try String(contentsOf: directory.appendingPathComponent(log.sessionID + ".jsonl"), encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2"))
        XCTAssertFalse(raw.contains("correct horse"))
    }

    func testFillMapRedactsOnlySecureEntries() {
        let sanitized = TrajectoryLog.sanitize([
            "app": "Sign up",
            "fields": ["Password": "p4ss", "Email": "sam@example.com"],
        ])
        let fields = sanitized["fields"] as? [String: Any]
        XCTAssertEqual(fields?["Password"] as? String, TrajectoryLog.redactedValue)
        XCTAssertEqual(fields?["Email"] as? String, "sam@example.com")
    }

    func testBatchStepsAreRedactedIndividually() {
        let sanitized = TrajectoryLog.sanitize([
            "app": "Login",
            "steps": [
                ["tool": "set_value", "label": "Passcode", "value": "1234"],
                ["tool": "set_value", "label": "Name", "value": "Michael"],
            ],
        ])
        let steps = sanitized["steps"] as? [[String: Any]]
        XCTAssertEqual(steps?[0]["value"] as? String, TrajectoryLog.redactedValue)
        XCTAssertEqual(steps?[1]["value"] as? String, "Michael")
    }

    func testSecureFieldValueInResultTextIsRedacted() {
        let redacted = TrajectoryLog.redactSecureLines(
            "secure text field \"Password\" Value: hunter2\nTextField \"Name\" Value: Michael"
        )
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("secure text field \"Password\" Value: [redacted]"))
        XCTAssertTrue(redacted.contains("Michael"), "ordinary fields keep their values")
    }

    // MARK: - Size cap

    func testSessionStopsAfterTheCapWithOneNote() throws {
        let log = makeLog(maxBytes: 900)
        for index in 0..<10 {
            log.recordToolCall(
                name: "click",
                arguments: ["app": "Notes", "label": "Button \(index)"],
                result: .text("Clicked button \(index)."),
                startedAt: started()
            )
        }
        log.sessionEnded()

        let lines = try records(log)
        let notes = lines.filter { $0["event"] as? String == "log_capped" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(lines.last?["event"] as? String, "log_capped")
        let calls = lines.filter { $0["event"] as? String == "tool_call" }
        XCTAssertGreaterThan(calls.count, 0)
        XCTAssertLessThan(calls.count, 10)

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(log.sessionID + ".jsonl").path)[.size] as? NSNumber)
        XCTAssertLessThanOrEqual(size.uint64Value, 900 + 300, "the file stays near the cap")
    }

    // MARK: - Receipts and folder cap

    func testBatchReplyGetsPerStepEffectsAndCheck() throws {
        let log = makeLog()
        let reply = "1. click \"Save\": ok\n   effect: 4 button Save disabled\n   new: 9 sheet Save\n2. type_text {\"text\": \"a: b\"}: FAILED: stale\nSteps 3-3 were not run.\nCheck: the state may be stale (90% sure). Read it"
        log.recordToolCall(name: "batch", arguments: ["app": "Notes"], result: .text(reply), startedAt: started())
        let calls = try records(log).filter { $0["event"] as? String == "tool_call" }
        let steps = try XCTUnwrap(calls.first?["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0]["effects"] as? [String], ["effect: 4 button Save disabled", "new: 9 sheet Save"])
        XCTAssertEqual(steps[1]["step"] as? String, "type_text {\"text\": \"a: b\"}")
        XCTAssertEqual(steps[1]["result"] as? String, "FAILED: stale")
        XCTAssertTrue((steps[1]["not_run"] as? String)?.hasPrefix("Steps 3-3") == true)
        XCTAssertTrue((calls.first?["check"] as? String)?.hasPrefix("Check:") == true)
    }

    func testPlainReplyHasNoStepsField() throws {
        let log = makeLog()
        log.recordToolCall(name: "list_apps", arguments: [:], result: .text("Safari\nNotes"), startedAt: started())
        let calls = try records(log).filter { $0["event"] as? String == "tool_call" }
        XCTAssertNil(calls.first?["steps"])
    }

    func testOldestSessionFilesAreDeletedWhenFolderIsOverItsCap() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("old.jsonl")
        try Data(repeating: 0x61, count: 5_000).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: old.path)
        let log = TrajectoryLog(
            environment: [TrajectoryLog.runIDVariable: "new-run"], directory: directory, directoryMaxBytes: 1_000
        )
        log.recordToolCall(name: "click", arguments: [:], result: .text("ok"), startedAt: started())
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(log.sessionID + ".jsonl").path))
    }

    // MARK: - Files and folders

    func testFolderIs0700AndFileIs0600() throws {
        let log = makeLog()
        log.recordToolCall(name: "list_apps", arguments: [:], result: .text("Apps"), startedAt: started())
        log.flush()

        let folder = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(folder.intValue & 0o777, 0o700)
        let file = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(log.sessionID + ".jsonl").path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(file.intValue & 0o777, 0o600)
    }

    func testRunIDCannotEscapeTheTrajectoryFolder() throws {
        let log = makeLog(runID: "../../escape me")
        XCTAssertFalse(log.sessionID.contains("/"))
        XCTAssertFalse(log.sessionID.hasPrefix("."))
        log.recordToolCall(name: "list_apps", arguments: [:], result: .text("Apps"), startedAt: started())
        log.flush()
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(written, [log.sessionID + ".jsonl"])
    }

    func testUnwritableFolderNeverThrowsIntoTheCall() {
        // The "folder" is a regular file, so creating the trajectory folder inside it must fail quietly.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("trajectory-blocker-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: blocker) }

        let log = TrajectoryLog(
            environment: [TrajectoryLog.enabledVariable: "1"],
            directory: blocker.appendingPathComponent("trajectories", isDirectory: true)
        )
        log.recordToolCall(name: "list_apps", arguments: [:], result: .text("Apps"), startedAt: started())
        log.recordFailedToolCall(name: "click", arguments: [:], error: ComputerUseError.message("x"), startedAt: started())
        log.sessionEnded()
        log.flush()
    }

    func testTypingIntoFocusedPasswordFieldIsRedacted() {
        let state = "App=X\n\t3 secure text field Password (focused, w:str)"
        XCTAssertTrue(TrajectoryLog.focusesSecureField(state))
        XCTAssertFalse(TrajectoryLog.focusesSecureField("App=X\n\t3 text field Name (focused)"))
        let redacted = TrajectoryLog.redactTypedValues([
            "steps": [["tool": "type_text", "text": "hunter2"]],
            "text": "hunter2",
        ])
        XCTAssertEqual(redacted["text"] as? String, TrajectoryLog.redactedValue)
        let step = (redacted["steps"] as? [[String: Any]])?.first
        XCTAssertEqual(step?["text"] as? String, TrajectoryLog.redactedValue)
        XCTAssertEqual(step?["tool"] as? String, "type_text")
    }
}

private func parseFractionalISO8601(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}
