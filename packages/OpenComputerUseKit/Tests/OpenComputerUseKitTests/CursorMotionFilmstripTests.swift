import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Offline cursor motion renderer and motion-quality checks.
///
/// `GODSPEED_CURSOR_FILMSTRIP=<dir>` writes one PNG per scenario (onion-skinned arrow frames at 60 Hz, the
/// path, and speed/angle charts) plus `metrics.json`, so motion changes can be judged by eye without
/// launching Godspeed. The simulation uses the overlay's own glide planner, lean and pose spring.
final class CursorMotionFilmstripTests: XCTestCase {
    struct Move {
        var to: CGPoint
        var queuedBehind = 0
        /// Moves the target by this much once the glide is this far through (a window dragged mid-flight).
        var retarget: (fraction: Double, by: CGVector)?
        var hold: Double = 0.1
    }

    struct Scenario {
        let name: String
        let start: CGPoint
        let moves: [Move]
        var displays: [CGRect] = [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
    }

    struct Frame {
        let time: Double
        let tip: CGPoint
        let velocity: CGVector
        let state: CursorVisualRenderState
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "01-long-right", start: CGPoint(x: 260, y: 500), moves: [Move(to: CGPoint(x: 1340, y: 500))]),
        Scenario(name: "02-long-left", start: CGPoint(x: 1340, y: 500), moves: [Move(to: CGPoint(x: 260, y: 500))]),
        Scenario(name: "03-down-right", start: CGPoint(x: 300, y: 880), moves: [Move(to: CGPoint(x: 1250, y: 160))]),
        Scenario(name: "04-up-left", start: CGPoint(x: 1250, y: 160), moves: [Move(to: CGPoint(x: 300, y: 880))]),
        Scenario(name: "05-up-right", start: CGPoint(x: 300, y: 160), moves: [Move(to: CGPoint(x: 1250, y: 880))]),
        Scenario(name: "06-down", start: CGPoint(x: 800, y: 900), moves: [Move(to: CGPoint(x: 800, y: 120))]),
        Scenario(name: "07-short-hops", start: CGPoint(x: 600, y: 500), moves: [
            Move(to: CGPoint(x: 690, y: 500)), Move(to: CGPoint(x: 760, y: 440)), Move(to: CGPoint(x: 900, y: 470)),
        ]),
        Scenario(name: "08-around-160px", start: CGPoint(x: 600, y: 500), moves: [
            Move(to: CGPoint(x: 755, y: 500)), Move(to: CGPoint(x: 600, y: 335)),
        ]),
        Scenario(name: "09-menu-bar", start: CGPoint(x: 900, y: 560), moves: [
            Move(to: CGPoint(x: 260, y: 988)), Move(to: CGPoint(x: 290, y: 900)),
        ]),
        Scenario(name: "10-click-chain", start: CGPoint(x: 300, y: 300), moves: [
            Move(to: CGPoint(x: 900, y: 700), hold: 0.09), Move(to: CGPoint(x: 1300, y: 420), hold: 0.09),
            Move(to: CGPoint(x: 700, y: 240), hold: 0.09),
        ]),
        Scenario(name: "11-retarget", start: CGPoint(x: 300, y: 600), moves: [
            Move(to: CGPoint(x: 1200, y: 600), retarget: (0.4, CGVector(dx: 0, dy: -220))),
        ]),
        Scenario(name: "12-queued-batch", start: CGPoint(x: 300, y: 500), moves: [
            Move(to: CGPoint(x: 700, y: 650), queuedBehind: 3, hold: 0.05), Move(to: CGPoint(x: 1100, y: 450), queuedBehind: 2, hold: 0.05),
            Move(to: CGPoint(x: 1300, y: 700), queuedBehind: 1, hold: 0.05),
        ]),
        Scenario(name: "13-two-displays", start: CGPoint(x: 700, y: 120), moves: [Move(to: CGPoint(x: 1500, y: 650))], displays: [
            CGRect(x: 0, y: 0, width: 900, height: 560), CGRect(x: 900, y: 300, width: 700, height: 700),
        ]),
    ]

    // MARK: - Simulation

