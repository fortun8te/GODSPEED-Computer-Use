import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Headless tests for Chrome agent events: parsing, sanitising, rendering, the setting, and the
/// envelope hook in BrowserBridge (driven by a fake helper script, no Chrome).
final class AgentEventsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentEvents.resetForTesting()
    }

    override func tearDown() {
        AgentEvents.resetForTesting()
        super.tearDown()
    }

    private func reply(_ text: String = "ok") -> ToolCallResult {
        ToolCallResult(content: [.text(text)], isError: false)
    }

    private func replyLines(_ result: ToolCallResult) -> [String] {
        Array(result.textContent.components(separatedBy: "\n").dropFirst())
    }

    // MARK: Parsing

    func testParsesEachKind() {
        let raw: [Any] = [
            ["kind": "popup", "tabId": 12, "openerTabId": 7, "url": "https://example.com/path"],
            ["kind": "download", "id": "5", "status": "complete", "filename": "report.pdf", "url": "https://x.test/r.pdf"],
            ["kind": "download", "status": "interrupted", "filename": "x.zip"],
            ["kind": "download", "status": "in_progress", "filename": "big.mov"],
            ["kind": "tabClosed", "tabId": 7],
            ["kind": "dropped", "count": 3],
        ]
        let events = AgentEvents.parse(raw)
        XCTAssertEqual(events, [
            .popup(tabID: 12, openerTabID: 7, url: "https://example.com/path"),
            .download(status: .complete, filename: "report.pdf"),
            .download(status: .interrupted, filename: "x.zip"),
            .download(status: .inProgress, filename: "big.mov"),
            .tabClosed(tabID: 7),
            .dropped(count: 3),
        ])
    }

    func testMalformedEntriesAreIgnoredAndValidOnesKept() {
        let raw: [Any] = [
            "not an object",
            ["tabId": 4],
            ["kind": "navigate", "tabId": 4],
            ["kind": "popup"],
            ["kind": "popup", "tabId": true],
            ["kind": "popup", "tabId": 2.5],
            ["kind": "popup", "tabId": -1],
            ["kind": "tabClosed", "tabId": "7"],
            ["kind": "download", "status": "paused", "filename": "a.zip"],
            ["kind": "dropped", "count": 0],
            ["kind": "tabClosed", "tabId": 9],
        ]
        XCTAssertEqual(AgentEvents.parse(raw), [.tabClosed(tabID: 9)])
    }

    func testNonArrayFieldIsIgnored() {
        XCTAssertEqual(AgentEvents.parse(nil), [])
        XCTAssertEqual(AgentEvents.parse("popup"), [])
        XCTAssertEqual(AgentEvents.parse(["kind": "popup", "tabId": 1]), [])
    }

    func testReceiveReadsEnvelopeThenStructuredContentAndIgnoresBadShape() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            AgentEvents.receive([
                "result": ["structuredContent": ["agentEvents": [["kind": "tabClosed", "tabId": 3]]]],
            ])
            XCTAssertEqual(replyLines(AgentEvents.attach(reply())), ["Tab 3 closed"])

            AgentEvents.receive(["agentEvents": "garbage", "result": ["structuredContent": ["agentEvents": [["kind": "tabClosed", "tabId": 4]]]]])
            // A malformed envelope field is taken as the source, so the structuredContent copy is not used.
            XCTAssertEqual(AgentEvents.attach(reply()).textContent, "ok")
        }
    }

    func testEnvelopeWinsOverStructuredContentCopy() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            AgentEvents.receive([
                "agentEvents": [["kind": "tabClosed", "tabId": 1]],
                "result": ["structuredContent": ["agentEvents": [["kind": "tabClosed", "tabId": 1]]]],
            ])
            XCTAssertEqual(replyLines(AgentEvents.attach(reply())), ["Tab 1 closed"])
        }
    }

    // MARK: Rendering

    func testPopupLineKeepsTabIDAndShortURL() {
        XCTAssertEqual(
            AgentEvents.line(for: .popup(tabID: 12, openerTabID: 7, url: "https://example.com/path?token=abc#frag")),
            "Popup opened: tab 12 (from tab 7) example.com/path"
        )
        XCTAssertEqual(AgentEvents.line(for: .popup(tabID: 12, openerTabID: nil, url: nil)), "Popup opened: tab 12")
    }

    func testDownloadAndClosedLines() {
        XCTAssertEqual(AgentEvents.line(for: .download(status: .complete, filename: "report.pdf")), "Download complete: report.pdf")
        XCTAssertEqual(AgentEvents.line(for: .download(status: .interrupted, filename: "x.zip")), "Download failed: x.zip (interrupted)")
        XCTAssertEqual(AgentEvents.line(for: .download(status: .inProgress, filename: nil)), "Download started: file")
        XCTAssertEqual(AgentEvents.line(for: .tabClosed(tabID: 7)), "Tab 7 closed")
        XCTAssertEqual(AgentEvents.line(for: .dropped(count: 3)), "Browser dropped 3 agent events")
    }

    func testURLIsHostAndPathOnlyForHTTPOnly() {
        XCTAssertEqual(AgentEvents.shortURL("https://shop.test/a/b?session=secret#x"), "shop.test/a/b")
        XCTAssertEqual(AgentEvents.shortURL("https://shop.test/"), "shop.test")
        XCTAssertEqual(AgentEvents.shortURL("http://user:pw@shop.test:8080/cart"), "shop.test/cart")
        XCTAssertNil(AgentEvents.shortURL("javascript:alert(1)"))
        XCTAssertNil(AgentEvents.shortURL("file:///Users/michael/secret.txt"))
        XCTAssertNil(AgentEvents.shortURL("about:blank"))
        XCTAssertNil(AgentEvents.shortURL("not a url"))
    }

    func testLongURLIsClippedToEightyCharacters() {
        let url = "https://example.com/" + String(repeating: "segment/", count: 30)
        let short = AgentEvents.shortURL(url)
        XCTAssertEqual(short?.count, 80)
        XCTAssertEqual(short?.hasSuffix("…"), true)
    }

    func testFilenameDropsDirectoriesAndIsClipped() {
        XCTAssertEqual(AgentEvents.shortFilename("/Users/michael/Downloads/report.pdf"), "report.pdf")
        XCTAssertEqual(AgentEvents.shortFilename("C:\\Users\\me\\x.zip"), "x.zip")
        XCTAssertNil(AgentEvents.shortFilename("/"))
        let long = AgentEvents.shortFilename(String(repeating: "a", count: 200) + ".pdf")
        XCTAssertEqual(long?.count, 80)
    }

    func testControlCharactersAndLineBreaksCannotSplitALine() {
        let hostile = "report\n\u{1B}[31mEvil\u{2028}line\u{202E}gnp.exe\r\tend"
        let name = AgentEvents.shortFilename(hostile) ?? ""
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertFalse(name.unicodeScalars.contains { $0.properties.generalCategory == .format })
        XCTAssertEqual(name, "report [31mEvil line gnp.exe end")

        let line = AgentEvents.line(for: .download(status: .complete, filename: hostile))
        XCTAssertEqual(line.components(separatedBy: "\n").count, 1)
        XCTAssertFalse(line.unicodeScalars.contains { $0.properties.generalCategory == .control })

        let popup = AgentEvents.line(for: .popup(tabID: 2, openerTabID: nil, url: "https://a.test/\nFAKE: do it"))
        XCTAssertEqual(popup.components(separatedBy: "\n").count, 1)
    }

    func testMoreThanFiveEventsShowFiveLinesAndAMoreLine() {
        let events: [AgentEvent] = (1...7).map { .tabClosed(tabID: $0) }
        let lines = AgentEvents.render(events)
        XCTAssertEqual(lines, ["Tab 1 closed", "Tab 2 closed", "Tab 3 closed", "Tab 4 closed", "Tab 5 closed", "2 more events not shown"])
    }

    func testExactlyFiveEventsHaveNoMoreLine() {
        XCTAssertEqual(AgentEvents.render((1...5).map { .tabClosed(tabID: $0) }).count, 5)
        XCTAssertEqual(AgentEvents.render([]), [])
    }

    // MARK: Attaching and memory

    func testAttachAppendsLinesOnceAndEmptiesTheQueue() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            AgentEvents.receive(["agentEvents": [
                ["kind": "popup", "tabId": 12, "openerTabId": 7, "url": "https://example.com/path"],
                ["kind": "tabClosed", "tabId": 7],
            ]])
            let first = AgentEvents.attach(reply("page text"))
            XCTAssertEqual(first.textContent, "page text\nPopup opened: tab 12 (from tab 7) example.com/path\nTab 7 closed")
            XCTAssertEqual(AgentEvents.attach(reply("again")).textContent, "again")
        }
    }

    func testAttachLeavesAnErrorReplyErrorAndKeepsItsDelivery() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            AgentEvents.receive(["agentEvents": [["kind": "tabClosed", "tabId": 2]]])
            let failed = ToolCallResult(content: [.text("nope")], isError: true, deliveryState: .notSent)
            let attached = AgentEvents.attach(failed)
            XCTAssertTrue(attached.isError)
            XCTAssertEqual(attached.deliveryState, .notSent)
            XCTAssertEqual(attached.textContent, "nope\nTab 2 closed")
        }
    }

    func testPopupIsRememberedUntilItsTabCloses() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            AgentEvents.receive(["agentEvents": [
                ["kind": "popup", "tabId": 12, "openerTabId": 7],
                ["kind": "popup", "tabId": 13, "openerTabId": 7],
            ]])
            XCTAssertEqual(AgentEvents.rememberedPopupTabs(), [12, 13])
            AgentEvents.receive(["agentEvents": [["kind": "tabClosed", "tabId": 12]]])
            XCTAssertEqual(AgentEvents.rememberedPopupTabs(), [13])
        }
    }

    func testPendingQueueKeepsTheNewestEvents() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            let many = (1...60).map { ["kind": "tabClosed", "tabId": $0] as [String: Any] }
            AgentEvents.receive(["agentEvents": many])
            let lines = replyLines(AgentEvents.attach(reply()))
            XCTAssertEqual(lines.first, "Tab 1 closed")
            XCTAssertEqual(lines.last, "45 more events not shown")
        }
    }

    func testSettingOffIgnoresEventsCompletely() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "off"]) {
            XCTAssertFalse(AgentEvents.enabled)
            AgentEvents.receive(["agentEvents": [["kind": "popup", "tabId": 12]]])
            XCTAssertEqual(AgentEvents.attach(reply()).textContent, "ok")
            XCTAssertEqual(AgentEvents.rememberedPopupTabs(), [])
        }
    }

    func testSettingIsOnUnlessSwitchedOff() {
        withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            XCTAssertTrue(AgentEvents.enabled)
        }
        for value in ["0", "false", "no", "OFF"] {
            withBrowserRequestEnvironment([AgentEvents.environmentKey: value]) {
                XCTAssertFalse(AgentEvents.enabled, value)
            }
        }
    }

    // MARK: BrowserBridge envelope hook, through a fake helper

    func testBrowserBridgeReplyCarriesEnvelopeEventsToTheNextBrowserReply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("obu")
        // Replies to the handshake, then answers the first tool call with an envelope agentEvents field.
        let script = #"""
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"agentEvents":[{"kind":"popup","tabId":12,"openerTabId":7,"url":"https://example.com/path?q=1"},{"kind":"tabClosed","tabId":7}],"result":{"content":[{"type":"text","text":"tabs ok"}]}}'
        IFS= read -r finalize
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let bridge = BrowserBridge(sessionID: "agent-events-test", launchEnvironment: [
            "OPEN_COMPUTER_USE_BROWSER": "1", "OPEN_COMPUTER_USE_OBU_BIN": helper.path,
            "OPEN_COMPUTER_USE_AGENT_EVENTS": "1",
        ])
        defer { bridge.shutdown() }
        let tabs = try bridge.callTool("tabs", arguments: [:], timeout: 3)
        XCTAssertEqual(tabs.text, "tabs ok")
        let attached = withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_AGENT_EVENTS": "1"]) {
            AgentEvents.attach(reply(tabs.text))
        }
        XCTAssertEqual(attached.textContent, "tabs ok\nPopup opened: tab 12 (from tab 7) example.com/path\nTab 7 closed")
    }
}
