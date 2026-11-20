import AppKit
import CoreGraphics
import Foundation

struct SoftwareCursorGlyphRenderState {
    let rotation: CGFloat
    let cursorBodyOffset: CGVector
    let fogOffset: CGVector
    let fogOpacity: CGFloat
    let fogScale: CGFloat
    let clickProgress: CGFloat

    init(
        rotation: CGFloat,
        cursorBodyOffset: CGVector,
        fogOffset: CGVector,
        fogOpacity: CGFloat,
        fogScale: CGFloat,
        clickProgress: CGFloat
    ) {
        self.rotation = rotation
        self.cursorBodyOffset = cursorBodyOffset
        self.fogOffset = fogOffset
        self.fogOpacity = fogOpacity
        self.fogScale = fogScale
        self.clickProgress = clickProgress
    }

    var appKitDrawingState: SoftwareCursorGlyphRenderState {
        SoftwareCursorGlyphRenderState(
            rotation: -rotation,
            cursorBodyOffset: CGVector(dx: cursorBodyOffset.dx, dy: -cursorBodyOffset.dy),
            fogOffset: CGVector(dx: fogOffset.dx, dy: -fogOffset.dy),
            fogOpacity: fogOpacity,
            fogScale: fogScale,
            clickProgress: clickProgress
        )
    }
}

enum CursorInteractionFeedback: Equatable {
    case drag
    case typing
    case scroll(CGVector)

    var phase: String {
        switch self {
        case .drag: "dragging"
        case .typing: "typing"
        case .scroll: "scrolling"
        }
    }

    var completionDuration: TimeInterval {
        switch self {
        case .drag: 0.16
        case .typing, .scroll: 0.22
        }
    }

    /// An AppKit unit vector for the direction of the scroll. Input deltas use screen coordinates.
    var scrollDirection: CGVector? {
        guard case let .scroll(delta) = self else { return nil }
        let length = hypot(delta.dx, delta.dy)
        guard length.isFinite, length > 0 else { return nil }
        return CGVector(dx: delta.dx / length, dy: -delta.dy / length)
    }
}

struct CursorInteractionIndicator: Equatable {
    let feedback: CursorInteractionFeedback
    var isCompleted = false

    var phase: String {
        if feedback == .drag, isCompleted { return "dropped" }
        return feedback.phase
    }
}

/// Frame values for a click ripple centered on the actual pointer tip.
struct CursorClickRipple {
    let radius: CGFloat
    let opacity: CGFloat
    let isSecondary: Bool

    init(progress: CGFloat, strength: CGFloat, reducesMotion: Bool, isSecondary: Bool = false) {
        let time = min(max(progress, 0), 1)
        let fade = 1 - time
        radius = reducesMotion ? 8 : 5 + 11 * (1 - fade * fade)
        opacity = 0.8 * strength * fade * fade
        self.isSecondary = isSecondary
    }
}

enum SoftwareCursorGlyphMetrics {
    static let windowSize = CGSize(width: 126, height: 126)
    static let tipAnchor = CGPoint(x: 60.35, y: 70.3)
    static let referenceImageResourceName = "official-software-cursor-window-252"

    static let pointerSize = CGSize(width: 21, height: 21)
    static let pointerOffset = CGPoint(x: 2.6, y: -3.2)
    static let targetNeutralHeading = -(3 * CGFloat.pi / 4)

    /// Screen-space (y down) heading the fallback contour must be authored at so that
    /// `pointerArtworkRotation` lands its apex on `targetNeutralHeading`.
    ///
    /// The previous -96.5 deg made the fallback point straight down (+132 deg measured) while the
    /// reference artwork rests facing upper-left, so users who run the CLI without the bundled
    /// `Resources` (every non-app build) saw a pointer rotated ~135 deg away from the cursor.
    static let proceduralContourNeutralHeading = -(CGFloat.pi / 4)
    static let pointerArtworkRotation = targetNeutralHeading - proceduralContourNeutralHeading
}

