import Darwin
import Foundation
import XCTest
@testable import OpenComputerUse
@testable import OpenComputerUseKit

final class AppAgentProxyTests: XCTestCase {
    private func socketPair(requestTimeout: timeval = timeval(tv_sec: 5, tv_usec: 0)) throws -> (client: AppAgentSocketClient, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.EIO) }
        guard let file = fdopen(descriptors[0], "r+") else {
            close(descriptors[0])
            close(descriptors[1])
            throw POSIXError(.EIO)
        }
        var buffer: Int32 = 4096
        setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        // Bound a broken regression even if cancellation fails to interrupt it.
        var timeout = requestTimeout
        for descriptor in descriptors {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return (AppAgentSocketClient(file: file), descriptors[1])
    }

    func testCancelledSocketRequestSendsNothingAndKeepsConnectionReusable() throws {
        let (client, peer) = try socketPair()
        defer { close(peer) }
        let token = RequestCancellation()
        token.cancel()
        XCTAssertThrowsError(try client.request(["kind": "mcp", "line": "request"], cancellation: token, rpcID: 1)) { error in
            XCTAssertEqual((error as? RequestCancellation.Cancelled)?.deliveryState, .notSent)
        }
        var byte: UInt8 = 0
        XCTAssertEqual(recv(peer, &byte, 1, MSG_DONTWAIT), -1)
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
        XCTAssertFalse(client.needsReconnect)
    }

    func testCancellationInterruptsRequestWriteToAnAgentThatStoppedReading() throws {
        let (client, peer) = try socketPair()
        defer { close(peer) }
        let token = RequestCancellation()
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            // Wait until sending has started, then stop reading. The entire
            // request cannot fit in this socket's small send buffer.
            XCTAssertEqual(recv(peer, &byte, 1, 0), 1)
            token.cancel()
            cancelled.signal()
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client.request([
            "kind": "mcp", "line": String(repeating: "x", count: 4 * 1024 * 1024),
        ], cancellation: token, rpcID: 17)) { error in
            XCTAssertEqual((error as? RequestCancellation.Cancelled)?.deliveryState, .outcomeUnknown)
        }
        XCTAssertEqual(cancelled.wait(timeout: .now() + 2), .success)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertTrue(client.needsReconnect)
        XCTAssertThrowsError(try client.request(["kind": "agentInfo"])) { error in
            XCTAssertTrue(error is AppAgentConnectionLost)
        }
    }

    func testClosedAgentConnectionIsNotReusedForLaterRequests() throws {
        let (client, peer) = try socketPair()
        close(peer)
        XCTAssertThrowsError(try client.request(["kind": "agentInfo"])) { error in
            XCTAssertTrue(error is AppAgentConnectionLost, "\(error)")
        }
        XCTAssertTrue(client.needsReconnect)
        XCTAssertThrowsError(try client.request(["kind": "agentInfo"])) { error in
            XCTAssertTrue(error is AppAgentConnectionLost)
        }
    }

    func testMalformedAgentReplyInvalidatesTheConnection() throws {
        let (client, peer) = try socketPair()
        defer { close(peer) }
        let malformed = Data("{broken}\n".utf8)
        XCTAssertEqual(malformed.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }, malformed.count)
        XCTAssertThrowsError(try client.request(["kind": "agentInfo"])) { error in
            XCTAssertTrue(error is AppAgentConnectionLost, "\(error)")
        }
        XCTAssertTrue(client.needsReconnect)
    }

    func testResponseTimeoutSignalsDisconnectBeforeAnotherRequestArrives() throws {
        let (client, peer) = try socketPair(requestTimeout: timeval(tv_sec: 0, tv_usec: 100_000))
        defer { close(peer) }
        XCTAssertThrowsError(try client.request(["kind": "agentInfo"])) { error in
            XCTAssertTrue(error is AppAgentResponseTimeout, "\(error)")
        }
        let capacity = 1024
        var bytes = [UInt8](repeating: 0, count: capacity)
        // The small request remains buffered at the peer, followed immediately
        // by EOF. There is no need for another MCP call to trigger cleanup.
        XCTAssertGreaterThan(recv(peer, &bytes, capacity, MSG_DONTWAIT), 0)
        XCTAssertEqual(recv(peer, &bytes, capacity, MSG_DONTWAIT), 0)
        XCTAssertTrue(client.needsReconnect)
    }

    func testRequestOptionsNeverChangeTheProcessEnvironment() throws {
        let key = "OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION"
        let host = ProcessInfo.processInfo.environment[key]
        for dimension in ["321", "654"] {
            try AppAgentEnvironment.withOverrides([key: dimension]) {
                XCTAssertEqual(ImageCaptureConfig.current.maxDimension, Double(dimension).map { CGFloat($0) })
                XCTAssertEqual(ProcessInfo.processInfo.environment[key], host)
            }
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment[key], host)
    }

    func testConcurrentRequestsKeepConflictingOptions() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            AppAgentEnvironment.withConfiguration([
                "OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION": "321",
                "OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT": "0",
                "OPEN_COMPUTER_USE_BACKGROUND_ONLY": "1",
            ]) {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                XCTAssertEqual(ImageCaptureConfig.current.maxDimension, 321)
                XCTAssertFalse(LeanDefaults.includeScreenshot)
                XCTAssertTrue(backgroundOnlyMode())
            }
            finished.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        AppAgentEnvironment.withConfiguration([
            "OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION": "654",
            "OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT": "1",
            "OPEN_COMPUTER_USE_BACKGROUND_ONLY": "0",
        ]) {
            XCTAssertEqual(ImageCaptureConfig.current.maxDimension, 654)
            XCTAssertTrue(LeanDefaults.includeScreenshot)
            XCTAssertFalse(backgroundOnlyMode())
        }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    func testTimeoutReplyCarriesDeliveryEvenWhenMessagesMatch() {
        let before = MacOSAppAgentProxy.mcpFailureReply(id: 17, message: "deadline", delivery: .notSent)
        let after = MacOSAppAgentProxy.mcpFailureReply(id: 17, message: "deadline", delivery: .outcomeUnknown)
        let notSent = (before["error"] as? [String: Any])?["data"] as? [String: String]
        let unknown = (after["error"] as? [String: Any])?["data"] as? [String: String]
        XCTAssertEqual(notSent?["delivery_state"], "not_sent")
        XCTAssertEqual(notSent?["safe_retry"], "after_correction")
        XCTAssertEqual(unknown?["delivery_state"], "outcome_unknown")
        XCTAssertEqual(unknown?["safe_retry"], "reconcile_first")
        XCTAssertNotNil(unknown?["reconcile"])
    }

    func testCursorNameUsesOnlyKnownClientInitializationMetadata() {
        XCTAssertEqual(
            MacOSAppAgentProxy.knownCursorClientName(initializeLine: #"{"method":"initialize","params":{"clientInfo":{"name":"codex-mcp-client","version":"1.0"}}}"#),
            "Codex"
        )
        XCTAssertNil(MacOSAppAgentProxy.knownCursorClientName(
            initializeLine: #"{"method":"initialize","params":{"clientInfo":{"name":"private-project-owner"}}}"#
        ))
        XCTAssertNil(MacOSAppAgentProxy.knownCursorClientName(
            initializeLine: #"{"method":"tools/call","params":{"clientInfo":{"name":"codex"}}}"#
        ))
    }

    func testInferredCursorNameDoesNotShadowSavedOrExplicitNickname() {
        let line = #"{"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#
        let inferred = MacOSAppAgentProxy.addingCursorClientName(to: [:], initializeLine: line)
        XCTAssertNil(inferred["OPEN_COMPUTER_USE_CURSOR_NAME"])
        XCTAssertEqual(inferred["OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME"], "Claude Code")
        XCTAssertEqual(VisualCursorSettings(environment: GodspeedSettings.merged(inferred, settings: [:])).agentName,
                       "Claude Code")
        XCTAssertEqual(VisualCursorSettings(environment: GodspeedSettings.merged(inferred, settings: ["cursor_name": "Studio"])).agentName,
                       "Studio")
        let explicit = MacOSAppAgentProxy.addingCursorClientName(to: ["OPEN_COMPUTER_USE_CURSOR_NAME": "Editor"], initializeLine: line)
        XCTAssertEqual(VisualCursorSettings(environment: GodspeedSettings.merged(explicit, settings: ["cursor_name": "Studio"])).agentName,
                       "Editor")
        // Returning the preference to automatic reuses the connection's inferred identity.
        XCTAssertEqual(VisualCursorSettings(environment: GodspeedSettings.merged(inferred, settings: [:])).agentName,
                       "Claude Code")
    }

    func testCursorIdentityRejectsInvalidNamesAndDoesNotLeakFromHostToAnotherClient() {
        let invalid = ["OPEN_COMPUTER_USE_CURSOR_NAME": "\u{001B}[31mprivate",
                       "OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME": "Codex"]
        XCTAssertEqual(VisualCursorSettings(environment: invalid).agentName, "Codex")
        XCTAssertNil(VisualCursorSettings(environment: ["OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME": "Project\nSecret"]).agentName)
        let host = ["OPEN_COMPUTER_USE_CURSOR_NAME": "Host", "OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME": "Codex"]
        let clean = AppAgentEnvironment.effectiveEnvironment([:], launchEnvironment: host)
        XCTAssertNil(clean["OPEN_COMPUTER_USE_CURSOR_NAME"])
        XCTAssertNil(clean["OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME"])
        let client = AppAgentEnvironment.effectiveEnvironment(["OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME": "Claude"],
                                                              launchEnvironment: host)
        XCTAssertEqual(VisualCursorSettings(environment: client).agentName, "Claude")
        let unknown = MacOSAppAgentProxy.addingCursorClientName(to: [:], initializeLine:
            #"{"method":"initialize","params":{"clientInfo":{"name":"private-project-owner"}}}"#)
        XCTAssertNil(unknown["OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME"])
    }

    func testSharedAdmissionIsOnlyForCanonicalBrowserReads() {
        func accepts(_ name: String = "browser", _ arguments: [String: Any]) -> Bool {
            AppAgentBrowserRead.accepts([
                "method": "tools/call", "params": ["name": name, "arguments": arguments],
            ])
        }
        XCTAssertTrue(accepts("browser", ["action": "peek", "urls": ["https://example.test"]]))
        XCTAssertTrue(accepts("browser", ["action": "read", "tab_id": 1, "find": "heading"]))
        XCTAssertTrue(accepts("browser", ["action": "tabs"]))
        XCTAssertTrue(accepts("browser", ["action": "wait_for", "text": "Ready", "timeout": 3]))
        XCTAssertFalse(accepts("browser", ["action": "wait_for", "label": "Ready", "timeout": 4]))
        XCTAssertFalse(accepts("browser", ["action": "wait_for", "text": "Ready"]))
        XCTAssertFalse(accepts("browser", ["action": "batch", "steps": [["web": false, "tool": "click"]]]))
        XCTAssertFalse(accepts("browser", ["action": "click", "label": "Cancel"]))
        XCTAssertFalse(accepts("browser", ["action": "read", "app": "Calculator"]))
        XCTAssertFalse(accepts("browser", ["action": "read", "operation": "click"]))
        XCTAssertFalse(accepts("browser", ["url": "https://example.test"]))
        XCTAssertFalse(accepts("batch", ["action": "read"]))
    }

    func testMCPProxiesFromTheSameParentHaveSeparateDefaultIdentities() {
        let session = UUID()
        let first = MacOSAppAgentProxy.proxyClientID(explicit: nil, mcpSession: session, parentProcessID: 99)
        let reconnected = MacOSAppAgentProxy.proxyClientID(explicit: nil, mcpSession: session, parentProcessID: 99)
        let second = MacOSAppAgentProxy.proxyClientID(explicit: "", mcpSession: UUID(), parentProcessID: 99)
        XCTAssertEqual(first, reconnected)
        XCTAssertNotEqual(first, second)
    }

    func testCLIUsesParentIdentityAndExplicitIdentityCanShareState() {
        XCTAssertEqual(
            MacOSAppAgentProxy.proxyClientID(explicit: nil, mcpSession: nil, parentProcessID: 99),
            "p99"
        )
        XCTAssertEqual(
            MacOSAppAgentProxy.proxyClientID(explicit: "shared", mcpSession: UUID(), parentProcessID: 99),
            "shared"
        )
    }
}
