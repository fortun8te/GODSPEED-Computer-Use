import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorRequestEnvironmentTests: XCTestCase {
    func testAgentNamesStaySeparateFromClientIdentifiers() {
        XCTAssertEqual(cursorAgentName("  Scout  "), "Scout")
        XCTAssertEqual(cursorAgentName("Claude Code 2"), "Claude Code 2")
        XCTAssertNil(cursorAgentName("Agent\nOther"))
        XCTAssertNil(cursorAgentName("/Users/example"))
        XCTAssertNil(cursorAgentName(String(repeating: "a", count: 21)))
        XCTAssertEqual(availableCursorAgentName("Codex", taken: ["codex", "codex 2"]), "Codex 3")
    }

    func testQueuedCursorsRetainTheirOwnNames() {
        let keys = ["OPEN_COMPUTER_USE_VISUAL_CURSOR", "OPEN_COMPUTER_USE_CURSOR_NAME", "OPEN_COMPUTER_USE_CURSOR_SPEED"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            SoftwareCursorOverlay.reset()
        }
        SoftwareCursorOverlay.reset()
        setenv(keys[0], "1", 1)
        setenv(keys[2], "instant", 1)
        let first = UUID().uuidString
        let second = UUID().uuidString
        for (client, name, point) in [(first, "Scout", CGPoint(x: 260, y: 360)), (second, "Reviewer", CGPoint(x: 520, y: 360))] {
            setenv(keys[1], name, 1)
            ClientScope.with(client) {
                VisualCursorSupport.performCursorAnimation {
                    SoftwareCursorOverlay.moveCursor(to: point, in: nil)
                }
            }
        }
        unsetenv(keys[1])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ClientScope.with(first) { SoftwareCursorOverlay.currentAgentNameForTesting }, "Scout")
        XCTAssertEqual(ClientScope.with(second) { SoftwareCursorOverlay.currentAgentNameForTesting }, "Reviewer")
        XCTAssertNil(VisualCursorSupport.settings.agentName)
    }

    func testDisabledRequestDoesNotDrawAfterEnvironmentIsRestored() {
        let key = "OPEN_COMPUTER_USE_VISUAL_CURSOR"
        let original = getenv(key).map { String(cString: $0) }
        defer {
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
            SoftwareCursorOverlay.reset()
        }
        SoftwareCursorOverlay.reset()
        setenv(key, "0", 1)
        VisualCursorSupport.performCursorAnimation {
            SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 260, y: 360), in: nil)
        }
        setenv(key, "1", 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(SoftwareCursorOverlay.overlayPanelForTesting?.isVisible ?? false,
                       "A cursor-disabled request must remain disabled after the request environment is restored")
    }
    func testEnabledRequestRemainsEnabledAfterEnvironmentIsRestored() {
        let key = "OPEN_COMPUTER_USE_VISUAL_CURSOR"
        let original = getenv(key).map { String(cString: $0) }
        defer {
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
            SoftwareCursorOverlay.reset()
        }
        SoftwareCursorOverlay.reset()
        setenv(key, "1", 1)
        VisualCursorSupport.performCursorAnimation {
            SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 260, y: 360), in: nil)
        }
        setenv(key, "0", 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(SoftwareCursorOverlay.overlayPanelForTesting?.isVisible ?? false,
                      "An enabled request must remain enabled when its animation runs")
        XCTAssertFalse(VisualCursorSupport.isEnabled, "The captured setting must not leak to later requests")
    }

}
