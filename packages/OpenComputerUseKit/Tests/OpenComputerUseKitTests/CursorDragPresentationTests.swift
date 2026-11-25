import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorDragPresentationTests: XCTestCase {
    private func progress(_ x: CGFloat, _ timestamp: UInt64, phase: NativeDragProgress.Phase = .dragged) -> NativeDragProgress {
        NativeDragProgress(point: CGPoint(x: x, y: 80), phase: phase, timestamp: timestamp)
    }

    private func drain() {
        let deadline = Date().addingTimeInterval(1)
        while VisualCursorSupport.isDraining, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertFalse(VisualCursorSupport.isDraining)
    }

    func testBusyMainThreadDrawsLatestDeliveryWithoutReplayingIntermediatePoints() throws {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var frames: [CursorDeliveredDragFrame] = []
        RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_CURSOR_ASYNC": "1"]) {
            let cursor = CursorDragPresentation(window: nil, mappings: []) { frames.append($0) }
            for index in 1...30 { cursor.record(progress(CGFloat(index), UInt64(index))) }
            cursor.record(progress(30, 31, phase: .released))
            cursor.finish()
            XCTAssertEqual(VisualCursorSupport.queuedAnimations, 1, "One gesture owns at most one pending presentation.")
        }
        drain()
        XCTAssertEqual(frames.count, 1)
        let final = try XCTUnwrap(frames.last)
        XCTAssertEqual(final.target.point, CGPoint(x: 30, y: 80))
        XCTAssertEqual(final.progress.phase, .released)
        XCTAssertEqual(final.completion, .delivered)
    }

    func testNewProgressAfterDrainSchedulesOneNewFrame() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var points: [CGPoint] = []
        let cursor = CursorDragPresentation(window: nil, mappings: []) { points.append($0.target.point) }
        cursor.record(progress(10, 10))
        drain()
        cursor.record(progress(20, 20))
        cursor.record(progress(30, 30))
        drain()
        XCTAssertEqual(points, [CGPoint(x: 10, y: 80), CGPoint(x: 30, y: 80)])
    }

    func testCancellationRetainsLastPostedPointAndRejectsLateOrInvalidUpdates() throws {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var frames: [CursorDeliveredDragFrame] = []
        let cursor = CursorDragPresentation(window: nil, mappings: []) { frames.append($0) }
        cursor.record(progress(20, 20))
        cursor.record(progress(10, 10))
        cursor.record(progress(.nan, 30))
        cursor.finish(cancelled: true)
        cursor.record(progress(900, 900))
        cursor.finish()
        drain()
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.target.point, CGPoint(x: 20, y: 80))
        XCTAssertEqual(frame.completion, .cancelled)
    }

    func testResetRevokesQueuedAndFutureUpdatesFromAnOldGesture() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var seen: [String] = []
        let stale = CursorDragPresentation(window: nil, mappings: []) { _ in seen.append("stale") }
        stale.record(progress(10, 10))
        SoftwareCursorOverlay.reset()
        stale.record(progress(20, 20))
        stale.finish()
        let fresh = CursorDragPresentation(window: nil, mappings: []) { _ in seen.append("fresh") }
        fresh.record(progress(30, 30))
        drain()
        XCTAssertEqual(seen, ["fresh"])
    }

    func testProgressKeepsOriginalClientAndPreferencesOutsideItsRequestScope() throws {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var clients: [String] = []
        var colors: [CursorColor?] = []
        let cursor = ClientScope.with("drag-owner") {
            RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_CURSOR_COLOR": "#A78BFA"]) {
                CursorDragPresentation(window: nil, mappings: []) { _ in
                    clients.append(VisualCursorSupport.cursorClient)
                    colors.append(VisualCursorSupport.settings.color)
                }
            }
        }
        ClientScope.with("unrelated-agent") {
            RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_CURSOR_COLOR": "#34D399"]) {
                cursor.record(progress(10, 10))
                cursor.finish()
            }
        }
        drain()
        XCTAssertEqual(clients, ["drag-owner"])
        XCTAssertEqual(colors, [CursorColor(hex: "#A78BFA")])
    }

    func testPreflightFailureNeverInventsDeliveredMovement() {
        SoftwareCursorOverlay.reset()
        defer { SoftwareCursorOverlay.reset() }
        var frames = 0
        let cursor = CursorDragPresentation(window: nil, mappings: []) { _ in frames += 1 }
        XCTAssertThrowsError(try cursor.delivering { _ in
            throw ComputerUseError.stateUnavailable("Endpoint changed before input.")
        })
        drain()
        XCTAssertEqual(frames, 0)
        XCTAssertEqual(VisualCursorSupport.queuedAnimations, 0)
    }

    func testLiveDragOverridesCosmeticBacklogAndRejectsOlderEventTimestamps() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("A display is required") }
        SoftwareCursorOverlay.reset()
        let stage = CursorStage(client: UUID().uuidString)
        defer { stage.shutdown(); SoftwareCursorOverlay.reset() }
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let later = CGPoint(x: point.x + 30, y: point.y + 20)
        func frame(_ gesture: UInt64, _ point: CGPoint, _ timestamp: UInt64) -> CursorDeliveredDragFrame {
            CursorDeliveredDragFrame(gesture: gesture, target: VisualCursorTarget(point: point, window: nil),
                                     progress: NativeDragProgress(point: point, phase: .dragged, timestamp: timestamp))
        }
        RequestConfiguration.withEnvironment([
            "OPEN_COMPUTER_USE_VISUAL_CURSOR": "1", "OPEN_COMPUTER_USE_CURSOR_SPEED": "0.25",
            "OPEN_COMPUTER_USE_CURSOR_MOTION": "natural"
        ]) {
            stage.moveCursor(to: CGPoint(x: point.x - 100, y: point.y), in: nil)
            stage.beginFeedback(.typing, at: point, in: nil)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertTrue(stage.isBusy) }
        }
        try RequestConfiguration.withEnvironment([
            "OPEN_COMPUTER_USE_VISUAL_CURSOR": "1", "OPEN_COMPUTER_USE_CURSOR_MOTION": "reduced"
        ]) {
            stage.presentDeliveredDrag(frame(10, point, 10))
            XCTAssertFalse(stage.isBusy)
            XCTAssertEqual(stage.pendingStepCount, 0)
            stage.presentDeliveredDrag(frame(11, later, 20))
            stage.presentDeliveredDrag(frame(10, point, 10))
            let panel = try XCTUnwrap(stage.overlayPanelForTesting)
            XCTAssertEqual(panel.frame.minX + SoftwareCursorPanelMetrics.tipAnchor.x, later.x, accuracy: 1)
            XCTAssertEqual(panel.frame.minY + SoftwareCursorPanelMetrics.tipAnchor.y, later.y, accuracy: 1)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            // Request 9 was created first but waited for the input lock: its real posted
            // event is now the latest, so creation order must not suppress its presentation.
            stage.presentDeliveredDrag(frame(9, point, 30))
            XCTAssertEqual(panel.frame.minX + SoftwareCursorPanelMetrics.tipAnchor.x, point.x, accuracy: 1)
        }
    }
}
