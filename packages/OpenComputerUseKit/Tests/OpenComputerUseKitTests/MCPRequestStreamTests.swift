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

    func testRawReaderSurvivesOverflowAndStillReceivesCancellation() throws {
        let stream = MCPRequestStream()
        var replies: [String] = []
        XCTAssertTrue(stream.receiveRPCLine(rpc(1)) { replies.append($0) })
        let active = try XCTUnwrap(stream.next())
        for id in 2...17 {
            XCTAssertTrue(stream.receiveRPCLine(rpc(id)) { replies.append($0) })
        }

        XCTAssertTrue(stream.receiveRPCLine(rpc(18)) { replies.append($0) },
                      "A busy line must not stop the stdio reader")
        XCTAssertFalse(active.cancellation.isCancelled, "Overflow must not disconnect the active request")
        XCTAssertEqual(replies.count, 1)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(replies[0].utf8)) as? [String: Any])
        XCTAssertEqual(reply["id"] as? Int, 18)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, MCPRequestStream.busyCode)

        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        XCTAssertTrue(stream.receiveRPCLine(cancel) { replies.append($0) })
        XCTAssertTrue(active.cancellation.isCancelled, "Cancellation must still reach active work after overflow")
        XCTAssertEqual(replies.count, 1)
        for id in 2...17 {
            let queued = try XCTUnwrap(stream.next())
            XCTAssertEqual(queued.line, rpc(id))
            XCTAssertFalse(queued.cancellation.isCancelled)
        }
        XCTAssertTrue(stream.receiveRPCLine(rpc(19)) { replies.append($0) })
        XCTAssertEqual(try XCTUnwrap(stream.next()).line, rpc(19), "The refused line must not reappear later")
        stream.disconnect()
    }

    func testRawBusyNotificationHasNoReplyAndDoesNotStopReader() {
        let stream = MCPRequestStream()
        for id in 1...16 { XCTAssertTrue(stream.receiveRPCLine(rpc(id)) { _ in XCTFail("Unexpected refusal") }) }
        let notification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        XCTAssertTrue(stream.receiveRPCLine(notification) { _ in XCTFail("Notifications have no reply") })
        stream.disconnect()
        XCTAssertFalse(stream.receiveRPCLine(rpc(17)) { _ in XCTFail("Closed streams must not emit a busy reply") })
    }

    func testRawBusyReplyPreservesStringAndNumericRequestIDs() throws {
        for id in [#""17""#, "17"] {
            let line = #"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#
            let response = try XCTUnwrap(MCPRequestStream.busyReply(forRPCLine: line))
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            if id.first == "\"" {
                XCTAssertEqual(reply["id"] as? String, "17")
                XCTAssertNil(reply["id"] as? Int)
            } else {
                XCTAssertEqual(reply["id"] as? Int, 17)
                XCTAssertNil(reply["id"] as? String)
            }
        }
    }
}
