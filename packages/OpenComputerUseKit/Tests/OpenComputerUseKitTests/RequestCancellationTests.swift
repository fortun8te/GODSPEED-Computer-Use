import XCTest
@testable import OpenComputerUseKit

final class RequestCancellationTests: XCTestCase {
    func testCancelledBatchReportsTheStepsItSkipped() throws {
        let token = RequestCancellation()
        token.cancel()
        let result = try RequestCancellation.$current.withValue(token) {
            try ComputerUseToolDispatcher(service: ComputerUseService()).runBatch(arguments: [
                "steps": [["tool": "list_apps"], ["tool": "list_apps"]],
            ])
        }
        XCTAssertEqual(result.batchReceipt?.steps.count, 0)
        XCTAssertEqual(result.batchReceipt?.stop?.rawValue, "cancelled")
        XCTAssertTrue(result.textContent.contains("Steps 1-2 were not run"))
    }

    func testCancelDuringHandoffChoiceKeepsEarlierStepAndSkipsTheNext() throws {
        let request = try HandoffTool.parse([
            "app": "Fixture", "window_id": 31, "goal": "Continue",
            "done_when": ["text": "Finished"],
        ])
        let stream = MCPRequestStream()
        let line = #"{"method":"tools/call","id":1}"#
        stream.receive(line, rpcLine: line)
        let call = try XCTUnwrap(stream.next())
        var acts = 0
        var choices = 0
        let deps = HandoffTool.Dependencies(
            readState: { "App=Fixture\nWindow: \"Fixture\"\nWindow ID: 31\n3 button Continue\n4 button Next" },
            act: { _, _ in
                acts += 1
                return .init(ok: true, message: "ok")
            },
            choose: { _, _, _, _, options in
                choices += 1
                if choices == 2 {
                    let cancel = #"{"method":"notifications/cancelled","params":{"requestId":1}}"#
                    stream.receive(cancel, rpcLine: cancel)
                }
                guard let id = options.first?.id else { return nil }
                return ["none": 0, id: 1]
            },
            looksStuck: { _, _, _ in false },
            check: { _ in .missing(unmet: ["Finished"]) },
            replay: { _ in nil },
            now: { ProcessInfo.processInfo.systemUptime }
        )
        let outcome = RequestCancellation.$current.withValue(call.cancellation) {
            HandoffTool.run(request, deps)
        }
        XCTAssertEqual(choices, 2)
        XCTAssertEqual(acts, 1)
        XCTAssertEqual(outcome.steps.count, 1)
        XCTAssertTrue(outcome.reply().contains("cancelled"))
    }

    func testDisconnectRejectsPendingWorkAndSignalsActiveCall() throws {
        let stream = MCPRequestStream()
        let first = #"{"id":1,"method":"tools/call"}"#
        let later = #"{"id":2,"method":"tools/call"}"#
        stream.receive(first, rpcLine: first)
        stream.receive(later, rpcLine: later)
        let active = try XCTUnwrap(stream.next())
        stream.disconnect()
        XCTAssertTrue(active.cancellation.isCancelled)
        XCTAssertNil(stream.next())
    }

    func testCancellationIDsAreConnectionLocalAndTypeSensitive() throws {
        let first = MCPRequestStream()
        let second = MCPRequestStream()
        let line = #"{"id":1,"method":"tools/call"}"#
        for stream in [first, second] { stream.receive(line, rpcLine: line) }
        let wrongType = #"{"method":"notifications/cancelled","params":{"requestId":"1"}}"#
        let cancel = #"{"method":"notifications/cancelled","params":{"requestId":1}}"#
        first.receive(wrongType, rpcLine: wrongType)
        let one = try XCTUnwrap(first.next())
        XCTAssertFalse(one.cancellation.isCancelled)
        first.receive(cancel, rpcLine: cancel)
        XCTAssertTrue(one.cancellation.isCancelled)
        XCTAssertFalse(try XCTUnwrap(second.next()).cancellation.isCancelled)
    }

    func testReadAheadPreservesCancellationWhenTheQueueIsFull() throws {
        let stream = MCPRequestStream()
        let first = #"{"id":1,"method":"tools/call"}"#
        stream.receive(first, rpcLine: first)
        let active = try XCTUnwrap(stream.next())
        for id in 2...17 {
            let line = #"{"method":"tools/call","id":\#(id)}"#
            XCTAssertTrue(stream.receive(line, rpcLine: line))
        }
        let cancel = #"{"method":"notifications/cancelled","params":{"requestId":1}}"#
        XCTAssertTrue(stream.receive(cancel, rpcLine: cancel))
        XCTAssertTrue(active.cancellation.isCancelled)
        XCTAssertFalse(stream.receive(first, rpcLine: first))
    }

    func testCancellationInterruptsAHelperThatHasStoppedReading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("obu")
        try """
        #!/usr/bin/python3
        import json, sys, time
        request = json.loads(sys.stdin.readline())
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}), flush=True)
        sys.stdin.readline()
        time.sleep(3)
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let bridge = BrowserBridge(sessionID: "blocked-fixture", launchEnvironment: [
            "OPEN_COMPUTER_USE_BROWSER": "1", "OPEN_COMPUTER_USE_OBU_BIN": helper.path,
        ])
        defer { bridge.shutdown() }
        let token = RequestCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(350)) { token.cancel() }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try RequestCancellation.$current.withValue(token) {
            try bridge.callTool("cdp", arguments: ["fixture": String(repeating: "x", count: 1_048_576)], timeout: 5)
        })
        XCTAssertTrue(token.isCancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testCancelledBrowserWaitReturnsWithinTwoSeconds() {
        let token = RequestCancellation()
        let response = BrowserBridgeResponses()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { token.cancel() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = RequestCancellation.$current.withValue(token) { response.wait(for: 1, timeout: 3) }
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }
}
