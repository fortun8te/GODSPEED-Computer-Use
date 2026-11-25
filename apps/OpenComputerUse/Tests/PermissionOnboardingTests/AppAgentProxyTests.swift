import XCTest
@testable import OpenComputerUse
@testable import OpenComputerUseKit

final class AppAgentProxyTests: XCTestCase {
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
