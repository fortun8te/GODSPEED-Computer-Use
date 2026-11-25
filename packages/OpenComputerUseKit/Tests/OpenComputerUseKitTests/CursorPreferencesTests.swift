import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorPreferencesTests: XCTestCase {
    func testDefaultPresentationIsVisibleAndStaysWithItsWindow() {
        let settings = VisualCursorSettings(environment: [:])
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.feedbackEnabled)
        XCTAssertTrue(settings.labelEnabled)
        XCTAssertTrue(settings.automaticTint)
        XCTAssertFalse(settings.reducedMotion)
        XCTAssertFalse(settings.floats)
        XCTAssertEqual(settings.idleHideDelay, 6)
    }

    func testExplicitPreferencesAreNormalizedAndInvalidMotionKeepsTheSystemDefault() {
        let settings = VisualCursorSettings(environment: [
            "OPEN_COMPUTER_USE_CURSOR_COLOR": " Auto ",
            "OPEN_COMPUTER_USE_CURSOR_FEEDBACK": " OFF ",
            "OPEN_COMPUTER_USE_CURSOR_LABEL": " No ",
            "OPEN_COMPUTER_USE_CURSOR_MOTION": " Reduced ",
            "OPEN_COMPUTER_USE_CURSOR_FLOAT": " On ",
        ])
        XCTAssertTrue(settings.automaticTint)
        XCTAssertFalse(settings.feedbackEnabled)
        XCTAssertFalse(settings.labelEnabled)
        XCTAssertTrue(settings.reducedMotion)
        XCTAssertTrue(settings.floats)
        XCTAssertFalse(VisualCursorSettings(environment: ["OPEN_COMPUTER_USE_CURSOR_MOTION": "invalid"]).reducedMotion)
        let grey = VisualCursorSettings(environment: ["OPEN_COMPUTER_USE_CURSOR_COLOR": " default "])
        XCTAssertNil(grey.color)
        XCTAssertFalse(grey.automaticTint)
        XCTAssertEqual(VisualCursorSettings(environment: ["OPEN_COMPUTER_USE_CURSOR_COLOR": " #34D399 "]).color,
                       CursorColor(hex: "#34d399"))
    }

    func testQueuedPreferencesBelongToTheRequestThatScheduledThem() throws {
        var observed: VisualCursorSettings?
        RequestConfiguration.withEnvironment([
            "OPEN_COMPUTER_USE_CURSOR_ASYNC": "1",
            "OPEN_COMPUTER_USE_CURSOR_FEEDBACK": "0",
            "OPEN_COMPUTER_USE_CURSOR_LABEL": "0",
            "OPEN_COMPUTER_USE_CURSOR_MOTION": "reduced",
            "OPEN_COMPUTER_USE_CURSOR_COLOR": "#a78bfa",
        ]) {
            VisualCursorSupport.performCursorAnimation { observed = VisualCursorSupport.settings }
        }
        let deadline = Date().addingTimeInterval(1)
        while observed == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        let settings = try XCTUnwrap(observed)
        XCTAssertFalse(settings.feedbackEnabled)
        XCTAssertFalse(settings.labelEnabled)
        XCTAssertTrue(settings.reducedMotion)
        XCTAssertEqual(settings.color, CursorColor(hex: "#a78bfa"))
    }

    func testQuietReducedMotionStillReachesTheTargetWithoutAnAnimationBacklog() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("A display is required") }
        let target = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        RequestConfiguration.withEnvironment([
            "OPEN_COMPUTER_USE_VISUAL_CURSOR": "1",
            "OPEN_COMPUTER_USE_CURSOR_MOTION": "reduced",
            "OPEN_COMPUTER_USE_CURSOR_FEEDBACK": "0",
        ]) {
            SoftwareCursorOverlay.moveCursor(to: target, in: nil)
            SoftwareCursorOverlay.pulseClick(at: target, clickCount: 2, mouseButton: .left, in: nil)
        }
        XCTAssertFalse(SoftwareCursorOverlay.isBusy)
        let panel = try XCTUnwrap(SoftwareCursorOverlay.overlayPanelForTesting)
        XCTAssertEqual(panel.frame.minX + SoftwareCursorPanelMetrics.tipAnchor.x, target.x, accuracy: 1)
        XCTAssertEqual(panel.frame.minY + SoftwareCursorPanelMetrics.tipAnchor.y, target.y, accuracy: 1)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testExtremelySlowExternalSettingsCannotLeaveAnInfiniteAnimation() {
        let speed = visualCursorSpeed(environment: ["OPEN_COMPUTER_USE_CURSOR_SPEED": "1e-310"])
        let travel = visualCursorTravelDuration(distance: 4_000, speed: speed)
        let pulse = visualCursorClickPulseDuration(speed: speed)
        XCTAssertTrue(travel.isFinite)
        XCTAssertLessThanOrEqual(travel, 2)
        XCTAssertGreaterThan(travel, 0)
        XCTAssertTrue(pulse.isFinite)
        XCTAssertLessThanOrEqual(pulse, 0.4)
        XCTAssertEqual(visualCursorTravelDuration(distance: 4_000, speed: speed, queuedBehind: 4), 0.16)
    }

    func testArrivalStaysInsideAWindowSmallerThanTheApproach() {
        let frame = CGRect(x: -100, y: 50, width: 30, height: 24)
        for target in [CGPoint(x: -99, y: 51), CGPoint(x: -71, y: 73)] {
            let start = visualCursorFreshStartPoint(target: target, forward: CGVector(dx: 0.6, dy: 0.8), keptInside: frame)
            XCTAssertTrue(frame.contains(start), "\(start) must stay in the destination window")
        }
    }
}
