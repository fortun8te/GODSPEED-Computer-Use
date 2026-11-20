import XCTest
@testable import OpenComputerUseKit

final class MCPRequestStreamTests: XCTestCase {
    private func rpc(_ id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"get_app_state","arguments":{}}}"#
    }

    private func envelope(_ id: Int) -> String {
        let inner = rpc(id).replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"kind":"mcp","line":"\#(inner)"}"#
    }

    private func busyReply(_ line: String) throws -> [String: Any] {
        let envelope = try XCTUnwrap(MCPRequestStream.busyEnvelope(for: line))
        let text = try XCTUnwrap(envelope["response"] as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testSeventeenthQueuedRequestGetsABusyReplyWithItsOwnID() throws {
        let stream = MCPRequestStream()
        for id in 1...16 {
            XCTAssertEqual(stream.intake(envelope(id), rpcLine: rpc(id)), .accepted)
        }
        XCTAssertEqual(stream.intake(envelope(17), rpcLine: rpc(17)), .busy)
        let reply = try busyReply(envelope(17))
        XCTAssertEqual(reply["id"] as? Int, 17)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, MCPRequestStream.busyCode)
        XCTAssertEqual((reply["error"] as? [String: Any])?["message"] as? String, "Busy. Retry later.")
    }

    func testBusyRefusalNeverCancelsTheActiveRequest() throws {
        let stream = MCPRequestStream()
        for id in 1...16 {
            XCTAssertEqual(stream.intake(envelope(id), rpcLine: rpc(id)), .accepted)
        }
        let active = try XCTUnwrap(stream.next())
        XCTAssertEqual(stream.intake(envelope(17), rpcLine: rpc(17)), .accepted)
        XCTAssertEqual(stream.intake(envelope(18), rpcLine: rpc(18)), .busy)
        XCTAssertFalse(active.cancellation.isCancelled)
    }

    func testBusyRefusalOfANotificationHasNoReply() {
        let notification = #"{"kind":"mcp","line":"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"}"#
        XCTAssertNil(MCPRequestStream.busyEnvelope(for: notification))
    }

    func testBusyRefusalOfANonMCPRequestSaysSo() throws {
        let envelope = try XCTUnwrap(MCPRequestStream.busyEnvelope(for: #"{"kind":"agentInfo"}"#))
        XCTAssertEqual(envelope["error"] as? String, "The app agent is busy. Retry later.")
    }
}