/// The cursor window: the 126 pt glyph art in the middle, with room on both sides for the name tag, which sits
/// beside the arrow (to its right, or to its left next to the right edge of a display).
enum SoftwareCursorPanelMetrics {
    static let sideRoom: CGFloat = 132
    static let glyphRect = CGRect(origin: CGPoint(x: sideRoom, y: 0), size: SoftwareCursorGlyphMetrics.windowSize)
    static let size = CGSize(width: SoftwareCursorGlyphMetrics.windowSize.width + 2 * sideRoom,
                             height: SoftwareCursorGlyphMetrics.windowSize.height)
    static let tipAnchor = CGPoint(x: SoftwareCursorGlyphMetrics.tipAnchor.x + sideRoom, y: SoftwareCursorGlyphMetrics.tipAnchor.y)
}

/// A cursor colour chosen in PURE (Settings > GODSPEED), as "#RRGGBB".
struct CursorColor: Equatable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = CGFloat((value >> 16) & 0xFF) / 255
        green = CGFloat((value >> 8) & 0xFF) / 255
        blue = CGFloat(value & 0xFF) / 255
    }

    /// The same hue moved toward white by `amount` (0...1), for the softer outer glow stops.
    func lighter(_ amount: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(calibratedRed: red + (1 - red) * amount, green: green + (1 - green) * amount,
                 blue: blue + (1 - blue) * amount, alpha: alpha)
    }
}

private enum SoftwareCursorGlyphColors {
    /// Dark graphite, used when no colour is chosen.
    static let defaultBase = (red: CGFloat(0.105), green: CGFloat(0.11), blue: CGFloat(0.125))
    /// The cool blue the default cursor glows in.
    static let defaultGlow = "#5E5C60"

    /// The body's lighter top edge, so the fill reads as a soft sheen rather than a flat shape.
    static func sheen(_ tint: CursorColor?) -> NSColor {
        let base = tint ?? CursorColor(hex: "#1B1C20")!
        return base.lighter(0.20, alpha: 0.98)
    }

    static func fill(_ tint: CursorColor?) -> NSColor {
        guard let tint else {
            return NSColor(calibratedRed: defaultBase.red, green: defaultBase.green, blue: defaultBase.blue, alpha: 0.98)
        }
        return NSColor(calibratedRed: tint.red, green: tint.green, blue: tint.blue, alpha: 0.98)
    }

    static func glow(_ tint: CursorColor?, lighter amount: CGFloat, alpha: CGFloat) -> CGColor {
        let base = tint ?? CursorColor(hex: defaultGlow)!
        return base.lighter(amount, alpha: alpha).cgColor
    }

    static let pointerStroke = NSColor(calibratedWhite: 0.98, alpha: 0.96)
}

