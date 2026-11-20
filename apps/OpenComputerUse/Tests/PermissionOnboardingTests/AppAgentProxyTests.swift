import XCTest
@testable import OpenComputerUse

final class AppAgentProxyTests: XCTestCase {
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
