import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorWindowActivityTests: XCTestCase {
    func testWindowFrameKeepsFullGeometryAcrossOffsetDisplays() throws {
        let mappings = [
            VisualCursorScreenMapping(screenStateFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            VisualCursorScreenMapping(screenStateFrame: CGRect(x: -1280, y: 220, width: 1280, height: 720),
                                      appKitFrame: CGRect(x: -1280, y: -40, width: 1280, height: 720))
        ]
        let spanning = CGRect(x: -100, y: 300, width: 300, height: 200)
        XCTAssertEqual(CursorWindowActivityGeometry.appKitFrame(for: spanning, mappings: mappings),
                       CGRect(x: -100, y: 400, width: 300, height: 200))
        let second = CGRect(x: -1200, y: 250, width: 400, height: 300)
        XCTAssertEqual(CursorWindowActivityGeometry.appKitFrame(for: second, mappings: mappings),
                       CGRect(x: -1200, y: 350, width: 400, height: 300))
        XCTAssertNil(CursorWindowActivityGeometry.appKitFrame(for: .null, mappings: mappings))
        XCTAssertNil(CursorWindowActivityGeometry.appKitFrame(for: CGRect(x: 5000, y: 0, width: 100, height: 100), mappings: mappings))
    }

    func testBloomLeavesDocumentTransparentAndHasASoftOuterFalloff() throws {
        let context = try bitmap(width: 480, height: 260)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        CursorWindowActivityRenderer.draw(in: context, bounds: CGRect(x: 0, y: 0, width: 480, height: 260),
            activity: .dragging, tint: CursorColor(hex: "#A78BFA"), labelEnabled: false)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * context.bytesPerRow + x * 4 + 3] }
        XCTAssertEqual(alpha(240, 130), 0, "The overlay must not dim document contents.")
        XCTAssertEqual(alpha(50, 130), 0)
        XCTAssertGreaterThan(alpha(30, 130), 0, "The glow must extend beyond a hard window outline.")
        XCTAssertGreaterThan(alpha(40, 130), alpha(30, 130))
        XCTAssertGreaterThan(alpha(30, 130), alpha(6, 130), "Bloom must soften toward the outside.")
    }

    func testActivityPanelCannotTakeInputAndDismissesOnInvalidGeometry() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("A display is required") }
        let frame = CGRect(x: screen.frame.midX - 180, y: screen.frame.midY - 100, width: 360, height: 200)
        let target = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        target.orderFrontRegardless()
        let overlay = CursorWindowActivityOverlay()
        defer { overlay.close(); target.orderOut(nil) }
        let window = CursorTargetWindow(windowID: CGWindowID(target.windowNumber), layer: target.level.rawValue)
        overlay.show(frame: frame, target: window, activity: .dragging, tint: nil, labelEnabled: true)
        let panel = try XCTUnwrap(overlay.panelForTesting)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, target.level)
        XCTAssertEqual(panel.frame, frame.insetBy(dx: -40, dy: -40))
        overlay.show(frame: .null, target: window, activity: .working, tint: nil, labelEnabled: true)
        XCTAssertFalse(panel.isVisible)
    }

    func testCancelResetAndFeedbackPreferenceClearWindowActivity() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("A display is required") }
        SoftwareCursorOverlay.reset()
        let frame = CGRect(x: screen.frame.midX - 180, y: screen.frame.midY - 100, width: 360, height: 200)
        let target = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        target.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let stage = CursorStage(client: UUID().uuidString)
        defer { stage.shutdown(); target.orderOut(nil); SoftwareCursorOverlay.reset() }
        let window = CursorTargetWindow(windowID: CGWindowID(target.windowNumber), layer: target.level.rawValue)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        func delivery(_ gesture: UInt64, completion: CursorDeliveredDragFrame.Completion? = nil) -> CursorDeliveredDragFrame {
            CursorDeliveredDragFrame(gesture: gesture, target: VisualCursorTarget(point: point, window: window),
                progress: NativeDragProgress(point: point, phase: .dragged, timestamp: gesture), completion: completion)
        }
        RequestConfiguration.withEnvironment([
            "OPEN_COMPUTER_USE_VISUAL_CURSOR": "1", "OPEN_COMPUTER_USE_CURSOR_FEEDBACK": "1",
            "OPEN_COMPUTER_USE_CURSOR_MOTION": "reduced"
        ]) {
            stage.presentDeliveredDrag(delivery(1))
            XCTAssertTrue(stage.activityPanelForTesting?.isVisible == true)
            stage.presentDeliveredDrag(delivery(1, completion: .cancelled))
            XCTAssertFalse(stage.activityPanelForTesting?.isVisible == true)
            stage.presentDeliveredDrag(delivery(2))
            XCTAssertTrue(stage.activityPanelForTesting?.isVisible == true)
            stage.reset()
            XCTAssertFalse(stage.activityPanelForTesting?.isVisible == true)
        }
        RequestConfiguration.withEnvironment([
            "OPEN_COMPUTER_USE_VISUAL_CURSOR": "1", "OPEN_COMPUTER_USE_CURSOR_FEEDBACK": "0"
        ]) {
            stage.presentDeliveredDrag(delivery(3))
            XCTAssertTrue(stage.isVisible)
            XCTAssertFalse(stage.activityPanelForTesting?.isVisible == true)
        }
    }

    /// An actual AppKit renderer preview, not a screenshot of a running user session.
    /// GODSPEED_WINDOW_ACTIVITY_PREVIEW=/absolute/path/window-activity.png enables it in CI.
    func testRenderActivityPreviewIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["GODSPEED_WINDOW_ACTIVITY_PREVIEW"], !path.isEmpty else { return }
        let context = try bitmap(width: 1440, height: 760)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.setFillColor(NSColor(calibratedWhite: 0.95, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 380, width: 1440, height: 380))
        context.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1440, height: 380))
        for row in 0..<2 {
            for (column, activity) in [CursorWindowActivity.dragging, .waiting, .delivered].enumerated() {
                context.saveGState()
                context.translateBy(x: CGFloat(column) * 480, y: CGFloat(row) * 380 + 20)
                let bounds = CGRect(x: 0, y: 0, width: 480, height: 320)
                let window = bounds.insetBy(dx: 40, dy: 40)
                context.setFillColor(NSColor(calibratedWhite: row == 0 ? 0.18 : 0.995, alpha: 1).cgColor)
                context.addPath(CGPath(roundedRect: window, cornerWidth: 12, cornerHeight: 12, transform: nil))
                context.fillPath()
                let foreground = NSColor(calibratedWhite: row == 0 ? 0.93 : 0.18, alpha: 1)
                ("Shared workspace" as NSString).draw(at: CGPoint(x: 62, y: 240), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: foreground])
                ("A quiet indication of the action in progress." as NSString).draw(at: CGPoint(x: 62, y: 215), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: foreground.withAlphaComponent(0.58)])
                for index in 0..<4 {
                    context.setFillColor(foreground.withAlphaComponent(0.055).cgColor)
                    let line = CGRect(x: 62, y: CGFloat(80 + index * 29), width: index == 0 ? 235 : 350, height: 20)
                    context.addPath(CGPath(roundedRect: line, cornerWidth: 5, cornerHeight: 5, transform: nil))
                    context.fillPath()
                }
                CursorWindowActivityRenderer.draw(in: context, bounds: bounds, activity: activity,
                    tint: CursorColor(hex: "#A78BFA"), labelEnabled: true)
                context.restoreGState()
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    }
}
