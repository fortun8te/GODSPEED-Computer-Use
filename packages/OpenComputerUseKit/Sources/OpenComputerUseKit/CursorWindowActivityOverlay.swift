import AppKit
import CoreGraphics

enum CursorWindowActivity: String, CaseIterable {
    case working = "Working"
    case dragging = "Dragging"
    case typing = "Typing"
    case scrolling = "Scrolling"
    case waiting = "Waiting"
    case delivered = "Delivered"

    var isActive: Bool { self != .waiting && self != .delivered }
}

enum CursorWindowActivityGeometry {
    static let padding: CGFloat = 40

    /// Do not clamp the corners to a display: a window can straddle screens and the
    /// halo must retain the same frame as that window, including its off-screen portion.
    static func appKitFrame(for frame: CGRect, mappings: [VisualCursorScreenMapping]) -> CGRect? {
        guard CursorRestingAnchor.isUsable(frame) else { return nil }
        let mapping = mappings.max { lhs, rhs in
            let a = frame.intersection(lhs.screenStateFrame)
            let b = frame.intersection(rhs.screenStateFrame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        guard let mapping, frame.intersects(mapping.screenStateFrame) else { return nil }
        return CGRect(x: mapping.appKitFrame.minX + frame.minX - mapping.screenStateFrame.minX,
                      y: mapping.appKitFrame.maxY - (frame.maxY - mapping.screenStateFrame.minY),
                      width: frame.width, height: frame.height)
    }
}

/// A cached, passive window-edge treatment. It never activates, captures pixels, takes
/// input, follows the physical mouse, or animates a timer. Draw only when geometry/status
/// changes; reduced-motion users receive the same static, readable activity indication.
@MainActor
final class CursorWindowActivityOverlay {
    private var panel: ActivityPanel?
    private var view: CursorWindowActivityView?
    private var target: CursorTargetWindow?

    var panelForTesting: NSWindow? { panel }

    /// Returns the panel number only when it was reordered, so its software cursor can
    /// remain above it without changing the target's order relative to the user's apps.
    @discardableResult
    func show(frame: CGRect, target: CursorTargetWindow, activity: CursorWindowActivity,
              tint: CursorColor?, labelEnabled: Bool, reorder: Bool = false) -> Int? {
        guard CursorRestingAnchor.isUsable(frame), target.windowID != 0 else { hide(); return nil }
        if panel == nil {
            let panel = ActivityPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            let view = CursorWindowActivityView(frame: .zero)
            panel.contentView = view
            self.panel = panel
            self.view = view
        }
        guard let panel, let view else { return nil }
        let padded = frame.insetBy(dx: -CursorWindowActivityGeometry.padding, dy: -CursorWindowActivityGeometry.padding)
        let level = NSWindow.Level(rawValue: target.layer)
        let needsOrdering = reorder || self.target != target || !panel.isVisible || panel.level != level
        if panel.frame != padded {
            panel.setFrame(padded, display: false)
            view.frame = CGRect(origin: .zero, size: padded.size)
            view.needsDisplay = true
        }
        view.update(activity: activity, tint: tint, labelEnabled: labelEnabled)
        self.target = target
        if panel.level != level { panel.level = level }
        if needsOrdering {
            // Keep the bloom attached to the target even when the cursor's optional Float
            // preference is enabled. Another app in front continues to occlude the bloom.
            panel.order(.above, relativeTo: Int(target.windowID))
            return panel.windowNumber
        }
        return nil
    }

    func hide() { panel?.orderOut(nil); target = nil }

    func close() {
        hide()
        panel?.close()
        panel = nil
        view = nil
    }
}

private final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shared by the overlay and the offline render regression/preview.
@MainActor
final class CursorWindowActivityView: NSView {
    private var activity: CursorWindowActivity = .working
    private var tint: CursorColor?
    private var labelEnabled = true

    func update(activity: CursorWindowActivity, tint: CursorColor?, labelEnabled: Bool) {
        guard self.activity != activity || self.tint != tint || self.labelEnabled != labelEnabled else { return }
        self.activity = activity
        self.tint = tint
        self.labelEnabled = labelEnabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        CursorWindowActivityRenderer.draw(in: context, bounds: bounds, activity: activity,
                                           tint: tint, labelEnabled: labelEnabled)
    }
}

@MainActor
enum CursorWindowActivityRenderer {
    static func draw(in context: CGContext, bounds: CGRect, activity: CursorWindowActivity,
                     tint: CursorColor?, labelEnabled: Bool) {
        let window = bounds.insetBy(dx: CursorWindowActivityGeometry.padding, dy: CursorWindowActivityGeometry.padding)
        guard window.width > 0, window.height > 0 else { return }
        let accent = tint ?? CursorColor(hex: "#A29AAE")!
        let strength: CGFloat = activity == .waiting ? 0.64 : activity == .delivered ? 0.8 : 1
        let core = NSColor(calibratedRed: accent.red * 0.30, green: accent.green * 0.30,
                           blue: accent.blue * 0.30, alpha: 0.80 * strength).cgColor
        let edge = CGPath(roundedRect: window, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.saveGState()
        // Keep window contents untouched. Only the boundary and the broad outer falloff
        // are painted; there is no glass sheet or dimming layer over the user's document.
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addRoundedRect(in: window.insetBy(dx: 1, dy: 1), cornerWidth: 11, cornerHeight: 11)
        context.addPath(outside)
        context.clip(using: .evenOdd)
        for (blur, alpha) in [(CGFloat(28), CGFloat(0.32)), (CGFloat(12), CGFloat(0.25))] {
            context.setShadow(offset: .zero, blur: blur,
                color: NSColor(calibratedRed: accent.red * 0.48, green: accent.green * 0.48,
                               blue: accent.blue * 0.48, alpha: alpha * strength).cgColor)
            context.addPath(edge)
            context.setStrokeColor(core)
            context.setLineWidth(2)
            context.strokePath()
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(edge)
        context.setStrokeColor(core)
        context.setLineWidth(1.25)
        context.strokePath()
        context.restoreGState()

        guard labelEnabled else { return }
        let label = activity.rawValue as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 0.98)
        ]
        let textSize = label.size(withAttributes: attributes)
        let width = textSize.width + 29
        let badge = CGRect(x: max(window.minX + 4, window.maxX - width - 12), y: window.maxY + 8,
                           width: width, height: 22)
        context.saveGState()
        context.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 0.94).cgColor)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 11, cornerHeight: 11, transform: nil))
        context.fillPath()
        let dot = CGRect(x: badge.minX + 8, y: badge.midY - 2.5, width: 5, height: 5)
        context.setFillColor(accent.lighter(activity.isActive ? 0.32 : 0.1, alpha: 1).cgColor)
        if activity == .waiting {
            context.setStrokeColor(accent.lighter(0.2, alpha: 1).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: dot)
        } else {
            context.fillEllipse(in: dot)
        }
        label.draw(at: CGPoint(x: badge.minX + 20, y: badge.midY - textSize.height / 2), withAttributes: attributes)
        context.restoreGState()
    }
}