enum SoftwareCursorGlyphRenderer {
    nonisolated(unsafe) private static let referenceImage = loadReferenceCursorWindowImage()
    /// The chosen cursor colour (set from the request's cursor settings). With a colour, the cursor is
    /// drawn procedurally in that colour; without one, the original artwork is used.
    nonisolated(unsafe) static var tint: CursorColor?
    /// A recent picture of the screen under the cursor window and where it sits in the view, for the lens.
    nonisolated(unsafe) static var backdrop: (image: CGImage, rect: CGRect)?
    // The falloff curve stays the same as the cursor moves. Keep only the current tint's gradient.
    nonisolated(unsafe) private static var cachedFog: (tint: CursorColor?, gradient: CGGradient)?
    /// How much the glass enlarges what is under it.
    static let magnification: CGFloat = 1.4
    /// OPEN_COMPUTER_USE_CURSOR_STYLE=classic brings back the original grey artwork.
    private static let usesClassicArtwork =
        (ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_CURSOR_STYLE"] ?? "").lowercased() == "classic"

    static func draw(
        in bounds: CGRect,
        context: CGContext,
        state: SoftwareCursorGlyphRenderState,
        usesReferenceArtwork: Bool = true,
        ripple: CursorClickRipple? = nil,
        indicator: CursorInteractionIndicator? = nil
    ) {
        let drawingState = state.appKitDrawingState
        if let ripple, ripple.opacity > 0 {
            drawClickRipple(ripple, in: bounds, context: context)
        }

        if let referenceImage, usesReferenceArtwork, tint == nil, usesClassicArtwork {
            drawReferenceImage(
                referenceImage,
                in: bounds,
                context: context,
                state: drawingState
            )
        } else {
            drawFog(
                in: context,
                center: CGPoint(x: bounds.midX + drawingState.fogOffset.dx, y: bounds.midY + drawingState.fogOffset.dy),
                pulse: drawingState.clickProgress,
                fogOpacity: state.fogOpacity,
                fogScale: state.fogScale
            )
            drawSmoothPointer(in: bounds, context: context, state: drawingState)
        }
        if let indicator {
            drawInteractionIndicator(indicator, in: bounds, context: context)
        }
    }

    private static func drawInteractionIndicator(_ indicator: CursorInteractionIndicator, in bounds: CGRect, context: CGContext) {
        let unit = bounds.width / SoftwareCursorGlyphMetrics.windowSize.width
        let tip = SoftwareCursorGlyphMetrics.tipAnchor
        let path = CGMutablePath()
        switch indicator.feedback {
        case .drag:
            path.addEllipse(in: CGRect(x: -6, y: -6, width: 12, height: 12))
        case .typing:
            // An I-beam beside the point leaves the target visible.
            path.move(to: CGPoint(x: -12, y: 3))
            path.addLine(to: CGPoint(x: -12, y: 13))
            path.move(to: CGPoint(x: -15, y: 3))
            path.addLine(to: CGPoint(x: -9, y: 3))
            path.move(to: CGPoint(x: -15, y: 13))
            path.addLine(to: CGPoint(x: -9, y: 13))
        case .scroll:
            guard let direction = indicator.feedback.scrollDirection else { return }
            // Place the chevron beside the pointer and aim it along the scroll delta.
            let center = CGPoint(x: -13, y: 9)
            func point(along: CGFloat, across: CGFloat) -> CGPoint {
                CGPoint(
                    x: center.x + along * direction.dx - across * direction.dy,
                    y: center.y + along * direction.dy + across * direction.dx
                )
            }
            path.move(to: point(along: -2, across: -4))
            path.addLine(to: point(along: 2, across: 0))
            path.addLine(to: point(along: -2, across: 4))
        }

        context.saveGState()
        context.translateBy(x: bounds.minX + tip.x * unit, y: bounds.minY + tip.y * unit)
        context.scaleBy(x: unit, y: unit)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if indicator.feedback == .drag, !indicator.isCompleted {
            context.setLineDash(phase: 0, lengths: [4, 2.3])
        }
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(3.2)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor((tint?.lighter(0.8, alpha: 1) ?? .white).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawClickRipple(_ ripple: CursorClickRipple, in bounds: CGRect, context: CGContext) {
        let unit = bounds.width / SoftwareCursorGlyphMetrics.windowSize.width
        let center = CGPoint(
            x: bounds.minX + SoftwareCursorGlyphMetrics.tipAnchor.x * unit,
            y: bounds.minY + SoftwareCursorGlyphMetrics.tipAnchor.y * unit
        )
        let radius = ripple.radius * unit
        let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        if ripple.isSecondary {
            context.setLineDash(phase: 0, lengths: [2.5 * unit, 2.5 * unit])
        }
        context.setStrokeColor(NSColor.black.withAlphaComponent(ripple.opacity * 0.6).cgColor)
        context.setLineWidth(3 * unit)
        context.strokeEllipse(in: ring)
        context.setStrokeColor((tint?.lighter(0.75, alpha: ripple.opacity) ?? .white.withAlphaComponent(ripple.opacity)).cgColor)
        context.setLineWidth(1.4 * unit)
        context.strokeEllipse(in: ring)
        context.restoreGState()
    }

    /// The pointer as a smooth outline matching the original artwork's shape and size: a rounded dart with a
    /// small notch, dark with a soft sheen, a crisp white edge and a drop shadow.
    private static func drawSmoothPointer(in bounds: CGRect, context: CGContext, state: SoftwareCursorGlyphRenderState) {
        let unit = bounds.width / 126
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: bounds.minX + x * unit, y: bounds.minY + y * unit) }
        let tip = point(56.6, 68.4), wing = point(74.0, 62.6), notch = point(67.0, 59.3), tail = point(64.1, 51.4)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: (tip.x + wing.x) / 2, y: (tip.y + wing.y) / 2))
        path.appendArc(from: wing, to: notch, radius: 1.5 * unit)
        path.appendArc(from: notch, to: tail, radius: 1.6 * unit)
        path.appendArc(from: tail, to: tip, radius: 1.5 * unit)
        path.appendArc(from: tip, to: wing, radius: 1.3 * unit)
        path.close()
        path.lineJoinStyle = .round

