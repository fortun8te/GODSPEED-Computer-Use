import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Pure-math checks on how the cursor moves: easing, lean, paths across displays and mid-flight retargets.
/// Nothing here opens a window. `CursorMotionFilmstripTests` renders the same scenarios as pictures.
final class CursorMotionQualityTests: XCTestCase {
    private let base = visualCursorRenderBaseHeading()

    private func restForward() -> CGVector {
        let angle = visualCursorAppKitForwardHeading(renderRotation: 0)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    private func glide(_ start: CGPoint, _ end: CGPoint, bounds: CGRect? = nil, velocity: CGVector = .zero) -> CursorGlide {
        CursorGlide(start: start, end: end, startVelocity: velocity, startForward: restForward(), restForward: restForward(),
                    bounds: bounds, planned: true, startTime: 0, speed: 1, queuedBehind: 0)
    }

    func testEasingStartsAndLandsWithoutAJoltAndNeverBacktracks() {
        for rate in stride(from: CGFloat(0), through: visualCursorMaxInitialRate, by: 0.2) {
            XCTAssertEqual(visualCursorEase(0, initialRate: rate), 0, accuracy: 1e-9)
            XCTAssertEqual(visualCursorEase(1, initialRate: rate), 1, accuracy: 1e-9)
            XCTAssertEqual(visualCursorEaseRate(0, initialRate: rate), rate, accuracy: 1e-9, "starts at the carried rate")
            XCTAssertEqual(visualCursorEaseRate(1, initialRate: rate), 0, accuracy: 1e-9, "lands at rest")
            // Acceleration is zero at both ends: no kick on take-off, no thud on landing.
            let h: CGFloat = 1e-4
            XCTAssertEqual((visualCursorEaseRate(h, initialRate: rate) - visualCursorEaseRate(0, initialRate: rate)) / h, 0, accuracy: 0.02)
            XCTAssertEqual((visualCursorEaseRate(1, initialRate: rate) - visualCursorEaseRate(1 - h, initialRate: rate)) / h, 0, accuracy: 0.02)
            var previous: CGFloat = 0
            for step in 1...400 {
                let value = visualCursorEase(CGFloat(step) / 400, initialRate: rate)
                XCTAssertGreaterThanOrEqual(value, previous - 1e-9, "rate \(rate) backtracks")
                previous = value
            }
        }
        // Peak speed comes a little before the middle, so the landing is the long gentle part.
        let peak = (0...100).max { visualCursorEaseRate(CGFloat($0) / 100) < visualCursorEaseRate(CGFloat($1) / 100) }!
        XCTAssertEqual(Double(peak), 40, accuracy: 2)
    }

    func testLeanHasTheSameSideForShortHopsAndLongGlides() {
        // A short hop (straight) and a long glide (arc) to the right must lean the same way.
        let hop = glide(CGPoint(x: 500, y: 500), CGPoint(x: 540, y: 500))
        let long = glide(CGPoint(x: 500, y: 500), CGPoint(x: 1300, y: 500))
        guard case .straight = hop.shape, case .planned = long.shape else { return XCTFail("expected a hop and an arc") }
        let hopLean = visualCursorGlideTargetAngle(hop, at: hop.duration * 0.4, baseHeading: base)
        let longLean = visualCursorGlideTargetAngle(long, at: long.duration * 0.4, baseHeading: base)
        XCTAssertGreaterThan(abs(hopLean), 0.05)
        XCTAssertGreaterThan(abs(longLean), 0.05)
        XCTAssertEqual(hopLean.sign, longLean.sign)
    }

    func testLeanNeverFlipsSidesWhenMovingAlongTheArrow() {
        let rest = restForward()
        let start = CGPoint(x: 1200, y: 800)
        // Against the arrow's heading: the old clamped-angle lean jumped between +19° and -19° here.
        let end = CGPoint(x: start.x - rest.dx * 700, y: start.y - rest.dy * 700)
        let move = glide(start, end)
        for step in 0...100 {
            let lean = visualCursorGlideTargetAngle(move, at: move.duration * Double(step) / 100, baseHeading: base)
            XCTAssertLessThan(abs(lean), 0.03, "step \(step)")
        }
    }

    func testLeanIsUprightAgainWhenTheTipLands() throws {
        let scenario = CursorMotionFilmstripTests.Scenario(
            name: "land", start: CGPoint(x: 300, y: 300), moves: [CursorMotionFilmstripTests.Move(to: CGPoint(x: 1200, y: 700), hold: 0)]
        )
        let frames = CursorMotionFilmstripTests.simulate(scenario)
        let landing = try XCTUnwrap(frames.firstIndex { $0.tip == CGPoint(x: 1200, y: 700) })
        XCTAssertLessThan(abs(frames[landing].state.rotation) * 180 / .pi, 3, "arrow still leaning when it lands")
    }

    func testTargetsNextToTheDisplayEdgeArcOnScreenAndKeepTheirMomentum() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        // A menu bar item: within a few points of the top edge.
        let move = visualCursorPlanGlide(
            from: CGPoint(x: 900, y: 560), to: CGPoint(x: 260, y: 988), velocity: CGVector(dx: -400, dy: 300), poseAngle: 0,
            screenFrame: screen, dragging: false, changesDisplay: false, route: nil, at: 0, speed: 1, queuedBehind: 0, fadesIn: false
        )
        guard case .planned = move.shape else { return XCTFail("edge targets glide like any other") }
        XCTAssertGreaterThan(move.initialRate, 0, "momentum is kept next to the edge")
        for step in 0...200 {
            XCTAssertTrue(screen.contains(move.point(at: move.duration * Double(step) / 200)))
        }
    }

