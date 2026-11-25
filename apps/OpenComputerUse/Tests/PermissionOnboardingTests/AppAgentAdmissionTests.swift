import Dispatch
import Foundation
import OpenComputerUseKit
import XCTest
@testable import OpenComputerUse

final class AppAgentAdmissionTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        func read() -> TimeInterval { lock.withLock { value } }
        func advance(_ amount: TimeInterval) { lock.withLock { value += amount } }
    }

    func testExpiredQueuedWorkDoesNotRunWhenAdmissionBecomesAvailable() throws {
        let clock = Clock()
        let gate = AppAgentAdmission(environment: [:], now: { clock.read() })
        let finished = DispatchSemaphore(value: 0)
        try gate.withAdmission(.exclusive) {
            DispatchQueue.global().async {
                defer { finished.signal() }
                do {
                    try gate.withAdmission(.exclusive, timeout: 1) {
                        XCTFail("Expired queued work reached dispatch")
                    }
                } catch {
                    XCTAssertTrue(error is AppAgentAdmission.Timeout, "\(error)")
                }
            }
            XCTAssertTrue(waitForQueue(gate, count: 1))
            clock.advance(2)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(gate.waitingCount, 0)
        // An expired ticket must not retain or poison the released gate.
        try gate.withAdmission(.exclusive, timeout: 0) {}
    }

    func testInvalidAdmissionBudgetsNeverRunEvenWhenGateIsFree() {
        let gate = AppAgentAdmission(environment: [:])
        for timeout in [TimeInterval.nan, .infinity, -.infinity, -1] {
            XCTAssertThrowsError(try gate.withAdmission(.exclusive, timeout: timeout) {
                XCTFail("Invalid admission budget reached dispatch")
            }) { error in XCTAssertTrue(error is AppAgentAdmission.Timeout) }
            XCTAssertEqual(gate.waitingCount, 0)
        }
        XCTAssertNoThrow(try gate.withAdmission(.exclusive, timeout: 0) {})
    }

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

    func testWaitingPeekLeavesRoomForReadsAndYieldsToWriter() throws {
        let gate = AppAgentAdmission(environment: ["OPEN_COMPUTER_USE_PARALLEL_READS": "2"])
        let finished = DispatchGroup()
        let writerRan = DispatchSemaphore(value: 0)
        let peekRan = DispatchSemaphore(value: 0)

        try gate.withAdmission(.browserPeek(client: "first")) {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do {
                    try gate.withAdmission(.browserPeek(client: "second"), timeout: 5) {
                        XCTAssertEqual(writerRan.wait(timeout: .now()), .success)
                        peekRan.signal()
                    }
                } catch { XCTFail("Second peek failed: \(error)") }
            }
            XCTAssertTrue(waitForQueue(gate, count: 1))
            try gate.withAdmission(.browserRead(client: "ordinary"), timeout: 0) {}
            XCTAssertEqual(peekRan.wait(timeout: .now()), .timedOut)
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do {
                    try gate.withAdmission(.exclusive, timeout: 5) { _ = writerRan.signal() }
                } catch { XCTFail("Writer failed: \(error)") }
            }
            XCTAssertTrue(waitForQueue(gate, count: 2))
            XCTAssertThrowsError(try gate.withAdmission(.browserRead(client: "late"), timeout: 0) {})
        }
        XCTAssertEqual(peekRan.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    func testWriteLanesRequireOptInAndExcludeTheSameTabAndNativeInput() throws {
        let first = AppAgentAdmission.Mode.browserTabWrite(client: "a", tabID: 17)
        let second = AppAgentAdmission.Mode.browserTabWrite(client: "b", tabID: 18)
        let serial = AppAgentAdmission(environment: [:])
        try serial.withAdmission(first, timeout: 0) {
            XCTAssertThrowsError(try serial.withAdmission(second, timeout: 0) {})
        }
        let parallel = AppAgentAdmission(environment: ["OPEN_COMPUTER_USE_PARALLEL_BROWSER_WRITES": "1"])
        try parallel.withAdmission(first, timeout: 0) {
            XCTAssertThrowsError(try parallel.withAdmission(.browserTabWrite(client: "b", tabID: 17), timeout: 0) {})
            XCTAssertThrowsError(try parallel.withAdmission(.browserTabWrite(client: "a", tabID: 19), timeout: 0) {})
            XCTAssertThrowsError(try parallel.withAdmission(.exclusive, timeout: 0) {})
            try parallel.withAdmission(second, timeout: 0) {}
        }
    }

    func testTwoClientsWriteOnlyTheirOwnedTabsThroughSeparateHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("obu-fixture")
        try """
        #!/usr/bin/python3
        import json, os, pathlib, sys, time

        root = pathlib.Path(os.environ["OBU_WRITE_FIXTURE_DIR"])
        tab = int(os.environ["OBU_WRITE_FIXTURE_TAB"])
        for line in sys.stdin:
            req = json.loads(line)
            if "id" not in req:
                continue
            params = req.get("params", {})
            name = params.get("name")
            result = {}
            if name == "open_tab":
                result = {"content": [{"type": "text", "text": json.dumps({"result": {"tab": {"id": tab}}})}]}
            if name == "cdp":
                args = params["arguments"]
                if args["tab_id"] != tab or args["method"] != "Runtime.evaluate":
                    sys.exit(4)
                marker = root / (str(tab) + ".write")
                with marker.open("a") as effects:
                    effects.write("once" + chr(10))
                deadline = time.monotonic() + 5
                while len(list(root.glob("*.write"))) < 2 and time.monotonic() < deadline:
                    time.sleep(0.01)
                ok = len(list(root.glob("*.write"))) == 2
                result = {"isError": not ok, "content": [
                    {"type": "text", "text": json.dumps({"result":{"result":{"value":[20,100]}}})}
                ]}
            print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}), flush=True)
            if name == "turn_ended":
                break
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let gate = AppAgentAdmission(environment: ["OPEN_COMPUTER_USE_PARALLEL_BROWSER_WRITES": "1"])
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let tab = 71 + index
            let client = "write-\(index)-" + UUID().uuidString.prefix(20)
            let environment = [
                "OPEN_COMPUTER_USE_BROWSER": "1",
                "OPEN_COMPUTER_USE_OBU_BIN": executable.path,
                "OPEN_COMPUTER_USE_TRAJECTORY_LOG": "0",
                "OBU_WRITE_FIXTURE_DIR": root.path,
                "OBU_WRITE_FIXTURE_TAB": String(tab),
            ]
            let server = StdioMCPServer(backgroundStateReset: {}, trajectoryEnvironment: environment)
            do {
                try ClientScope.with(client) {
                    try withBrowserRequestEnvironment(environment) {
                        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                            "params": ["name": "browser", "arguments": ["action": "scroll", "tab_id": tab]]]
                        let mode = try XCTUnwrap(AppAgentBrowserRead.mode(
                            payload, client: client, allowWrites: gate.parallelTabWrites
                        ))
                        XCTAssertEqual(mode.tabWrite, tab)
                        XCTAssertNil(AppAgentBrowserRead.mode(payload, client: client, allowWrites: false))
                        XCTAssertThrowsError(try withOwnedBrowserTabWrite(tab) {})
                        let open = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser","arguments":{"action":"open"}}}"#
                        try gate.withAdmission(.exclusive, timeout: 10) {
                            XCTAssertTrue(server.handle(line: open)?.contains("opened a blank tab") == true)
                        }
                        defer { try? gate.withAdmission(.exclusive) { server.endSession() } }
                        XCTAssertThrowsError(try withOwnedBrowserTabWrite(tab + 10) {})
                        let line = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                        let reply = try gate.withAdmission(mode, timeout: 10) {
                            try withOwnedBrowserTabWrite(tab) { server.handle(line: line) }
                        }
                        XCTAssertTrue(reply?.contains("scrolled") == true, reply ?? "(no reply)")
                    }
                }
            } catch { XCTFail("Browser fixture write failed: \(error)") }
        }
        for tab in 71...72 {
            let marker = root.appendingPathComponent("\(tab).write")
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "once\n")
        }
    }

    func testInferenceReleasesExclusiveAndCancelsWhenAnInterleavedRequestRan() throws {
        let gate = AppAgentAdmission(environment: [:])
        let token = RequestCancellation()
        try RequestCancellation.$current.withValue(token) {
            try gate.withAdmission(.exclusive) {
                let outside = try XCTUnwrap(RequestInferenceAdmission.withoutExclusive)
                XCTAssertThrowsError(try outside {
                    do {
                        try gate.withAdmission(.exclusive, timeout: 0) {}
                    } catch { XCTFail("Inference still owned desktop admission: \(error)") }
                    return Data([1])
                }) { error in XCTAssertTrue(error is AppAgentAdmission.AdmissionLost, "\(error)") }
                XCTAssertTrue(token.isCancelled)
            }
        }
        try gate.withAdmission(.exclusive, timeout: 0) {}
    }

    func testInferenceThrowsInsteadOfContinuingWhenTheGateIsHeldPastTwoSeconds() throws {
        let gate = AppAgentAdmission(environment: [:])
        let token = RequestCancellation()
        let holding = DispatchGroup()
        try RequestCancellation.$current.withValue(token) {
            try gate.withAdmission(.exclusive) {
                let outside = try XCTUnwrap(RequestInferenceAdmission.withoutExclusive)
                let acquired = DispatchSemaphore(value: 0)
                XCTAssertThrowsError(try outside {
                    holding.enter()
                    DispatchQueue.global().async {
                        defer { holding.leave() }
                        try? gate.withAdmission(.exclusive, timeout: 10) {
                            acquired.signal()
                            Thread.sleep(forTimeInterval: 2.5)
                        }
                    }
                    XCTAssertEqual(acquired.wait(timeout: .now() + 5), .success)
                    return Data([1])
                }) { error in XCTAssertTrue(error is AppAgentAdmission.AdmissionLost, "\(error)") }
                XCTAssertTrue(token.isCancelled)
            }
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 10), .success)
    }

    func testCancellingTwentyQueuedClientsReleasesTheirTickets() throws {
        let gate = AppAgentAdmission(environment: [:])
        let requests = (0..<20).map { _ in RequestCancellation() }
        let finished = DispatchGroup()
        try gate.withAdmission(.exclusive) {
            for (index, token) in requests.enumerated() {
                finished.enter()
                Thread.detachNewThread {
                    defer { finished.leave() }
                    do {
                        try RequestCancellation.$current.withValue(token) {
                            try gate.withAdmission(.browserRead(client: "queued-\(index)")) {
                                XCTFail("Cancelled request reached dispatch")
                            }
                        }
                    } catch {
                        XCTAssertTrue(error is RequestCancellation.Cancelled)
                    }
                }
            }
            XCTAssertTrue(waitForQueue(gate, count: 20))
            requests.forEach { $0.cancel() }
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(gate.waitingCount, 0)
        }
        try gate.withAdmission(.exclusive, timeout: 0) {}
    }

    private func waitForQueue(_ gate: AppAgentAdmission, count: Int) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if gate.waitingCount == count { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
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
