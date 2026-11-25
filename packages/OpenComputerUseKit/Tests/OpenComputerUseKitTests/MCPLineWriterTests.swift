import Foundation
import XCTest
@testable import OpenComputerUseKit

final class MCPLineWriterTests: XCTestCase {
    func testConcurrentRepliesRemainCompleteJSONLinesWithUnicodePayloads() throws {
        let state = NSLock()
        var bytes = Data()
        var activeWrites = 0
        var maximumActiveWrites = 0
        let writer = MCPLineWriter { data in
            // Model a large write that needs multiple low-level writes. Without
            // line serialization, another reply can land between its fragments.
            let midpoint = data.count / 2
            state.withLock {
                activeWrites += 1
                maximumActiveWrites = max(maximumActiveWrites, activeWrites)
                bytes.append(data.prefix(midpoint))
            }
            Thread.sleep(forTimeInterval: 0.002)
            state.withLock {
                bytes.append(data.suffix(from: midpoint))
                activeWrites -= 1
            }
        }
        let payload = String(repeating: "λ🖱️", count: 500)
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let line = #"{"id":\#(index),"payload":"\#(payload)"}"#
            if index.isMultiple(of: 2) { writer.writeLine(line) }
            else { writer.writeLine(Data(line.utf8)) }
        }
        XCTAssertEqual(maximumActiveWrites, 1)
        XCTAssertEqual(bytes.last, 10)
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 16)
        let replies = try lines.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertEqual(Set(replies.compactMap { $0["id"] as? Int }), Set(0..<16))
        XCTAssertTrue(replies.allSatisfy { $0["payload"] as? String == payload })
    }
}