    func testWindowMovedMidFlightBendsInsteadOfTurningACorner() {
        let scenario = CursorMotionFilmstripTests.scenarios.first { $0.name == "11-retarget" }!
        let metrics = CursorMotionFilmstripTests.metrics(scenario, CursorMotionFilmstripTests.simulate(scenario))
        XCTAssertLessThan(metrics.worstTurnDegrees, 20)
        XCTAssertLessThan(metrics.worstSpeedJump, 0.25)
    }

    func testCrossingDisplaysBanksThroughTheSharedEdge() {
        let scenario = CursorMotionFilmstripTests.scenarios.first { $0.name == "13-two-displays" }!
        let metrics = CursorMotionFilmstripTests.metrics(scenario, CursorMotionFilmstripTests.simulate(scenario))
        XCTAssertLessThan(metrics.worstTurnDegrees, 15)
        XCTAssertFalse(metrics.leftDisplays)
    }

    func testRouteFindsAPathThroughThreeDisplays() throws {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let middle = CGRect(x: 1000, y: 0, width: 1000, height: 600)
        let top = CGRect(x: 1000, y: 600, width: 1000, height: 600)
        let displays = [left, middle, top]
        let start = CGPoint(x: 200, y: 100)
        let end = CGPoint(x: 1500, y: 1150)
        XCTAssertFalse(CursorPathPlanner.isVisibleTrip(from: start, to: end, displays: displays))
        let waypoints = try XCTUnwrap(CursorPathPlanner.route(from: start, to: end, displays: displays))
        XCTAssertEqual(waypoints.count, 4, "left -> middle -> top")
        let path = CursorPathPlanner.through(waypoints, displays: displays)
        let move = CursorGlide(start: start, end: end, startVelocity: .zero, startForward: restForward(), restForward: restForward(),
                               bounds: nil, planned: false, route: path, startTime: 0, speed: 1, queuedBehind: 0)
        for step in 0...400 {
            let point = move.point(progress: CGFloat(step) / 400)
            XCTAssertTrue(displays.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) }, "step \(step) at \(point)")
        }
        XCTAssertNil(CursorPathPlanner.route(from: start, to: CGPoint(x: 3000, y: 100), displays: displays + [CGRect(x: 2100, y: 0, width: 1000, height: 600)]),
                     "a display behind a gap has no route")
    }

    func testEveryRenderedScenarioMovesSmoothly() {
        for scenario in CursorMotionFilmstripTests.scenarios {
            let metrics = CursorMotionFilmstripTests.metrics(scenario, CursorMotionFilmstripTests.simulate(scenario))
            XCTAssertFalse(metrics.leftDisplays, scenario.name)
            XCTAssertLessThan(metrics.worstTurnDegrees, 20, scenario.name)
            XCTAssertLessThan(metrics.worstSpeedJump, 0.4, scenario.name)
            XCTAssertLessThan(metrics.maxLeanDegrees, 18, scenario.name)
        }
    }

    func testNameTagSitsBesideTheArrowAndStaysOnScreen() {
        let tip = SoftwareCursorPanelMetrics.tipAnchor
        let room = CGRect(origin: .zero, size: SoftwareCursorPanelMetrics.size).insetBy(dx: 4, dy: 0)
        // Default: right of the arrow, centred a little below the tip (beside the arrow's body).
        let tag = visualCursorNameTagFrame(width: 70, height: 19, available: room)
        XCTAssertEqual(tag.minX, tip.x + 21, accuracy: 0.01)
        XCTAssertLessThan(tag.midY, tip.y)
        XCTAssertGreaterThan(tag.maxY, tip.y - 22)
        // Near a display's right edge (the window is clipped just past the arrow), it moves to the left of the tip.
        let clippedRight = CGRect(x: room.minX, y: room.minY, width: tip.x + 40 - room.minX, height: room.height)
        let left = visualCursorNameTagFrame(width: 70, height: 19, available: clippedRight)
        XCTAssertLessThan(left.maxX, tip.x)
        XCTAssertTrue(clippedRight.contains(left))
        // Near the bottom edge, it goes above the tip.
        let clippedBottom = CGRect(x: room.minX, y: tip.y - 10, width: room.width, height: room.maxY - (tip.y - 10))
        XCTAssertGreaterThan(visualCursorNameTagFrame(width: 70, height: 19, available: clippedBottom).minY, tip.y)
        // The glyph keeps its own 126 pt art space inside the wider window.
        XCTAssertEqual(SoftwareCursorPanelMetrics.glyphRect.size, SoftwareCursorGlyphMetrics.windowSize)
    }
}
