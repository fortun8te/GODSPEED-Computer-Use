import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorHideTimerTests: XCTestCase {
    func testSettleSchedulesAnIdleHide() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        SoftwareCursorOverlay.settle(at: CGPoint(x: 220, y: 320), in: nil)
        XCTAssertNotNil(SoftwareCursorOverlay.hideTimer)
        XCTAssertEqual(visualCursorPostInteractionIdleTimeout(environment: [:]), 6)
    }

    func testMoveAloneReturnsToTheConfiguredIdleDelay() throws {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 260, y: 360), in: nil)
        SoftwareCursorOverlay.waitUntilIdleForTesting()
        let hide = try XCTUnwrap(SoftwareCursorOverlay.hideTimer)
        XCTAssertLessThanOrEqual(hide.fireDate.timeIntervalSinceNow, VisualCursorSupport.settings.idleHideDelay + 0.1,
                                 "a completed move must use the normal idle delay")
    }

    func testResetDuringHideFadeLetsTheNextActionStayPresented() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        // Create and present the panel with a real move.
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 250, y: 350), in: nil)
        SoftwareCursorOverlay.waitUntilIdleForTesting()
        let panel = SoftwareCursorOverlay.overlayPanelForTesting
        XCTAssertNotNil(panel, "the overlay panel should exist after a move")

        // Start the hide fade, then reset mid-fade (turn-ended style).
        SoftwareCursorOverlay.scheduleHide(after: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertLessThan(panel!.alphaValue, 1.0, "the fade should have started")

        SoftwareCursorOverlay.reset()
        // A new action arrives while the fade is still running.
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 300, y: 400), in: nil)
        SoftwareCursorOverlay.waitUntilIdleForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        // If the fade were not aborted, finishHide would have ordered the panel
        // out and cleared the new session's state.
        XCTAssertEqual(panel!.alphaValue, 1.0, "the aborted fade must leave the cursor fully opaque")
        XCTAssertTrue(panel!.isVisible, "the new action's cursor must not be ordered out by a stale fade")
    }

    func testCursorFadesOutWhenItsTargetWindowCloses() throws {
        try XCTSkipUnless(LockedUseSession.current().state == .unlocked,
                          "Requires an unlocked desktop for WindowServer visibility transitions.")
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
        SoftwareCursorOverlay.waitUntilIdleForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let panel = SoftwareCursorOverlay.overlayPanelForTesting
        XCTAssertEqual(panel?.isVisible, true, "the cursor should be shown while its window is open")

        target.orderOut(nil)
        target.close()
        // WindowServer can report the closed window briefly. Wait for the
        // actual fade before the normal idle timeout could hide it.
        let deadline = Date().addingTimeInterval(1.5)
        while panel?.isVisible == true, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(panel?.isVisible, false, "the cursor must fade out once its window is gone")
        XCTAssertEqual(panel?.alphaValue, 1, "a hidden cursor must leave the panel fully opaque for the next action")
    }

    func testCursorDoesNotPresentForTargetThatAlreadyLeftTheScreen() throws {
        try XCTSkipUnless(LockedUseSession.current().state == .unlocked,
                          "Requires an unlocked desktop for WindowServer visibility transitions.")
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        let target = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 240, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        target.isReleasedWhenClosed = false
        defer { target.close() }
        target.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let window = CursorTargetWindow(windowID: CGWindowID(target.windowNumber), layer: 0)
        target.orderOut(nil)
        func isOnScreen() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], window.windowID) as? [[String: Any]]
            return rows?.contains {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.windowID
                    && $0[kCGWindowIsOnscreen as String] as? Bool == true
            } ?? false
        }
        let deadline = Date().addingTimeInterval(1.5)
        while isOnScreen(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(isOnScreen(), "the fixture must leave WindowServer's onscreen list")
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 280, y: 260), in: window)
        SoftwareCursorOverlay.pulseClick(at: CGPoint(x: 280, y: 260), clickCount: 1, mouseButton: .left, in: window)
        XCTAssertFalse(SoftwareCursorOverlay.overlayPanelForTesting?.isVisible ?? false)
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: 390, y: 390), in: nil)
        SoftwareCursorOverlay.waitUntilIdleForTesting()
        XCTAssertTrue(SoftwareCursorOverlay.overlayPanelForTesting?.isVisible ?? false)
    }

    func testClosingWindowDoesNotDiscardTheNextClick() throws {
        try XCTSkipUnless(LockedUseSession.current().state == .unlocked,
                          "Requires an unlocked desktop for WindowServer visibility transitions.")
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "This test closes the old window while its glide is in progress.")
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let key = "OPEN_COMPUTER_USE_CURSOR_SPEED"
        let original = getenv(key).map { String(cString: $0) }
        setenv(key, "2", 1)
        SoftwareCursorOverlay.reset()
        defer {
            SoftwareCursorOverlay.reset()
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
        }

        let first = NSPanel(contentRect: CGRect(x: visible.midX - 300, y: visible.midY, width: 200, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let second = NSPanel(contentRect: CGRect(x: visible.midX + 100, y: visible.midY, width: 160, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        first.orderFrontRegardless()
        second.orderFrontRegardless()
        defer { first.orderOut(nil); second.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let from = CursorTargetWindow(windowID: CGWindowID(first.windowNumber), layer: first.level.rawValue)
        let to = CursorTargetWindow(windowID: CGWindowID(second.windowNumber), layer: second.level.rawValue)
        let destination = CGPoint(x: second.frame.midX, y: second.frame.midY)
        SoftwareCursorOverlay.settle(at: CGPoint(x: first.frame.minX + 10, y: first.frame.midY), in: from)
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: first.frame.maxX - 10, y: first.frame.midY), in: from)
        SoftwareCursorOverlay.pulseClick(at: destination, clickCount: 1, mouseButton: .left, in: to)
        first.orderOut(nil)

        SoftwareCursorOverlay.waitUntilIdleForTesting()
        let panel = try XCTUnwrap(SoftwareCursorOverlay.overlayPanelForTesting)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.minX + SoftwareCursorPanelMetrics.tipAnchor.x, destination.x, accuracy: 1)
        XCTAssertEqual(panel.frame.minY + SoftwareCursorPanelMetrics.tipAnchor.y, destination.y, accuracy: 1)
    }
}