    static func simulate(_ scenario: Scenario, fps: Double = 60) -> [Frame] {
        let base = visualCursorRenderBaseHeading()
        let config = CursorVisualDynamicsConfiguration.fast(speed: 1)
        let dt = 1 / fps
        var frames: [Frame] = []
        var pose = CursorPoseDynamics()
        var tip = scenario.start
        var velocity = CGVector.zero
        var time = 0.0
        func emit(_ point: CGPoint, _ v: CGVector, _ angle: CGFloat) {
            let state = pose.advance(tip: point, velocity: v, targetAngle: angle, idleAngleOffset: 0, dt: CGFloat(dt),
                                     baseHeading: base, configuration: config)
            frames.append(Frame(time: time, tip: point, velocity: v, state: state))
            tip = point
            velocity = v
            time += dt
        }
        emit(tip, .zero, 0)
        for move in scenario.moves {
            let displays = scenario.displays
            let target = move.to
            let startFrame = displays.first { $0.contains(tip) }
            let endFrame = displays.first { $0.contains(target) } ?? displays[0]
            let changesDisplay = startFrame != endFrame
            var route: CursorMotionPath?
            if changesDisplay, startFrame != nil,
               !CursorPathPlanner.isVisibleTrip(from: tip, to: target, displays: displays),
               let waypoints = CursorPathPlanner.route(from: tip, to: target, displays: displays) {
                route = CursorPathPlanner.through(waypoints, displays: displays)
            }
            var glide = visualCursorPlanGlide(
                from: tip, to: target, velocity: velocity, poseAngle: pose.angle, screenFrame: endFrame,
                dragging: false, changesDisplay: changesDisplay, route: route, at: time, speed: 1,
                queuedBehind: move.queuedBehind, fadesIn: false
            )
            var retargeted = move.retarget == nil
            while !glide.isFinished(at: time) {
                if !retargeted, let retarget = move.retarget, glide.timeFraction(at: time) >= CGFloat(retarget.fraction) {
                    retargeted = true
                    let moved = CGPoint(x: glide.end.x + retarget.by.dx, y: glide.end.y + retarget.by.dy)
                    glide = visualCursorRetargetGlide(glide, to: moved, at: time, poseAngle: pose.angle, speed: 1)
                }
                emit(glide.point(at: time), glide.velocity(at: time), visualCursorGlideTargetAngle(glide, at: time, baseHeading: base))
            }
            emit(glide.end, .zero, 0)
            let holdUntil = time + move.hold
            while time < holdUntil { emit(glide.end, .zero, 0) }
        }
        // Let the pose settle.
        for _ in 0..<Int(0.25 * fps) { emit(tip, .zero, 0) }
        return frames
    }

    struct Metrics: Codable {
        var name: String
        var frames: Int
        var travelMs: Int
        var peakSpeed: Double
        /// Largest speed change between two frames, as a fraction of the peak speed (a visible jolt).
        var worstSpeedJump: Double
        /// Largest change of direction between two consecutive moving frames, in degrees (a visible kink).
        var worstTurnDegrees: Double
        var maxLeanDegrees: Double
        /// How many times the lean target changes sign during a single move (wobble).
        var leanSignFlips: Int
        var leftDisplays: Bool
    }

