import Foundation
import XCTest
@testable import OpenComputerUseKit

final class LocalDecisionToolTests: XCTestCase {
    private let loopback = URL(string: "http://127.0.0.1:18765")!

    private func arguments(role: String) -> [String: Any] {
        ["role": role, "state": ["goal": "Inspect the fixture"], "question": [
            "type": "choice", "instructions": "Choose the next step.",
            "criteria": ["inspect": "Inspect the result", "pause": "Pause"],
        ]]
    }

    func testEachRoleUsesItsCheckpointAndReturnsAdviceWithoutDispatch() throws {
        for role in LocalDecisionTool.roles {
            let result = try LocalDecisionTool.run(arguments: arguments(role: role), baseURL: loopback) { url, body, _ in
                XCTAssertEqual(url.path, "/gsd1/score")
                XCTAssertEqual(body["role"] as? String, role)
                return ["model": "gsd1-" + role, "probs": ["inspect": 0.91, "pause": 0.09]]
            }
            XCTAssertEqual(result.deliveryState, .notSent)
            XCTAssertEqual(result.primaryText, "GSD1 \(role) suggests inspect (91%).")
        }
    }

    func testWrongCheckpointMalformedScoresAndUncertaintyAbstain() throws {
        for reply in [
            ["model": "gsd1-action", "probs": ["inspect": 0.91, "pause": 0.09]],
            ["model": "gsd1-recover", "probs": ["inspect": 0.91, "extra": 0.09]],
            ["model": "gsd1-recover", "probs": ["inspect": 0.57, "pause": 0.43]],
        ] {
            let result = try LocalDecisionTool.run(arguments: arguments(role: "recover"), baseURL: loopback) { _, _, _ in reply }
            XCTAssertTrue(result.primaryText?.hasPrefix("No ") == true)
            XCTAssertEqual(result.deliveryState, .notSent)
        }
    }

    func testEvidenceIsRestrictedToLoopback() {
        XCTAssertNil(LocalDecisionTool.baseURL(environment: ["OPEN_COMPUTER_USE_GSD1_URL": "https://example.com"]))
        XCTAssertEqual(LocalDecisionTool.baseURL(environment: ["OPEN_COMPUTER_USE_GSD1_URL": loopback.absoluteString]), loopback)
    }

    func testLiveConfiguredHelperServesAllThreeModelsThroughMCP() throws {
        let url = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_GSD1_URL"]
        try XCTSkipUnless(url == loopback.absoluteString, "Run with the disposable loopback helper.")
        let server = StdioMCPServer(trajectoryEnvironment: ["OPEN_COMPUTER_USE_TRAJECTORY_LOG": "0"])
        for (index, role) in LocalDecisionTool.roles.enumerated() {
            let packet: [String: Any] = ["jsonrpc": "2.0", "id": index, "method": "tools/call",
                                         "params": ["name": LocalDecisionTool.name, "arguments": arguments(role: role)]]
            let line = String(decoding: try JSONSerialization.data(withJSONObject: packet), as: UTF8.self)
            let response = try XCTUnwrap(server.handle(line: line))
            XCTAssertFalse(response.contains("helper was busy"), response)
            XCTAssertFalse(response.contains("\"isError\":true"), response)
            XCTAssertTrue(response.contains("GSD1 \(role)") || response.contains("No clear local recommendation"), response)
        }
    }
}
