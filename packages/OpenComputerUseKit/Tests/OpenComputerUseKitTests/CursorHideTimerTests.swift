import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorHideTimerTests: XCTestCase {
    // Regression guards for the 2026-11-04 hide/sway/fade fixes.

    func testSettleSchedulesSwayStopAndHideTogether() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        SoftwareCursorOverlay.settle(at: CGPoint(x: 220, y: 320), in: nil)
        // Scheduling the hide must not cancel the sway-stop that was just armed
        // (the old ordering killed the sway timer immediately).
        XCTAssertNotNil(SoftwareCursorOverlay.swayStopTimer, "hide scheduling must not cancel the sway-stop timer")
        XCTAssertNotNil(SoftwareCursorOverlay.hideTimer, "the hide timer must still own disappearance")
        XCTAssertEqual(visualCursorIdleSwayTimeout(), 6)
    }

    func testMoveSchedulesItsOwnFallbackHide() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 260, y: 360), in: nil)
        XCTAssertNotNil(SoftwareCursorOverlay.hideTimer, "a move with no following settle/pulse must still hide")
    }

    func testResetDuringHideFadeLetsTheNextActionStayPresented() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        // Create and present the panel with a real move.
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 250, y: 350), in: nil)
        let panel = SoftwareCursorOverlay.overlayPanelForTesting
        XCTAssertNotNil(panel, "the overlay panel should exist after a move")

        // Start the hide fade, then reset mid-fade (turn-ended style).
        SoftwareCursorOverlay.scheduleHide(after: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertLessThan(panel!.alphaValue, 1.0, "the fade should have started")

        SoftwareCursorOverlay.reset()
        // A new action arrives while the fade is still running.
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 300, y: 400), in: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        // If the fade were not aborted, finishHide would have ordered the panel
        // out and cleared the new session's state.
        XCTAssertEqual(panel!.alphaValue, 1.0, "the aborted fade must leave the cursor fully opaque")
        XCTAssertTrue(panel!.isVisible, "the new action's cursor must not be ordered out by a stale fade")
    }

    func testCursorFadesOutWhenItsTargetWindowCloses() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        // A real window the cursor points at; closing it must not leave the cursor over the desktop.
        let target = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 240, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        target.isReleasedWhenClosed = false
        target.orderFront(nil)
        // The window list only knows the window after the window server has run a turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let targetWindow = CursorTargetWindow(windowID: CGWindowID(target.windowNumber), layer: 0)
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 280, y: 260), in: targetWindow)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let panel = SoftwareCursorOverlay.overlayPanelForTesting
        XCTAssertEqual(panel?.isVisible, true, "the cursor should be shown while its window is open")

        target.orderOut(nil)
        target.close()
        // The window watch checks every 0.1 s and the fade takes about 0.12 s.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(panel?.isVisible, false, "the cursor must fade out once its window is gone")
        XCTAssertEqual(panel?.alphaValue, 1, "a hidden cursor must leave the panel fully opaque for the next action")
    }
}
