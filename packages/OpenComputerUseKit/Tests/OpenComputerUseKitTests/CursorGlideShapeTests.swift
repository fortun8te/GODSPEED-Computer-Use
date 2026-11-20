import AppKit
import XCTest
@testable import OpenComputerUseKit

final class CursorGlideShapeTests: XCTestCase {
    private func restForward() -> CGVector {
        let angle = visualCursorAppKitForwardHeading(renderRotation: 0)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    func testPlannedGlidesReachTheDestinationWithoutBacktracking() {
        let bounds = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let start = CGPoint(x: 1280, y: 720)
        for degrees in stride(from: 0.0, to: 360.0, by: 15.0) {
            let radians = degrees * .pi / 180
            let end = CGPoint(x: start.x + cos(radians) * 600, y: start.y + sin(radians) * 600)
            let glide = CursorGlide(
                start: start, end: end, startVelocity: .zero, startForward: restForward(), restForward: restForward(),
                bounds: bounds, planned: true, startTime: 0, speed: 1, queuedBehind: 0
            )
            guard case let .planned(path) = glide.shape else { return XCTFail("\(degrees)°: expected a planned move") }
            XCTAssertEqual(path.segments.count, 1)
            var previous: CGFloat = 0
            for step in 0...200 {
                let point = glide.point(at: glide.duration * Double(step) / 200)
                let forward = (point.x - start.x) * cos(radians) + (point.y - start.y) * sin(radians)
                XCTAssertGreaterThanOrEqual(forward, previous - 1e-9)
                XCTAssertTrue(bounds.contains(point))
                previous = forward
            }
            XCTAssertEqual(glide.point(at: glide.duration).x, end.x, accuracy: 0.01)
            XCTAssertEqual(glide.point(at: glide.duration).y, end.y, accuracy: 0.01)
            XCTAssertLessThanOrEqual(glide.duration, 0.45)
        }
    }

    func testShortHopsScootWithALightTiltThatReturnsToZero() {
        let glide = CursorGlide(
            start: CGPoint(x: 100, y: 100), end: CGPoint(x: 140, y: 100), startVelocity: .zero,
            startForward: restForward(), restForward: restForward(), bounds: nil, planned: true,
            startTime: 0, speed: 1, queuedBehind: 0
        )
        guard case let .straight(tilt) = glide.shape else { return XCTFail("a 40 px hop scoots") }
        XCTAssertGreaterThan(abs(tilt), 0.1)
        XCTAssertLessThanOrEqual(abs(tilt), 1 / 3)
        XCTAssertEqual(glide.tilt(at: glide.duration), 0, accuracy: 1e-6)
    }

    func testCarriedSpeedStartsTheNewGlideMovingInsteadOfFromRest() {
        let still = CursorGlide(
            start: .zero, end: CGPoint(x: 120, y: 0), startVelocity: .zero, startForward: restForward(),
            restForward: restForward(), bounds: nil, planned: false, startTime: 0, speed: 1, queuedBehind: 0
        )
        let moving = CursorGlide(
            start: .zero, end: CGPoint(x: 120, y: 0), startVelocity: CGVector(dx: 900, dy: 0), startForward: restForward(),
            restForward: restForward(), bounds: nil, planned: false, startTime: 0, speed: 1, queuedBehind: 0
        )
        XCTAssertEqual(still.initialRate, 0)
        XCTAssertGreaterThan(moving.initialRate, 0.5)
        XCTAssertGreaterThan(moving.point(at: 0.01).x, still.point(at: 0.01).x)
    }

    func testPlannerKeepsBothTheCurveAndItsControlsInsideDisplay() {
        let bounds = CGRect(x: 100, y: 200, width: 1300, height: 900)
        let route = CursorPathPlanner.plan(
            start: CGPoint(x: 101, y: 201), end: CGPoint(x: 1399, y: 201), bounds: bounds,
            startForward: CGVector(dx: 0, dy: -1), restForward: CGVector(dx: 0, dy: 1)
        )
        XCTAssertTrue(route.path.segments.allSatisfy { bounds.contains($0.control1) && bounds.contains($0.control2) })
        XCTAssertTrue(route.path.sampledConstraintPoints().allSatisfy(bounds.contains))
        XCTAssertGreaterThanOrEqual(route.length, 1298)
    }

    func testStaggeredDisplaysUseASharedEdgeInsteadOfTheGap() throws {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let right = CGRect(x: 1000, y: 300, width: 1200, height: 800)
        let start = CGPoint(x: 990, y: 15)
        let end = CGPoint(x: 1800, y: 420)
        XCTAssertFalse(CursorPathPlanner.isVisibleTrip(from: start, to: end, displays: [left, right]))
        let seam = try XCTUnwrap(CursorPathPlanner.crossing(from: start, to: end, between: left, and: right))
        let glide = CursorGlide(
            start: start, end: end, startVelocity: .zero, startForward: restForward(), restForward: restForward(),
            bounds: nil, planned: false, via: seam, startTime: 0, speed: 1, queuedBehind: 0
        )
        for sample in 0...100 {
            let point = glide.point(progress: CGFloat(sample) / 100)
            XCTAssertTrue(left.contains(point) || right.contains(point))
        }
        XCTAssertEqual(glide.point(progress: 1), end)
        let detached = right.offsetBy(dx: 50, dy: 0)
        XCTAssertFalse(CursorPathPlanner.isVisibleTrip(from: start, to: end, displays: [left, detached]))
        XCTAssertNil(CursorPathPlanner.crossing(from: start, to: end, between: left, and: detached))
        XCTAssertTrue(CursorPathPlanner.isVisibleTrip(from: CGPoint(x: 980, y: 410), to: end, displays: [left, right]))
    }
}
