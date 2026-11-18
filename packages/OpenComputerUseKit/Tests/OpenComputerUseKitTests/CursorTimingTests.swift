import AppKit
import XCTest
@testable import OpenComputerUseKit

/// OCU Fast cursor timing: no speed cap, short distance-scaled travel, catch-up under
/// backlog, one persistent cursor across calls.
@MainActor
final class CursorTimingTests: XCTestCase {
    func testCursorLensRequiresAnExplicitOptIn() {
        let key = "OPEN_COMPUTER_USE_CURSOR_LENS"
        XCTAssertFalse(VisualCursorSettings(environment: [:]).lensEnabled)
        XCTAssertFalse(VisualCursorSettings(environment: [key: "false"]).lensEnabled)
        XCTAssertTrue(VisualCursorSettings(environment: [key: "true"]).lensEnabled)
    }

    func testClickRippleExpandsAndFadesAndReducedMotionKeepsItsRadius() {
        let start = CursorClickRipple(progress: 0, strength: 1, reducesMotion: false)
        let middle = CursorClickRipple(progress: 0.5, strength: 1, reducesMotion: false)
        let end = CursorClickRipple(progress: 1, strength: 1, reducesMotion: false)
        XCTAssertGreaterThan(middle.radius, start.radius)
        XCTAssertLessThan(middle.opacity, start.opacity)
        XCTAssertEqual(end.opacity, 0)

        let reduced = CursorClickRipple(progress: 0.5, strength: 1, reducesMotion: true)
        XCTAssertEqual(reduced.radius, CursorClickRipple(progress: 0, strength: 1, reducesMotion: true).radius)
        XCTAssertEqual(reduced.opacity, middle.opacity)
    }

    func testInteractionIndicatorDistinguishesDragFromDropAndRetainsScrollDirection() throws {
        var indicator = CursorInteractionIndicator(feedback: .drag)
        XCTAssertEqual(indicator.phase, "dragging")
        indicator.isCompleted = true
        XCTAssertEqual(indicator.phase, "dropped")

        let scroll = CursorInteractionFeedback.scroll(CGVector(dx: 3, dy: 4))
        let direction = try XCTUnwrap(scroll.scrollDirection)
        XCTAssertEqual(direction.dx, 0.6, accuracy: 0.0001)
        XCTAssertEqual(direction.dy, -0.8, accuracy: 0.0001)
        XCTAssertNil(CursorInteractionFeedback.scroll(.zero).scrollDirection)
        XCTAssertEqual(CursorInteractionIndicator(feedback: scroll, isCompleted: true).phase, "scrolling")
        XCTAssertEqual(CursorInteractionIndicator(feedback: .typing, isCompleted: true).phase, "typing")
    }

    func testSpeedHasNoUpperLimitAndAnInstantSetting() {
        let key = "OPEN_COMPUTER_USE_CURSOR_SPEED"
        // The setting keeps the scale callers already use: unset or 4 is the default timing.
        XCTAssertEqual(visualCursorSpeed(environment: [:]), 1)
        XCTAssertEqual(visualCursorSpeed(environment: [key: "4"]), 1)
        XCTAssertEqual(visualCursorSpeed(environment: [key: "2"]), 0.5)
        XCTAssertEqual(visualCursorSpeed(environment: [key: "10"]), 2.5)
        XCTAssertEqual(visualCursorSpeed(environment: [key: "1000"]), 250, "no clamp at 10 any more")
        XCTAssertEqual(visualCursorSpeed(environment: [key: " 0.5 "]), 0.125)
        for word in ["instant", "Instant", "inf", "max"] {
            XCTAssertEqual(visualCursorSpeed(environment: [key: word]), .infinity, word)
        }
        for junk in ["", "fast", "0", "-3", "nan"] {
            XCTAssertEqual(visualCursorSpeed(environment: [key: junk]), 1, "'\(junk)' falls back to the default")
        }
    }

