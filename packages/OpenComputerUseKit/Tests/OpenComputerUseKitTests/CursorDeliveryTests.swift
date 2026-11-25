import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorDeliveryTests: XCTestCase {
    func testResetDiscardsQueuedActionsWithoutBlockingFreshWork() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var seen: [String] = []
        RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_CURSOR_ASYNC": "1"]) {
            VisualCursorSupport.performCursorAnimation(kind: .move) { seen.append("stale move") }
            VisualCursorSupport.performCursorAnimation { seen.append("stale click") }
            SoftwareCursorOverlay.reset()
            VisualCursorSupport.performCursorAnimation { seen.append("fresh action") }
        }
        drainDeliveries()
        XCTAssertEqual(seen, ["fresh action"], "A reset must revoke actions queued before ownership changed.")
    }

    func testResetDuringDeliveryDiscardsRetainedActionsAndAnOldDeferredReset() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var seen: [String] = []
        RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_CURSOR_ASYNC": "1"]) {
            VisualCursorSupport.performCursorAnimation {
                seen.append("started")
                SoftwareCursorOverlay.resetWhenIdle()
                XCTAssertTrue(VisualCursorSupport.deferredReset)
                SoftwareCursorOverlay.reset()
                XCTAssertFalse(VisualCursorSupport.deferredReset)
                VisualCursorSupport.performCursorAnimation { seen.append("fresh action") }
            }
            // This action has already been removed from `pending` when the first callback runs.
            VisualCursorSupport.performCursorAnimation { seen.append("stale retained click") }
        }
        drainDeliveries()
        XCTAssertEqual(seen, ["started", "fresh action"])
    }

    private func drainDeliveries() {
        let deadline = Date().addingTimeInterval(1)
        while VisualCursorSupport.isDraining, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertFalse(VisualCursorSupport.isDraining)
        XCTAssertEqual(VisualCursorSupport.queuedAnimations, 0)
    }

    func testMovementBurstCoalescesSeparatelyForEachClient() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("A display is required for overlay rendering") }
        let prefix = UUID().uuidString
        let left = prefix + "-left"
        let right = prefix + "-right"
        let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let start = CACurrentMediaTime()
        var moves: [String: Int] = [:]
        var lastPoints: [String: CGPoint] = [:]
        var drainedAt: CFTimeInterval?
        defer { SoftwareCursorOverlay.reset() }

        for i in 0..<40 {
            for (client, x) in [(left, center.x - 130), (right, center.x + 130)] {
                let point = CGPoint(x: x, y: center.y + CGFloat(i) * 2)
                ClientScope.with(client) {
                    VisualCursorSupport.performCursorAnimation(kind: .move) {
                        moves[client, default: 0] += 1
                        lastPoints[client] = point
                        SoftwareCursorOverlay.moveCursor(to: point, in: nil)
                    }
                }
            }
        }
        VisualCursorSupport.performCursorAnimation { drainedAt = CACurrentMediaTime() }
        let deadline = Date().addingTimeInterval(2)
        while drainedAt == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        let elapsed = (try XCTUnwrap(drainedAt) - start) * 1000
        print("cursor burst: 80 requests, \(moves.values.reduce(0, +)) move deliveries, \(Int(elapsed.rounded())) ms to drain")
        XCTAssertEqual(lastPoints[left], CGPoint(x: center.x - 130, y: center.y + 78))
        XCTAssertEqual(lastPoints[right], CGPoint(x: center.x + 130, y: center.y + 78))
        XCTAssertEqual(moves[left], 1)
        XCTAssertEqual(moves[right], 1)

        SoftwareCursorOverlay.waitUntilIdleForTesting()
        let anchor = SoftwareCursorPanelMetrics.tipAnchor
        for client in [left, right] {
            let point = try XCTUnwrap(lastPoints[client])
            let panel = try XCTUnwrap(ClientScope.with(client) { SoftwareCursorOverlay.overlayPanelForTesting })
            XCTAssertEqual(panel.frame.minX + anchor.x, point.x, accuracy: 1)
            XCTAssertEqual(panel.frame.minY + anchor.y, point.y, accuracy: 1)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertTrue(panel.ignoresMouseEvents)
        }
    }

    func testGestureBoundariesRetainMovesForTheirOwnClient() {
        var seen: [String] = []
        let left = UUID().uuidString
        let right = UUID().uuidString
        let actions: [(String, VisualCursorSupport.AnimationKind, String)] = [
            (left, .move, "left arrival"),
            (right, .move, "right superseded"),
            (left, .other, "left click"),
            (right, .move, "right arrival"),
            (left, .move, "left superseded"),
            (right, .other, "right settle"),
            (left, .move, "left departure"),
        ]
        for (client, kind, action) in actions {
            ClientScope.with(client) {
                VisualCursorSupport.performCursorAnimation(kind: kind) { seen.append(action) }
            }
        }
        let deadline = Date().addingTimeInterval(1)
        while VisualCursorSupport.queuedAnimations > 0, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertEqual(seen, ["left arrival", "left click", "right arrival", "right settle", "left departure"])
    }
}
