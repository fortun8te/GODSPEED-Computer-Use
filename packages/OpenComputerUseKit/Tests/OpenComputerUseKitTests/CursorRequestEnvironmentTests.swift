import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorRequestEnvironmentTests: XCTestCase {
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
