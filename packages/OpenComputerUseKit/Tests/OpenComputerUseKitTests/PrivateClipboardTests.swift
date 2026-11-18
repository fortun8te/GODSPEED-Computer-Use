import XCTest
@testable import OpenComputerUseKit

final class PrivateClipboardTests: XCTestCase {
    func testClientsShareClipboardAcrossDispatchersAndKeepOtherClientsSeparate() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let native = ComputerUseToolDispatcher()
        let web = ComputerUseToolDispatcher()
        try ClientScope.with(first) {
            defer { PrivateClipboard.current.clear() }
            _ = try native.callTool(name: "clipboard", arguments: ["action": "write", "text": "🌱 plain text"])
            XCTAssertEqual(try web.callTool(name: "clipboard", arguments: ["action": "read"]).primaryText, "🌱 plain text")
            try ClientScope.with(second) {
                defer { PrivateClipboard.current.clear() }
                XCTAssertNil(PrivateClipboard.current.payload)
                try PrivateClipboard.current.writeText("other")
            }
            XCTAssertEqual(try PrivateClipboard.current.textForPaste(), "🌱 plain text")
            _ = try native.callTool(name: "clipboard", arguments: ["action": "clear"])
            XCTAssertThrowsError(try PrivateClipboard.current.textForPaste())
        }
    }

    func testFinderPayloadCannotSilentlyBecomeText() throws {
        let clipboard = PrivateClipboard()
        let cut = PrivateClipboard.Payload.files(paths: ["/tmp/synthetic"], move: true)
        clipboard.write(cut)
        XCTAssertThrowsError(try clipboard.textForPaste())
        try clipboard.writeText("new")
        clipboard.clear(matching: cut)
        XCTAssertEqual(try clipboard.textForPaste(), "new")
        XCTAssertThrowsError(try clipboard.writeText(String(repeating: "x", count: PrivateClipboard.maxTextBytes + 1)))
        XCTAssertEqual(try clipboard.textForPaste(), "new")
    }

    func testBrowserAliasesDoNotInterceptNativeControlKeys() {
        XCTAssertEqual(PrivateClipboard.Action(key: "⌘C"), .copy)
        XCTAssertEqual(PrivateClipboard.Action(key: "Control+V", browser: true), .paste)
        XCTAssertNil(PrivateClipboard.Action(key: "Control+V"))
        XCTAssertEqual(PrivateClipboard.Action(key: "Command+Shift+V"), .paste)
    }
}
