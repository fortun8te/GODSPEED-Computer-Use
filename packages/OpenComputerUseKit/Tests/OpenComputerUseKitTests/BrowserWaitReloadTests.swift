import Foundation
import XCTest
@testable import OpenComputerUseKit

final class BrowserWaitReloadTests: XCTestCase {

    func testWaitCallBudgetIncludesFullAdvertisedWaitAndReplyTime() {
        for action in ["wait", "wait_load", "wait_for", "wait_for_text"] {
            XCTAssertGreaterThan(ComputerUseToolDispatcher.browserCallLimit(action: action), 30)
        }
        XCTAssertEqual(ComputerUseToolDispatcher.browserCallLimit(action: "reload"), 25)
    }

    func testWaitDeadlineReservesReplyTimeWithinInheritedBudget() {
        let start = ProcessInfo.processInfo.systemUptime
        BrowserCallBudget.withDeadline(start + 35) {
            XCTAssertEqual(BrowserCallBudget.observationDeadline(after: 30, startingAt: start), start + 30)
        }
        BrowserCallBudget.withDeadline(start + 8) {
            XCTAssertEqual(BrowserCallBudget.observationDeadline(after: 30, startingAt: start), start + 7)
        }
    }

    func testSameURLReloadWaitsForAReadyReplacementLoader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("obu")
        let marker = directory.appendingPathComponent("reloads")
        let script = #"""
        #!/bin/sh
        loader=old
        reloading=false
        sample=0
        while IFS= read -r line; do
          case "$line" in *'"method":"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'; continue ;; esac
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\)[,}].*/\1/p')
          [ -n "$id" ] || continue
          text='{}'
          case "$line" in
            *Page.reload*) printf 'sent\n' >> '\#(marker.path)'; reloading=true ;;
            *Page.getFrameTree*)
              text='{\"frameTree\":{\"frame\":{\"id\":\"main\",\"loaderId\":\"'"$loader"'\"}}}'
              if [ "$reloading" = true ]; then loader=new; fi
              ;;
            *performance.timeOrigin*) text='{\"result\":{\"value\":1}}' ;;
            *document.readyState*)
              sample=$((sample + 1))
              if [ "$sample" -eq 1 ]; then ready=loading; title=Loading; else ready=complete; title=Ready; fi
              text='{\"result\":{\"value\":[\"https://example.test/\",\"'"$title"'\",\"'"$ready"'\"]}}'
              ;;
          esac
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}]}}\n' "$id" '{\"result\":'"$text"'}'
        done
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let bridge = BrowserBridge(sessionID: UUID().uuidString, launchEnvironment: [
            "OPEN_COMPUTER_USE_BROWSER": "1", "OPEN_COMPUTER_USE_OBU_BIN": helper.path,
        ])
        defer { bridge.shutdown() }
        let page = BrowserPage(bridge: bridge, tab: ["tab_id": 12])
        let reply = try BrowserCallBudget.withDeadline(BrowserCallBudget.deadline(after: 8)) {
            try page.history("reload")
        }
        XCTAssertTrue(reply.hasPrefix("reloaded Ready"))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "sent\n")
    }
}
