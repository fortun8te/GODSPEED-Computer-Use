import XCTest
@testable import OpenComputerUseKit

final class DeliveryStateTests: XCTestCase {
    func testDeliveryStatesEncodeStableValues() throws {
        let values: [DeliveryState] = [.notSent, .outcomeUnknown, .acknowledged, .verified]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["not_sent","outcome_unknown","acknowledged","verified"]"#)
        XCTAssertEqual(try JSONDecoder().decode([DeliveryState].self, from: data), values)
    }

    func testNativeAXTimeoutIsUncertainAndAfterAckFailureRetainsDelivery() throws {
        XCTAssertThrowsError(try clickActionRan(.cannotComplete, action: "AXPress")) { error in
            let result = ToolCallResult.failure(error)
            XCTAssertEqual(result.failureCode, .timeout)
            XCTAssertEqual(result.deliveryState, .outcomeUnknown)
        }
        let afterAck = ToolCallResult.failure(ComputerUseError.acknowledged("Readback timed out"))
        XCTAssertTrue(afterAck.isError)
        XCTAssertEqual(afterAck.deliveryState, .acknowledged)
        XCTAssertEqual(afterAck.deliveryState.safeRetry, .doNotRetry)
    }

    func testWorkspaceTimeoutAfterDispatchRequiresReconciliation() {
        let sent = XCTestExpectation(description: "sent once")
        sent.assertForOverFulfill = true
        XCTAssertThrowsError(try SmartSteps.openWorkspace(timeout: 0.001) { _ in sent.fulfill() }) { error in
            let result = ToolCallResult.failure(error)
            XCTAssertEqual(result.deliveryState, .outcomeUnknown)
            XCTAssertEqual(result.failureCode, .timeout)
        }
        wait(for: [sent], timeout: 0.1)
    }

    func testSingleActionPublishesDeliveryWithoutReadingItsText() {
        let result = ComputerUseToolDispatcher().callToolAsResult(
            name: "clipboard", arguments: ["action": "write", "text": "outcome unknown"])
        let metadata = result.asDictionary["_meta"] as? [String: Any]
        XCTAssertEqual(metadata?["godspeed/delivery_state"] as? String, "acknowledged")
        XCTAssertEqual(metadata?["godspeed/safe_retry"] as? String, "do_not_retry")
    }

    func testValidationPublishesNotSentEvenWithTimeoutInArgument() {
        let result = ComputerUseToolDispatcher().callToolAsResult(
            name: "clipboard", arguments: ["action": "timed out"])
        let metadata = result.asDictionary["_meta"] as? [String: Any]
        XCTAssertEqual(metadata?["godspeed/delivery_state"] as? String, "not_sent")
        XCTAssertEqual(metadata?["godspeed/safe_retry"] as? String, "after_correction")
    }

    func testExistingFileIsOnlyWeakEvidenceAndCannotVerifyBatch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("old".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = ComputerUseToolDispatcher().callToolAsResult(name: "batch", arguments: [
            "steps": [["tool": "clipboard", "action": "write", "text": "new"]],
            "done_when": ["file_exists": url.path],
        ])
        XCTAssertFalse(result.isError)
        let metadata = result.asDictionary["_meta"] as? [String: Any]
        let batch = metadata?["godspeed/batch"] as? [String: Any]
        XCTAssertEqual(batch?["completion"] as? String, "weak_evidence")
        XCTAssertEqual(metadata?["godspeed/delivery_state"] as? String, "acknowledged")
    }

    func testFileChangedUsesTheBaselineFromBeforeStepOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = directory.appendingPathComponent("export.pdf")
        try Data("old".utf8).write(to: export)
        let helper = directory.appendingPathComponent("obu")
        let script = #"""
        #!/bin/sh
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        case "$request" in *'"name":"open_tab"'*) ;; *) exit 1;; esac
        printf '%s' 'new' > "$(dirname "$0")/export.pdf"
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"result\":{\"tab\":{\"id\":12}}}"}]}}'
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let result = ClientScope.with(UUID().uuidString) {
            withBrowserRequestEnvironment([
                "OPEN_COMPUTER_USE_BROWSER": "1", "OPEN_COMPUTER_USE_OBU_BIN": helper.path,
            ]) {
                ComputerUseToolDispatcher().callToolAsResult(name: "batch", arguments: [
                    "steps": [["tool": "browser", "action": "open"]],
                    "done_when": ["file_changed": export.path],
                ])
            }
        }
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.batchReceipt?.doneCheck, .verified)
        XCTAssertEqual(result.batchReceipt?.steps.first?.deliveryState, .acknowledged)
        XCTAssertEqual(result.deliveryState, .verified)
    }
    func testBrowserLostReplyStopsBatchAfterOneSend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("obu")
        let log = directory.appendingPathComponent("send.log")
        let script = #"""
        #!/bin/sh
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        case "$request" in *'"name":"open_tab"'*) printf '%s\n' sent >> "$(dirname "$0")/send.log";; *) exit 1;; esac
        # Accept the mutation and hold the connection open beyond the action deadline.
        exec /bin/sleep 3
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let result = try ClientScope.with(UUID().uuidString) {
            try withBrowserRequestEnvironment([
                "OPEN_COMPUTER_USE_BROWSER": "1", "OPEN_COMPUTER_USE_OBU_BIN": helper.path,
            ]) {
                try ComputerUseToolDispatcher().runBatch(arguments: [
                    "steps": [["tool": "browser", "action": "open"], ["tool": "browser", "action": "open"]],
                ], inheritedDeadline: ProcessInfo.processInfo.systemUptime + 2)
            }
        }
        XCTAssertTrue(result.isError)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "sent\n")
        let metadata = result.asDictionary["_meta"] as? [String: Any]
        let batch = metadata?["godspeed/batch"] as? [String: Any]
        let steps = batch?["steps"] as? [[String: Any]]
        XCTAssertEqual(steps?.count, 1)
        XCTAssertEqual(steps?.first?["failure_code"] as? String, "timeout")
        XCTAssertEqual(steps?.first?["delivery_state"] as? String, "outcome_unknown")
        XCTAssertEqual(steps?.first?["safe_retry"] as? String, "reconcile_first")
        XCTAssertEqual((batch?["recovery"] as? [String: Any])?["action"] as? String, "inspect_before_retry")
        XCTAssertEqual(batch?["not_run"] as? Int, 1)
    }
}
