import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Multi-agent safety: a running call keeps its client active, browser lanes and page memory stay per agent,
/// and malformed MCP requests get a reply instead of leaving the client waiting.
final class ClientScopeSafetyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClientScope.forgetActivityForTesting()
    }

    override func tearDown() {
        ClientScope.forgetActivityForTesting()
        super.tearDown()
    }

    func testLongRunningCallCountsAsActiveForOtherAgents() {
        ClientScope.with("safety-long-a") {
            ClientScope.with("safety-long-b") {
                // Window of zero: only a call still in flight can make agent "a" count as active.
                XCTAssertTrue(ClientScope.othersActive(within: 0))
                XCTAssertGreaterThanOrEqual(ClientScope.activeCount(within: 0), 2)
            }
        }
    }

    func testRequestsInFlightReturnsToBaselineAfterCalls() {
        let before = ClientScope.requestsInFlight
        ClientScope.with("safety-inflight") {
            XCTAssertEqual(ClientScope.requestsInFlight, before + 1)
        }
        XCTAssertEqual(ClientScope.requestsInFlight, before)
    }

    func testBrowserLanesBelongToTheirAgent() {
        let mainLane = BrowserBridge.lane(0).sessionID
        let a = ClientScope.with("safety-lane-a") { BrowserBridge.lane(0).sessionID }
        let b = ClientScope.with("safety-lane-b") { BrowserBridge.lane(0).sessionID }
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, mainLane)
        XCTAssertTrue(a.contains("safety-lane-a"))
        // The same agent gets the same lane again, not a new session.
        XCTAssertEqual(ClientScope.with("safety-lane-a") { BrowserBridge.lane(0).sessionID }, a)
    }

    func testScopedStoreGivesEachAgentItsOwnValue() {
        let store = ScopedStore<RecentAppMemory>(make: { _ in RecentAppMemory() })
        ClientScope.with("safety-store-a") { store.current.remember("Notes") }
        XCTAssertNil(ClientScope.with("safety-store-b") { store.current.current })
        XCTAssertEqual(ClientScope.with("safety-store-a") { store.current.current }, "Notes")
    }

    func testRequestWithIdButNoMethodGetsAnErrorReply() throws {
        let server = StdioMCPServer(service: ComputerUseService())
        let response = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":7}"#))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? Int, 7)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32600)
    }

    func testNotificationWithoutMethodStaysSilent() {
        let server = StdioMCPServer(service: ComputerUseService())
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0"}"#))
    }
}
