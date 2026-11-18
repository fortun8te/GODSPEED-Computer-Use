import Dispatch
import Foundation
import OpenComputerUseKit
import XCTest
@testable import OpenComputerUse

final class AppAgentAdmissionTests: XCTestCase {
    func testAllowsThreeDistinctReadersAndOnlyOnePerClient() throws {
        let gate = AppAgentAdmission()

        try gate.withAdmission(.browserRead(client: "a")) {
            XCTAssertThrowsError(try gate.withAdmission(.browserRead(client: "a"), timeout: 0) {})
            XCTAssertThrowsError(try gate.withAdmission(.browserRead(client: ""), timeout: 0) {})
            try gate.withAdmission(.browserRead(client: "b"), timeout: 0) {
                try gate.withAdmission(.browserRead(client: "c"), timeout: 0) {
                    XCTAssertThrowsError(try gate.withAdmission(.browserRead(client: "d"), timeout: 0) {})
                    XCTAssertThrowsError(try gate.withAdmission(.exclusive, timeout: 0) {})
                }
                try gate.withAdmission(.browserRead(client: "d"), timeout: 0) {}
            }
        }
    }

    func testTwoReadersOverlapThroughSeparateBrowserHelpers() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("godspeed-overlap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let executable = fixture.appendingPathComponent("obu-fixture")
        try """
        #!/usr/bin/python3
        import json, os, pathlib, sys, time

        root = pathlib.Path(os.environ["OBU_OVERLAP_DIR"])
        session = sys.argv[sys.argv.index("--session-id") + 1]
        for line in sys.stdin:
            req = json.loads(line)
            if "id" not in req:
                continue
            name = req.get("params", {}).get("name")
            result = {}
            if name == "tabs":
                (root / (session + ".ready")).touch()
                deadline = time.monotonic() + 5
                while len(list(root.glob("*.ready"))) < 2 and time.monotonic() < deadline:
                    time.sleep(0.01)
                ok = len(list(root.glob("*.ready"))) == 2
                text = json.dumps([{"id": 1, "url": "https://fixture.test/overlap"}]) if ok else "second reader never arrived"
                result = {"isError": not ok, "content": [{"type": "text", "text": text}]}
            print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}), flush=True)
            if name == "turn_ended":
                break
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let environment = [
            "OPEN_COMPUTER_USE_BROWSER": "1",
            "OPEN_COMPUTER_USE_OBU_BIN": executable.path,
            "OPEN_COMPUTER_USE_TRAJECTORY_LOG": "0",
            "OBU_OVERLAP_DIR": fixture.path,
        ]
        let gate = AppAgentAdmission()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let client = "overlap-\(UUID().uuidString.lowercased())-\(index)"
            let server = StdioMCPServer(backgroundStateReset: {}, trajectoryEnvironment: environment)
            do {
                try gate.withAdmission(.browserRead(client: client), timeout: 7) {
                    ClientScope.with(client) {
                        withBrowserRequestEnvironment(environment) {
                            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser","arguments":{"action":"tabs"}}}"#
                            let reply = server.handle(line: line) ?? ""
                            XCTAssertTrue(reply.contains("fixture.test/overlap"), reply)
                            server.endSession()
                        }
                    }
                }
            } catch {
                XCTFail("Browser fixture read failed: \(error)")
            }
        }
        let ready = try FileManager.default.contentsOfDirectory(atPath: fixture.path).filter { $0.hasSuffix(".ready") }
        XCTAssertEqual(ready.count, 2)
    }

    func testQueuedWriterPreventsNewReadersUntilItCompletes() throws {
        let gate = AppAgentAdmission()
        let writerAcquired = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }

        try gate.withAdmission(.browserRead(client: "first")) {
            DispatchQueue.global().async {
                defer { writerDone.signal() }
                do {
                    try gate.withAdmission(.exclusive, timeout: 5) {
                        writerAcquired.signal()
                        XCTAssertEqual(releaseWriter.wait(timeout: .now() + 5), .success)
                    }
                } catch {
                    XCTFail("Queued writer failed: \(error)")
                }
            }

            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while gate.waitingExclusiveCount == 0, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            XCTAssertEqual(gate.waitingExclusiveCount, 1)
            XCTAssertEqual(writerAcquired.wait(timeout: .now()), .timedOut)
            XCTAssertThrowsError(try gate.withAdmission(.browserRead(client: "new"), timeout: 0) {})
        }

        XCTAssertEqual(writerAcquired.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try gate.withAdmission(.browserRead(client: "new"), timeout: 0) {})
        XCTAssertThrowsError(try gate.withAdmission(.exclusive, timeout: 0) {})
        releaseWriter.signal()
        XCTAssertEqual(writerDone.wait(timeout: .now() + 2), .success)
        try gate.withAdmission(.browserRead(client: "new"), timeout: 0) {}
    }

    func testThrowingBodiesAndTimedOutWritersReleaseAdmission() throws {
        struct BodyFailure: Error {}
        let gate = AppAgentAdmission()

        XCTAssertThrowsError(try gate.withAdmission(.exclusive) { throw BodyFailure() }) {
            XCTAssertTrue($0 is BodyFailure)
        }
        XCTAssertThrowsError(try gate.withAdmission(.browserRead(client: "owner")) {
            XCTAssertThrowsError(try gate.withAdmission(.exclusive, timeout: 0.01) {}) {
                XCTAssertTrue($0 is AppAgentAdmission.Timeout)
            }
            XCTAssertEqual(gate.waitingExclusiveCount, 0)
            try gate.withAdmission(.browserRead(client: "other"), timeout: 0) {}
            throw BodyFailure()
        }) { XCTAssertTrue($0 is BodyFailure) }

        let empty: String? = try gate.withAdmission(.exclusive, timeout: 0) { nil }
        XCTAssertNil(empty)
    }
}