    static func metrics(_ scenario: Scenario, _ frames: [Frame]) -> Metrics {
        let moving = frames.filter { hypot($0.velocity.dx, $0.velocity.dy) > 1 }
        let speeds = frames.map { hypot($0.velocity.dx, $0.velocity.dy) }
        let peak = speeds.max() ?? 0
        var jump = 0.0
        for i in 1..<speeds.count { jump = max(jump, Double(abs(speeds[i] - speeds[i - 1]))) }
        var turn = 0.0
        for i in 2..<frames.count {
            let a = CGVector(dx: frames[i - 1].tip.x - frames[i - 2].tip.x, dy: frames[i - 1].tip.y - frames[i - 2].tip.y)
            let b = CGVector(dx: frames[i].tip.x - frames[i - 1].tip.x, dy: frames[i].tip.y - frames[i - 1].tip.y)
            guard hypot(a.dx, a.dy) > 2, hypot(b.dx, b.dy) > 2 else { continue }
            let angle = abs(CursorPoseDynamics.normalize(atan2(b.dy, b.dx) - atan2(a.dy, a.dx)))
            turn = max(turn, Double(angle) * 180 / .pi)
        }
        var flips = 0
        var lastSign: CGFloat = 0
        for frame in frames {
            let r = frame.state.rotation
            guard abs(r) > 0.02 else { continue }
            let sign: CGFloat = r > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign { flips += 1 }
            lastSign = sign
        }
        let outside = frames.contains { frame in !scenario.displays.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(frame.tip) } }
        return Metrics(
            name: scenario.name, frames: frames.count, travelMs: Int(Double(moving.count) * 1000 / 60),
            peakSpeed: Double(peak), worstSpeedJump: peak > 0 ? jump / Double(peak) : 0, worstTurnDegrees: turn,
            maxLeanDegrees: Double(frames.map { abs($0.state.rotation) }.max() ?? 0) * 180 / .pi,
            leanSignFlips: flips, leftDisplays: outside
        )
    }

    // MARK: - Drawing

    static func render(_ scenario: Scenario, _ frames: [Frame], to url: URL) throws {
        let scale: CGFloat = 0.6
        let canvas = CGSize(width: 1600 * scale, height: 1000 * scale)
        let chartHeight: CGFloat = 260
        let size = CGSize(width: canvas.width, height: canvas.height + chartHeight)
        let pixels = 2
        guard let context = CGContext(
            data: nil, width: Int(size.width) * pixels, height: Int(size.height) * pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("no bitmap context") }
        context.scaleBy(x: CGFloat(pixels), y: CGFloat(pixels))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Background and displays (canvas sits above the charts).
        context.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: chartHeight + p.y * scale) }
        for display in scenario.displays {
            let rect = CGRect(x: display.minX * scale, y: chartHeight + display.minY * scale, width: display.width * scale, height: display.height * scale)
            context.setFillColor(NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.92, alpha: 1).cgColor)
            context.fill(rect.insetBy(dx: 1, dy: 1))
        }
        // Path.
        context.setStrokeColor(NSColor(calibratedRed: 0.2, green: 0.45, blue: 1, alpha: 0.55).cgColor)
        context.setLineWidth(1.2)
        context.beginPath()
        context.move(to: map(frames[0].tip))
        for frame in frames.dropFirst() { context.addLine(to: map(frame.tip)) }
        context.strokePath()
        // Frame dots (spacing shows speed).
        for frame in frames {
            let p = map(frame.tip)
            context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.3, blue: 0.2, alpha: 0.9).cgColor)
            context.fillEllipse(in: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2))
        }
        // Onion skin arrows: every second moving frame, plus rest frames at each landing.
        let windowSize = SoftwareCursorGlyphMetrics.windowSize
        let anchor = SoftwareCursorGlyphMetrics.tipAnchor
        var lastDrawn = -10
        for (index, frame) in frames.enumerated() {
            let moving = hypot(frame.velocity.dx, frame.velocity.dy) > 1
            guard moving ? index - lastDrawn >= 2 : index - lastDrawn >= 12 else { continue }
            lastDrawn = index
            let p = map(frame.tip)
            let rect = CGRect(x: p.x - anchor.x, y: p.y - anchor.y, width: windowSize.width, height: windowSize.height)
            context.saveGState()
            context.setAlpha(moving ? 0.55 : 1)
            SoftwareCursorGlyphRenderer.draw(in: rect, context: context, state: SoftwareCursorGlyphRenderState(
                rotation: frame.state.rotation, cursorBodyOffset: frame.state.cursorBodyOffset, fogOffset: frame.state.fogOffset,
                fogOpacity: frame.state.fogOpacity, fogScale: frame.state.fogScale, clickProgress: 0
            ))
            context.restoreGState()
        }

        // Charts: speed (blue) and lean angle (orange) against time.
        let plot = CGRect(x: 40, y: 24, width: size.width - 60, height: chartHeight - 48)
        context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1).cgColor)
        context.fill(plot)
        let duration = max(frames.last?.time ?? 1, 0.001)
        let peak = max(frames.map { hypot($0.velocity.dx, $0.velocity.dy) }.max() ?? 1, 1)
        func series(_ value: (Frame) -> CGFloat, color: NSColor, range: ClosedRange<CGFloat>) {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.5)
            context.beginPath()
            for (i, frame) in frames.enumerated() {
                let x = plot.minX + CGFloat(frame.time / duration) * plot.width
                let v = (value(frame) - range.lowerBound) / (range.upperBound - range.lowerBound)
                let point = CGPoint(x: x, y: plot.minY + v.clamped(to: 0...1) * plot.height)
                if i == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        }
        context.setStrokeColor(NSColor(calibratedWhite: 0.3, alpha: 1).cgColor)
        context.setLineWidth(0.5)
        context.stroke(CGRect(x: plot.minX, y: plot.midY, width: plot.width, height: 0))
        series({ hypot($0.velocity.dx, $0.velocity.dy) / peak * 0.5 + 0.5 }, color: NSColor(calibratedRed: 0.35, green: 0.6, blue: 1, alpha: 1), range: 0...1)
        series({ $0.state.rotation }, color: NSColor(calibratedRed: 1, green: 0.6, blue: 0.2, alpha: 1), range: -0.6...0.6)
        let label = "\(scenario.name)   peak \(Int(peak)) pt/s   \(Int(duration * 1000)) ms shown   blue: speed   orange: lean"
        NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
        ]).draw(at: CGPoint(x: 40, y: 4))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("no image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testWriteFilmstrips() throws {
        guard let dir = ProcessInfo.processInfo.environment["GODSPEED_CURSOR_FILMSTRIP"] else { throw XCTSkip("filmstrips only") }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var all: [Metrics] = []
        for scenario in Self.scenarios {
            let frames = Self.simulate(scenario)
            try Self.render(scenario, frames, to: folder.appendingPathComponent("\(scenario.name).png"))
            all.append(Self.metrics(scenario, frames))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: folder.appendingPathComponent("metrics.json"))
    }

    // MARK: - Video

    /// One frame of the demo: where the tip is, its pose, and the click press/ripple.
    struct VideoFrame {
        let tip: CGPoint
        let state: CursorVisualRenderState
        let press: CGFloat
        let ripple: CursorClickRipple?
    }

    /// A short tour of a desktop: toolbar, sidebar, a field, the menu bar, a far button. Each stop clicks, then
    /// the arrow rests a moment with its idle breathing, as the overlay does.
    static func tourFrames(fps: Double = 60) -> [VideoFrame] {
        let base = visualCursorRenderBaseHeading()
        let config = CursorVisualDynamicsConfiguration.fast(speed: 1)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let stops: [CGPoint] = [
            CGPoint(x: 330, y: 700), CGPoint(x: 1150, y: 790), CGPoint(x: 700, y: 520), CGPoint(x: 760, y: 470),
            CGPoint(x: 120, y: 886), CGPoint(x: 1240, y: 150), CGPoint(x: 330, y: 640), CGPoint(x: 410, y: 160),
        ]
        let dt = 1 / fps
        var frames: [VideoFrame] = []
        var pose = CursorPoseDynamics()
        var tip = CGPoint(x: 720, y: 450)
        var time = 0.0
        func emit(_ point: CGPoint, _ v: CGVector, _ angle: CGFloat, press: CGFloat = 0, ripple: CursorClickRipple? = nil) {
            let state = pose.advance(tip: point, velocity: v, targetAngle: angle, idleAngleOffset: 0, dt: CGFloat(dt),
                                     baseHeading: base, configuration: config)
            frames.append(VideoFrame(tip: point, state: state, press: press, ripple: ripple))
            tip = point
            time += dt
        }
        for _ in 0..<Int(0.4 * fps) { emit(tip, .zero, 0) }
        for stop in stops {
            let glide = visualCursorPlanGlide(
                from: tip, to: stop, velocity: .zero, poseAngle: pose.angle, screenFrame: screen, dragging: false,
                changesDisplay: false, route: nil, at: time, speed: 1, queuedBehind: 0, fadesIn: false
            )
            while !glide.isFinished(at: time) {
                emit(glide.point(at: time), glide.velocity(at: time), visualCursorGlideTargetAngle(glide, at: time, baseHeading: base))
            }
            // Click: quick press, softer release, ripple (as ActivePulse samples it).
            let pulseStart = time
            while time - pulseStart < 0.15 {
                let raw = CGFloat((time - pulseStart) / 0.15)
                let attack = min(raw / 0.24, 1), release = max((1 - raw) / 0.76, 0)
                let press = min(attack * attack * (3 - 2 * attack), release * release * (3 - 2 * release))
                emit(stop, .zero, 0, press: press, ripple: CursorClickRipple(progress: raw, strength: 1, reducesMotion: false))
            }
            // Rest with the idle breathing.
            let restStart = time
            while time - restStart < 0.45 {
                let t = CGFloat(time - restStart)
                let fade = min(1, t / 0.6)
                emit(stop, .zero, sin(t * visualCursorIdleRotationRate()) * visualCursorIdleRotationAmplitude() * fade * fade)
            }
        }
        return frames
    }

    func testWriteTourVideoFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["GODSPEED_CURSOR_VIDEO"] else { throw XCTSkip("video only") }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frames = Self.tourFrames()
        let scale: CGFloat = 1.3333
        let size = CGSize(width: 1440, height: 900)
        let windowSize = SoftwareCursorGlyphMetrics.windowSize
        let anchor = SoftwareCursorGlyphMetrics.tipAnchor
        for (index, frame) in frames.enumerated() {
            guard let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw XCTSkip("no bitmap context") }
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            // Desktop, a window with a sidebar, toolbar buttons, a field and the menu bar.
            context.setFillColor(NSColor(calibratedRed: 0.30, green: 0.38, blue: 0.52, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 0.92).cgColor)
            context.fill(CGRect(x: 0, y: 872, width: 1440, height: 28))
            let window = CGRect(x: 90, y: 80, width: 1260, height: 760)
            context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
            context.addPath(CGPath(roundedRect: window, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.fillPath()
            context.setFillColor(NSColor(calibratedWhite: 0.92, alpha: 1).cgColor)
            context.fill(CGRect(x: window.minX, y: window.minY, width: 300, height: window.height - 52))
            context.fill(CGRect(x: window.minX, y: window.maxY - 52, width: window.width, height: 52))
            context.setFillColor(NSColor(calibratedWhite: 0.85, alpha: 1).cgColor)
            for row in 0..<9 { context.fill(CGRect(x: 120, y: 160 + CGFloat(row) * 60, width: 240, height: 30)) }
            context.fill(CGRect(x: 1110, y: 775, width: 80, height: 30))
            context.fill(CGRect(x: 500, y: 500, width: 520, height: 40))
            context.fill(CGRect(x: 1180, y: 130, width: 130, height: 40))
            let p = frame.tip
            let rect = CGRect(x: p.x - anchor.x, y: p.y - anchor.y, width: windowSize.width, height: windowSize.height)
            SoftwareCursorGlyphRenderer.draw(in: rect, context: context, state: SoftwareCursorGlyphRenderState(
                rotation: frame.state.rotation, cursorBodyOffset: frame.state.cursorBodyOffset, fogOffset: frame.state.fogOffset,
                fogOpacity: frame.state.fogOpacity, fogScale: frame.state.fogScale, clickProgress: frame.press
            ), ripple: frame.ripple)
            // The name tag, placed as the overlay places it (same frame function, same style).
            let name = NSAttributedString(string: "Claude", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
            ])
            let panelOrigin = CGPoint(x: p.x - SoftwareCursorPanelMetrics.tipAnchor.x, y: p.y - SoftwareCursorPanelMetrics.tipAnchor.y)
            let panelBounds = CGRect(origin: .zero, size: SoftwareCursorPanelMetrics.size)
            let viewport = panelBounds.insetBy(dx: 4, dy: 0)
                .intersection(CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2).offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y))
            let tag = visualCursorNameTagFrame(width: ceil(name.size().width) + 14, height: 19, available: viewport)
                .offsetBy(dx: panelOrigin.x, dy: panelOrigin.y)
            let pill = NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5)
            NSColor(white: 0.085, alpha: 0.93).setFill()
            pill.fill()
            NSColor(white: 1, alpha: 0.24).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            name.draw(in: tag.insetBy(dx: 7, dy: 2))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(
                    folder.appendingPathComponent(String(format: "frame_%04d.png", index)) as CFURL, "public.png" as CFString, 1, nil
                  ) else { throw XCTSkip("no image") }
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
}
