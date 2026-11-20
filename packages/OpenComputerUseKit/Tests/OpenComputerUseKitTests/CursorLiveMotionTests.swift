import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Plays a tour with the real overlay on the main display (display link, panel, frame clock) and records every
/// frame it actually draws. Opt-in because it shows a cursor on screen: `GODSPEED_CURSOR_LIVE=<dir>` writes
/// `live-frames.json` and `live-metrics.json` there. Posts no input events and touches no app.
final class CursorLiveMotionTests: XCTestCase {
    struct Sample: Codable { let t: Double; let x: Double; let y: Double; let rotation: Double; let press: Double }

    struct Report: Codable {
        var frames: Int
        var medianFrameMs: Double
        var p99FrameMs: Double
        /// Frames that took more than 1.5x the median while the cursor was moving.
        var hitches: Int
        var worstSpeedJump: Double
        var worstTurnDegrees: Double
        var maxLeanDegrees: Double
        var landingErrorPoints: Double
    }

    @MainActor
    func testLiveTourOnTheRealOverlay() throws {
        guard let dir = ProcessInfo.processInfo.environment["GODSPEED_CURSOR_LIVE"] else { throw XCTSkip("live demo only") }
        guard let screen = NSScreen.main?.frame, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("needs a display with Reduce Motion off")
        }
        _ = NSApplication.shared
        setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR", "1", 1)
        setenv("OPEN_COMPUTER_USE_CURSOR_FLOAT", "1", 1)
        defer {
            SoftwareCursorOverlay.frameObserverForTesting = nil
            SoftwareCursorOverlay.reset()
            unsetenv("OPEN_COMPUTER_USE_CURSOR_FLOAT")
        }
        var samples: [Sample] = []
        SoftwareCursorOverlay.frameObserverForTesting = { time, state, press in
            samples.append(Sample(t: time, x: state.tipPosition.x, y: state.tipPosition.y, rotation: state.rotation, press: press))
        }
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: screen.minX + screen.width * fx, y: screen.minY + screen.height * fy)
        }
        let stops = [at(0.30, 0.55), at(0.78, 0.78), at(0.50, 0.40), at(0.53, 0.37), at(0.08, 0.985), at(0.86, 0.17), at(0.25, 0.60)]
        SoftwareCursorOverlay.settle(at: at(0.5, 0.5), in: nil)
        SoftwareCursorOverlay.waitUntilIdleForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        for stop in stops {
            SoftwareCursorOverlay.moveCursor(to: stop, in: nil)
            SoftwareCursorOverlay.pulseClick(at: stop, clickCount: 1, mouseButton: .left, in: nil)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        }
        let last = try XCTUnwrap(samples.last)
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(samples).write(to: folder.appendingPathComponent("live-frames.json"))

        let intervals = zip(samples, samples.dropFirst()).map { ($1.t - $0.t) * 1000 }.filter { $0 > 0 }.sorted()
        let median = intervals[intervals.count / 2]
        var hitches = 0, jump = 0.0, turn = 0.0, peak = 1.0
        var speeds: [Double] = []
        for (a, b) in zip(samples, samples.dropFirst()) where b.t > a.t {
            speeds.append(hypot(b.x - a.x, b.y - a.y) / (b.t - a.t))
            if hypot(b.x - a.x, b.y - a.y) > 1, (b.t - a.t) * 1000 > median * 1.5 { hitches += 1 }
        }
        peak = max(speeds.max() ?? 1, 1)
        for (a, b) in zip(speeds, speeds.dropFirst()) { jump = max(jump, abs(b - a) / peak) }
        for i in 2..<samples.count {
            let ax = samples[i - 1].x - samples[i - 2].x, ay = samples[i - 1].y - samples[i - 2].y
            let bx = samples[i].x - samples[i - 1].x, by = samples[i].y - samples[i - 1].y
            guard hypot(ax, ay) > 2, hypot(bx, by) > 2 else { continue }
            turn = max(turn, abs(Double(CursorPoseDynamics.normalize(CGFloat(atan2(by, bx) - atan2(ay, ax))))) * 180 / .pi)
        }
        let report = Report(
            frames: samples.count, medianFrameMs: median, p99FrameMs: intervals[Int(Double(intervals.count - 1) * 0.99)],
            hitches: hitches, worstSpeedJump: jump, worstTurnDegrees: turn,
            maxLeanDegrees: samples.map { abs($0.rotation) }.max()! * 180 / .pi,
            landingErrorPoints: hypot(last.x - stops.last!.x, last.y - stops.last!.y)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: folder.appendingPathComponent("live-metrics.json"))
        XCTAssertLessThan(report.landingErrorPoints, 0.5)
        XCTAssertLessThan(report.worstTurnDegrees, 25)
    }
}