        let motionCompression = min(hypot(state.cursorBodyOffset.dx, state.cursorBodyOffset.dy) * 0.008, 0.018)
        let pulseCompression = state.clickProgress * 0.03
        let baseTransform = context.ctm
        context.saveGState()
        context.translateBy(x: bounds.midX + state.cursorBodyOffset.dx, y: bounds.midY + state.cursorBodyOffset.dy)
        context.rotate(by: state.rotation)
        context.scaleBy(x: 1 - motionCompression - pulseCompression, y: 1 + (pulseCompression * 0.4))
        context.translateBy(x: -bounds.midX, y: -bounds.midY)

        // Clear liquid glass: nothing grey inside, what is under it shows through slightly magnified, a light
        // caught at the tip, a faint colour split along the edge and a bright rim.
        let space = CGColorSpaceCreateDeviceRGB()
        let box = path.bounds
        let cg = path.cgPath
        let lit = CGPoint(x: box.minX, y: box.maxY), far = CGPoint(x: box.maxX, y: box.minY)
        func white(_ alpha: CGFloat) -> CGColor { NSColor(calibratedWhite: 1, alpha: alpha).cgColor }

        // A soft shadow around the glass only, so the inside stays clear.
        context.saveGState()
        context.addRect(box.insetBy(dx: -30 * unit, dy: -30 * unit))
        context.addPath(cg)
        context.clip(using: .evenOdd)
        context.setShadow(offset: CGSize(width: 0, height: -1.6 * unit), blur: (5.5 + state.clickProgress * 1.6) * unit,
                          color: NSColor.black.withAlphaComponent(0.40).cgColor)
        context.addPath(cg)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(cg)
        context.clip()
        // The lens: the screen under the cursor, drawn a little larger. Skipped when no fresh picture of it exists
        // (the window is see-through, so the real screen simply shows unmagnified).
        if let backdrop {
            let glassCenter = CGPoint(x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2).applying(context.ctm).applying(baseTransform.inverted())
            context.saveGState()
            context.concatenate(context.ctm.inverted())
            context.concatenate(baseTransform)
            context.translateBy(x: glassCenter.x, y: glassCenter.y)
            context.scaleBy(x: Self.magnification, y: Self.magnification)
            context.translateBy(x: -glassCenter.x + 0.8 * unit, y: -glassCenter.y - 0.8 * unit)
            context.interpolationQuality = .high
            context.draw(backdrop.image, in: backdrop.rect)
            context.restoreGState()
        }
        let tintTop = tint?.lighter(0.6, alpha: 0.22).cgColor ?? white(0.10)
        let tintBottom = tint?.lighter(0.2, alpha: 0.10).cgColor ?? white(0)
        if let body = CGGradient(colorsSpace: space, colors: [tintTop, tintBottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(body, start: lit, end: far, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if let shine = CGGradient(colorsSpace: space, colors: [white(0.50), white(0.10), white(0)] as CFArray, locations: [0, 0.45, 1]) {
            let at = CGPoint(x: box.minX + box.width * 0.22, y: box.maxY - box.height * 0.14)
            context.drawRadialGradient(shine, startCenter: at, startRadius: 0, endCenter: at, endRadius: box.width * 0.6, options: [])
        }
        if let pool = CGGradient(colorsSpace: space, colors: [
            NSColor(calibratedRed: 0.85, green: 0.93, blue: 1, alpha: 0.22).cgColor, white(0),
        ] as CFArray, locations: [0, 1]) {
            let at = CGPoint(x: box.minX + box.width * 0.60, y: box.minY + box.height * 0.32)
            context.drawRadialGradient(pool, startCenter: at, startRadius: 0, endCenter: at, endRadius: box.width * 0.32, options: [])
        }
        // Thickness: a light inner edge, and a faint darker one beside it.
        context.setLineJoin(.round)
        context.addPath(cg)
        context.setStrokeColor(white(0.18))
        context.setLineWidth(2.2 * unit)
        context.strokePath()
        context.translateBy(x: -0.9 * unit, y: 0.9 * unit)
        context.addPath(cg)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(1.2 * unit)
        context.strokePath()
        context.restoreGState()

        // The colour split at the edge.
        for (dx, dy, color) in [
            (0.5, -0.5, NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.36, alpha: 0.27)),
            (-0.5, 0.5, NSColor(calibratedRed: 0.36, green: 0.72, blue: 1.0, alpha: 0.29)),
            (0.5, 0.5, NSColor(calibratedRed: 0.72, green: 0.50, blue: 1.0, alpha: 0.15)),
        ] {
            context.saveGState()
            context.translateBy(x: CGFloat(dx) * unit, y: CGFloat(dy) * unit)
            context.addPath(cg)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.0 * unit)
            context.setLineJoin(.round)
            context.strokePath()
            context.restoreGState()
        }
        // The rim: brightest toward the light.
        context.saveGState()
        context.addPath(cg.copy(strokingWithWidth: 1.15 * unit, lineCap: .round, lineJoin: .round, miterLimit: 4))
        context.clip()
        if let rim = CGGradient(colorsSpace: space, colors: [white(1), white(0.92), white(0.85)] as CFArray, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(rim, start: lit, end: far, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
        context.restoreGState()
    }

    private static func drawReferenceImage(
        _ image: NSImage,
        in bounds: CGRect,
        context: CGContext,
        state: SoftwareCursorGlyphRenderState
    ) {
        let motionCompression = min(hypot(state.cursorBodyOffset.dx, state.cursorBodyOffset.dy) * 0.008, 0.018)
        let pulseCompression = state.clickProgress * 0.03

        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(
            x: bounds.midX + state.cursorBodyOffset.dx,
            y: bounds.midY + state.cursorBodyOffset.dy
        )
        context.rotate(by: state.rotation)
        context.scaleBy(
            x: 1 - motionCompression - pulseCompression,
            y: 1 + (pulseCompression * 0.4)
        )
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }

    private static func drawFog(
        in context: CGContext,
        center: CGPoint,
        pulse: CGFloat,
        fogOpacity: CGFloat,
        fogScale: CGFloat
    ) {
        // A white halo that fades like a soft light: a bell curve, so there is no ring or flat patch in it.
        let radius = (22 * fogScale) + (pulse * 3)
        let peak = min(0.55 * max(0.5, min(fogOpacity / 0.12, 1.5)) + pulse * 0.2, 0.9)
        guard let gradient = fogGradient() else { return }
        context.saveGState()
        context.setAlpha(peak)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        context.restoreGState()
    }

    private static func fogGradient() -> CGGradient? {
        if let cachedFog, cachedFog.tint == tint { return cachedFog.gradient }
        let base = tint?.lighter(0.55, alpha: 1) ?? NSColor.white
        let falloff: CGFloat = 4.2
        let floor = exp(-falloff)
        let locations = (0...24).map { CGFloat($0) / 24 }
        let colors = locations.map { t in
            base.withAlphaComponent((exp(-falloff * t * t) - floor) / (1 - floor)).cgColor
        }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else { return nil }
        cachedFog = (tint, gradient)
        return gradient
    }

    private static func drawPointer(
        in context: CGContext,
        center: CGPoint,
        rotation: CGFloat,
        clickProgress: CGFloat,
        cursorBodyOffset: CGVector,
        boundsMidpoint: CGPoint
    ) {
        let pointerRect = CGRect(
            x: center.x - (SoftwareCursorGlyphMetrics.pointerSize.width / 2),
            y: center.y - (SoftwareCursorGlyphMetrics.pointerSize.height / 2),
            width: SoftwareCursorGlyphMetrics.pointerSize.width,
            height: SoftwareCursorGlyphMetrics.pointerSize.height
        )
        let outerPath = pointerPath(in: pointerRect)

        context.saveGState()
        context.translateBy(
            x: boundsMidpoint.x + cursorBodyOffset.dx,
            y: boundsMidpoint.y + cursorBodyOffset.dy
        )
        context.rotate(by: rotation)
        context.scaleBy(x: 1 - (clickProgress * 0.04), y: 1 + (clickProgress * 0.02))
        context.translateBy(
            x: -(boundsMidpoint.x + cursorBodyOffset.dx),
            y: -(boundsMidpoint.y + cursorBodyOffset.dy)
        )
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: SoftwareCursorGlyphMetrics.pointerArtworkRotation)
        context.translateBy(x: -center.x, y: -center.y)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4.5 + (clickProgress * 1.6)
        shadow.shadowOffset = CGSize(width: 0, height: -1.0)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
        shadow.set()
        NSColor.black.withAlphaComponent(0.20).setFill()
        outerPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        if let gradient = NSGradient(starting: SoftwareCursorGlyphColors.sheen(tint), ending: SoftwareCursorGlyphColors.fill(tint)) {
            gradient.draw(in: outerPath, angle: -90)
        } else {
            SoftwareCursorGlyphColors.fill(tint).setFill()
            outerPath.fill()
        }

        SoftwareCursorGlyphColors.pointerStroke.setStroke()
        outerPath.lineWidth = 1.45
        outerPath.lineJoinStyle = .round
        outerPath.lineCapStyle = .round
        outerPath.stroke()

        context.restoreGState()
    }

    private static func pointerPath(in rect: CGRect) -> NSBezierPath {
        let contourRows: [(y: CGFloat, minX: CGFloat, maxX: CGFloat)] = [
            (39, 17, 21), (38, 16, 22), (37, 15, 22), (36, 15, 23), (35, 15, 24),
            (34, 15, 24), (33, 14, 25), (32, 14, 25), (31, 14, 26), (30, 14, 27),
            (29, 13, 29), (28, 13, 31), (27, 13, 34), (26, 13, 36), (25, 13, 37),
            (24, 12, 37), (23, 12, 37), (22, 12, 37), (21, 12, 37), (20, 12, 36),
            (19, 11, 36), (18, 11, 34), (17, 11, 32), (16, 11, 30), (15, 10, 27),
            (14, 10, 25), (13, 10, 23), (12, 11, 21), (11, 11, 19), (10, 13, 16),
        ]
        let sourceMinX: CGFloat = 10
        let sourceMaxX: CGFloat = 38
        let sourceMinY: CGFloat = 10
        let sourceMaxY: CGFloat = 39

        func mappedPoint(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + ((x - sourceMinX) / (sourceMaxX - sourceMinX) * rect.width),
                y: rect.minY + ((y - sourceMinY) / (sourceMaxY - sourceMinY) * rect.height)
            )
        }

        let leftBoundary = contourRows.map { mappedPoint(x: $0.minX, y: $0.y) }
        let rightBoundary = contourRows.reversed().map { mappedPoint(x: $0.maxX, y: $0.y) }

        let path = NSBezierPath()
        path.move(to: leftBoundary[0])
        leftBoundary.dropFirst().forEach { path.line(to: $0) }
        rightBoundary.forEach { path.line(to: $0) }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}

func loadReferenceCursorWindowImage() -> NSImage? {
    if let bundledReference = Bundle.main.url(
        forResource: SoftwareCursorGlyphMetrics.referenceImageResourceName,
        withExtension: "png"
    ), let image = NSImage(contentsOf: bundledReference) {
        return image
    }

    let fileURL = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repoRoot = fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let referenceURL = repoRoot
        .appendingPathComponent("docs/references/codex-computer-use-reverse-engineering/assets/extracted-2026-04-19/\(SoftwareCursorGlyphMetrics.referenceImageResourceName).png")

    return NSImage(contentsOf: referenceURL)
}