    func testDefaultTravelIsShortAndScalesGentlyWithDistance() {
        let hop = visualCursorTravelDuration(distance: 40, speed: 1)
        let typical = visualCursorTravelDuration(distance: 400, speed: 1)
        let far = visualCursorTravelDuration(distance: 3000, speed: 1)
        XCTAssertGreaterThanOrEqual(hop, 0.06)
        XCTAssertLessThan(hop, 0.075)
        XCTAssertGreaterThan(typical, 0.09)
        XCTAssertLessThan(typical, 0.12)
        XCTAssertLessThanOrEqual(far, 0.14)
        XCTAssertLessThan(hop, typical)
        XCTAssertLessThan(typical, far)
    }

    func testTravelFollowsSpeedAndNeverGlitchesAtTheExtremes() {
        XCTAssertEqual(visualCursorTravelDuration(distance: 400, speed: 2), visualCursorTravelDuration(distance: 400, speed: 1) / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(visualCursorTravelDuration(distance: 400, speed: 0.5), 0.18)
        // Instant, or faster than one frame: no animation loop at all, the cursor is placed.
        XCTAssertEqual(visualCursorTravelDuration(distance: 400, speed: .infinity), 0)
        XCTAssertEqual(visualCursorTravelDuration(distance: 400, speed: 1_000_000), 0)
        XCTAssertEqual(visualCursorTravelDuration(distance: 0, speed: 1), 0)
        XCTAssertEqual(visualCursorTravelDuration(distance: .nan, speed: 1), 0)
        XCTAssertEqual(visualCursorClickPulseDuration(speed: .infinity), 0)
        XCTAssertEqual(visualCursorClickPulseDuration(speed: 1), 0.09, accuracy: 1e-9)
    }

    func testQueuedActionsMakeTheCursorCatchUp() {
        let alone = visualCursorTravelDuration(distance: 400, speed: 1, queuedBehind: 0)
        let behind = visualCursorTravelDuration(distance: 400, speed: 1, queuedBehind: 4)
        XCTAssertEqual(visualCursorTravelDuration(distance: 400, speed: 1, queuedBehind: -1), alone)
        XCTAssertLessThan(behind, alone / 2)
        XCTAssertLessThan(visualCursorClickPulseDuration(speed: 1, queuedBehind: 4), 0.045)
        // A long backlog speeds up but still glides (floored at 35%) instead of turning every step into a jump.
        XCTAssertEqual(visualCursorTravelDuration(distance: 400, speed: 1, queuedBehind: 100), alone * 0.35, accuracy: 1e-9)
        XCTAssertGreaterThan(visualCursorTravelDuration(distance: 40, speed: 1, queuedBehind: 100), 0)
    }

    func testTipSpringStaysStableAtAnySpeed() {
        XCTAssertEqual(visualCursorTipSpringResponse(speed: 1), 0.07, accuracy: 1e-9)
        XCTAssertEqual(visualCursorTipSpringResponse(speed: 1000), 0.04)
        XCTAssertEqual(visualCursorTipSpringResponse(speed: .infinity), 0.04)
        XCTAssertEqual(visualCursorTipSpringResponse(speed: 0.1), 0.18)
        // The integrator runs at 240 Hz: the stiffest spring must stay well inside its stable range.
        let stiffest = CursorVisualDynamicsConfiguration.fast(speed: .infinity).tipSpring
        XCTAssertLessThan(sqrt(stiffest.stiffness) * stiffest.dt, 1)
    }

    func testFreshCursorAppearsNextToItsTargetNotInAScreenCorner() {
        let target = CGPoint(x: 900, y: 600)
        let start = visualCursorFreshStartPoint(target: target, forward: CGVector(dx: 0.6, dy: 0.8))
        XCTAssertEqual(hypot(start.x - target.x, start.y - target.y), 96, accuracy: 0.001)
        XCTAssertEqual(start.x, 900 - 57.6, accuracy: 0.001)
        XCTAssertEqual(start.y, 600 - 76.8, accuracy: 0.001)
    }

    func testSettingsAreCapturedWhenTheAnimationIsQueued() {
        let key = "OPEN_COMPUTER_USE_CURSOR_SPEED"
        let original = getenv(key).map { String(cString: $0) }
        defer { if let original { setenv(key, original, 1) } else { unsetenv(key) } }
        setenv(key, "8", 1)
        var seen: CGFloat = 0
        VisualCursorSupport.performCursorAnimation { seen = VisualCursorSupport.settings.speed }
        // The app agent restores its environment as soon as the request returns.
        unsetenv(key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(seen, 2, "the queued animation must run with the request's speed")
        XCTAssertEqual(VisualCursorSupport.settings.speed, 1)
    }

    // MARK: - One persistent cursor

    private func withTrace(speed: String? = nil, _ body: (URL, CGPoint) throws -> Void) throws {
        guard let screen = NSScreen.main else { throw XCTSkip("A display is required for overlay rendering") }
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-cursor-trace-\(UUID().uuidString).log")
        let keys: [String: String?] = ["OPEN_COMPUTER_USE_VISUAL_CURSOR": "1", "OPEN_COMPUTER_USE_CURSOR_TRACE_FILE": file.path,
                                       "OPEN_COMPUTER_USE_CURSOR_SPEED": speed]
        let previous = keys.keys.map { ($0, getenv($0).map { String(cString: $0) }) }
        for (key, value) in keys { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
        SoftwareCursorOverlay.reset()
        defer {
            SoftwareCursorOverlay.reset()
            for (key, value) in previous { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: file)
        }
        try body(file, CGPoint(x: screen.frame.midX, y: screen.frame.midY))
    }

    private func moves(in file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init).filter { $0.contains(" move ") }
    }

    func testSecondMoveContinuesFromWhereTheFirstEndedEvenAcrossASessionEnd() throws {
        try withTrace { file, center in
            let first = CGPoint(x: center.x - 120, y: center.y)
            let second = CGPoint(x: center.x + 140, y: center.y + 60)
            SoftwareCursorOverlay.moveCursor(to: first, in: nil)
            SoftwareCursorOverlay.pulseClick(at: first, clickCount: 1, mouseButton: .left, in: nil)
            let panel = try XCTUnwrap(SoftwareCursorOverlay.overlayPanelForTesting)

            // One `ocu call` is one session. Ending it used to reset the cursor, so the next
            // call of a batch started a brand new one.
            StdioMCPServer().endSession()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            XCTAssertTrue(panel.isVisible, "the cursor must outlive the session that moved it")

            SoftwareCursorOverlay.moveCursor(to: second, in: nil)
            XCTAssertTrue(SoftwareCursorOverlay.overlayPanelForTesting === panel, "still the same single panel")

            let lines = try moves(in: file)
            XCTAssertEqual(lines.count, 2)
            XCTAssertTrue(lines[0].contains("fresh=true"))
            XCTAssertTrue(lines[1].contains("fresh=false"), lines[1])
            // The second move starts within a few points of the first target (the tip spring may
            // still be a hair away), not at a fresh start position.
            let from = try XCTUnwrap(lines[1].range(of: #"from=\((-?\d+),(-?\d+)\)"#, options: .regularExpression).map { String(lines[1][$0]) })
            let numbers = from.dropFirst(6).dropLast().split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(numbers.count, 2)
            XCTAssertEqual(numbers[0], Double(first.x), accuracy: 4)
            XCTAssertEqual(numbers[1], Double(first.y), accuracy: 4)
        }
    }

    func testFreshMoveStartsNearTheTargetAndTakesDefaultTime() throws {
        try withTrace { file, center in
            let started = CACurrentMediaTime()
            SoftwareCursorOverlay.moveCursor(to: center, in: nil)
            let took = CACurrentMediaTime() - started
            let line = try XCTUnwrap(try moves(in: file).first)
            XCTAssertTrue(line.contains("fresh=true"))
            XCTAssertFalse(line.contains("from=(0,0)"))
            // 96 pt away at 1x is about 97 ms plus the landing allowance and frame pumping.
            XCTAssertGreaterThan(took, 0.05)
            XCTAssertLessThan(took, 0.30)
            XCTAssertEqual(SoftwareCursorOverlay.overlayPanelForTesting?.alphaValue, 1)
        }
    }

    func testInstantSpeedPlacesTheCursorWithoutAnimating() throws {
        try withTrace(speed: "instant") { file, center in
            let started = CACurrentMediaTime()
            SoftwareCursorOverlay.moveCursor(to: center, in: nil)
            SoftwareCursorOverlay.pulseClick(at: center, clickCount: 2, mouseButton: .left, in: nil)
            XCTAssertLessThan(CACurrentMediaTime() - started, 0.05)
            let panel = try XCTUnwrap(SoftwareCursorOverlay.overlayPanelForTesting)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.alphaValue, 1)
            let tip = SoftwareCursorGlyphMetrics.tipAnchor
            XCTAssertEqual(panel.frame.origin.x + tip.x, center.x, accuracy: 1)  // whole-pixel window origin
            XCTAssertEqual(panel.frame.origin.y + tip.y, center.y, accuracy: 1)
            XCTAssertTrue(try XCTUnwrap(try moves(in: file).first).contains("ms=0"))
        }
    }

    func testCursorHidesAfterTheConfiguredIdleDelay() throws {
        let key = "OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS"
        let original = getenv(key).map { String(cString: $0) }
        setenv(key, "0.3", 1)
        defer { if let original { setenv(key, original, 1) } else { unsetenv(key) } }
        try withTrace { _, center in
            SoftwareCursorOverlay.moveCursor(to: center, in: nil)
            SoftwareCursorOverlay.pulseClick(at: center, clickCount: 1, mouseButton: .left, in: nil)
            let panel = try XCTUnwrap(SoftwareCursorOverlay.overlayPanelForTesting)
            XCTAssertTrue(panel.isVisible)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            XCTAssertFalse(panel.isVisible, "gone 0.3 s after the last action plus the 120 ms fade")
        }
    }

    /// With no target window the cursor goes behind the frontmost app's window, not in front of the user's.
    func testCursorWithoutATargetSitsBehindTheFrontmostAppsTopWindow() {
        let windows: [[String: Any]] = [
            [kCGWindowOwnerPID as String: NSNumber(value: 900), kCGWindowLayer as String: NSNumber(value: 0), kCGWindowNumber as String: NSNumber(value: 11)],
            [kCGWindowOwnerPID as String: NSNumber(value: 500), kCGWindowLayer as String: NSNumber(value: 0), kCGWindowNumber as String: NSNumber(value: 22)],
            [kCGWindowOwnerPID as String: NSNumber(value: 500), kCGWindowLayer as String: NSNumber(value: 0), kCGWindowNumber as String: NSNumber(value: 33)],
        ]
        XCTAssertEqual(cursorBehindWindowID(windowList: windows, frontmostPID: 500), 22, "topmost window of the frontmost app")
    }

    func testCursorIgnoresMenusAndNoFrontmostAppAndFallsBackToBackOrdering() {
        let menuOnly: [[String: Any]] = [
            [kCGWindowOwnerPID as String: NSNumber(value: 500), kCGWindowLayer as String: NSNumber(value: 25), kCGWindowNumber as String: NSNumber(value: 7)],
            [kCGWindowOwnerPID as String: NSNumber(value: 500), kCGWindowLayer as String: NSNumber(value: 0), kCGWindowNumber as String: NSNumber(value: 8)],
        ]
        XCTAssertEqual(cursorBehindWindowID(windowList: menuOnly, frontmostPID: 500), 8, "a menu bar layer is not a window to sit behind")
        XCTAssertNil(cursorBehindWindowID(windowList: menuOnly, frontmostPID: 777), "no window of that app: caller orders at the back")
        XCTAssertNil(cursorBehindWindowID(windowList: menuOnly, frontmostPID: 0), "no frontmost app known")
        XCTAssertNil(cursorBehindWindowID(windowList: [], frontmostPID: 500))
    }
}
