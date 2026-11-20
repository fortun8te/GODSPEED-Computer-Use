import AppKit
import CoreGraphics
import Foundation
import QuartzCore

public enum VisualCursorSupport {
    /// Set by short-lived one-shot processes (the CLI `call` command). The process
    /// exits before a queued animation can finish, so the glyph only flickered at
    /// stale positions (the screen corner it started from) and never reached the
    /// target. Long-lived MCP servers keep the cursor.
    nonisolated(unsafe) public static var shortLivedProcess = false

    private static let settingsSnapshotKey = "com.michael.ocufast.cursor.settings-snapshot"
    private static let cursorClientKey = "com.michael.ocufast.cursor.client"

    /// The agent whose cursor the running animation drives. Queued animations run on the main thread, outside
    /// the request's `ClientScope`, so the client is captured when the animation is queued.
    static var cursorClient: String {
        (Thread.current.threadDictionary[cursorClientKey] as? String) ?? ClientScope.current
    }

    public static var isEnabled: Bool { settings.enabled }

    /// Every cursor setting for the current request. The app agent applies a caller's
    /// OPEN_COMPUTER_USE_* variables only while that request runs, and queued animations
    /// play after it returned, so they must use the values captured when they were queued.
    static var settings: VisualCursorSettings {
        if let snapshot = Thread.current.threadDictionary[settingsSnapshotKey] as? VisualCursorSettings {
            return snapshot
        }
        // PURE's Settings > GODSPEED fill in whatever the environment does not set.
        let environment = GodspeedSettings.merged(ProcessInfo.processInfo.environment)
        var settings = VisualCursorSettings(environment: environment)
        let client = ClientScope.current
        if environment["OPEN_COMPUTER_USE_CURSOR_COLOR"]?.lowercased() == "auto", client != "main" {
            let palette = ["#5C9CFA", "#C77BF2", "#35BA9A", "#F19A5B", "#E876A4", "#8CA965"]
            let index = client.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
            settings.color = CursorColor(hex: palette[index])
        }
        if shortLivedProcess {
            settings.enabled = false
        }
        return settings
    }

    /// OPEN_COMPUTER_USE_CURSOR_ASYNC (default on): cursor animations are queued on the main thread
    /// and play while the action runs, so the action never waits for them. Order is kept (move, then pulse).
    static var animatesAsync: Bool {
        let raw = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_CURSOR_ASYNC"]?.lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(raw)
    }

    private static let backlogLock = NSLock()
    nonisolated(unsafe) private static var backlog = 0
    /// What a queued cursor animation is. Moves can be skipped when a later move is queued; see the drain loop.
    enum AnimationKind { case move, other }

    @MainActor private static var pendingAnimations: [(kind: AnimationKind, client: String, body: @MainActor () -> Void)] = []
    @MainActor private static var isDrainingAnimations = false
    /// A reset asked for by another process or a finished turn while animations play. Resetting then aborted
    /// the glide and the cursor vanished mid-batch, so it waits until the queue is empty.
    @MainActor static var deferredReset = false
    @MainActor static var isDraining: Bool { isDrainingAnimations || !pendingAnimations.isEmpty }
    @MainActor static var isAnimating: Bool {
        isDrainingAnimations || !pendingAnimations.isEmpty || SoftwareCursorOverlay.isBusy
    }

    /// Animations still waiting to start. A move that has others queued behind it plays faster, so the
    /// cursor keeps up with a fast batch instead of replaying it for seconds afterwards.
    static var queuedAnimations: Int {
        backlogLock.lock(); defer { backlogLock.unlock() }
        return backlog
    }

    static func performCursorAnimation(kind: AnimationKind = .other, _ body: @escaping @MainActor () -> Void) {
        // The app agent temporarily overrides its environment per request. The
        // main queue can run after those overrides are restored, so capture the
        // request's cursor setting before dispatching any work.
        let captured = settings
        let client = ClientScope.current
        let perform: @MainActor () -> Void = {
            let dictionary = Thread.current.threadDictionary
            let previous = dictionary[settingsSnapshotKey]
            let previousClient = dictionary[cursorClientKey]
            dictionary[settingsSnapshotKey] = captured
            dictionary[cursorClientKey] = client
            defer {
                if let previous { dictionary[settingsSnapshotKey] = previous }
                else { dictionary.removeObject(forKey: settingsSnapshotKey) }
                if let previousClient { dictionary[cursorClientKey] = previousClient }
                else { dictionary.removeObject(forKey: cursorClientKey) }
            }
            body()
        }
        guard animatesAsync else {
            performOnMain(perform)
            return
        }
        backlogLock.lock(); backlog += 1; backlogLock.unlock()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                pendingAnimations.append((kind, client, perform))
                // Bodies only queue work on the overlay's timeline and return at once; the
                // display-synced frame clock plays it. Order is kept (move, then pulse), and the
                // overlay itself collapses or retargets moves that pile up.
                guard !isDrainingAnimations else { return }
                isDrainingAnimations = true
                defer { isDrainingAnimations = false }
                while !pendingAnimations.isEmpty {
                    let next = pendingAnimations.removeFirst()
                    backlogLock.lock(); backlog -= 1; backlogLock.unlock()
                    next.body()
                }
                if deferredReset {
                    deferredReset = false
                    SoftwareCursorOverlay.resetWhenIdle()
                }
            }
        }
    }

    static func performOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body()
            }
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}

func visualCursorEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_VISUAL_CURSOR"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return true
    }

    return !["0", "false", "no", "off"].contains(rawValue)
}

func defaultVisualCursorInitialTipPosition(
    windowOrigin: CGPoint = .zero,
    tipAnchor: CGPoint = SoftwareCursorGlyphMetrics.tipAnchor
) -> CGPoint {
    return CGPoint(
        x: windowOrigin.x + tipAnchor.x,
        y: windowOrigin.y + tipAnchor.y
    )
}

func visualCursorRenderBaseHeading(
    artworkNeutralHeading: CGFloat = SoftwareCursorGlyphMetrics.targetNeutralHeading
) -> CGFloat {
    artworkNeutralHeading
}

func visualCursorAppKitForwardHeading(
    renderRotation: CGFloat,
    artworkNeutralHeading: CGFloat = SoftwareCursorGlyphMetrics.targetNeutralHeading
) -> CGFloat {
    -artworkNeutralHeading - renderRotation
}

func visualCursorRuntimeRenderYAxisMultiplier() -> CGFloat {
    // Window placement uses AppKit global coordinates, but glyph render state is
    // still interpreted as CursorMotion's y-down screen state before drawing.
    -1
}

func visualCursorScreenStateVelocity(
    fromRuntimeVelocity velocity: CGVector,
    yAxisMultiplier: CGFloat
) -> CGVector {
    CGVector(dx: velocity.dx, dy: velocity.dy * yAxisMultiplier)
}

/// The cursor settings one request runs with (see `VisualCursorSupport.settings`).
struct VisualCursorSettings: Equatable, Sendable {
    var enabled: Bool
    /// Playback rate relative to the OCU Fast default timing: 1 is the default, larger is faster,
    /// `.infinity` is instant. See `visualCursorSpeed(environment:)` for the setting's scale.
    var speed: CGFloat
    var floats: Bool
    var lensEnabled: Bool
    var idleHideDelay: TimeInterval
    var observationFilePath: String?
    var traceFilePath: String?
    /// OPEN_COMPUTER_USE_CURSOR_COLOR ("#RRGGBB"); nil keeps the original cursor artwork.
    var color: CursorColor?
    var agentName: String?

    init(environment: [String: String]) {
        color = CursorColor(hex: environment["OPEN_COMPUTER_USE_CURSOR_COLOR"])
        agentName = cursorAgentName(environment["OPEN_COMPUTER_USE_CURSOR_NAME"])
        enabled = visualCursorEnabled(environment: environment)
        speed = visualCursorSpeed(environment: environment)
        floats = visualCursorFloats(environment: environment)
        lensEnabled = ["1", "true", "on", "yes"].contains(
            environment["OPEN_COMPUTER_USE_CURSOR_LENS"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
        idleHideDelay = visualCursorPostInteractionIdleTimeout(environment: environment)
        observationFilePath = visualCursorObservationFileURL(environment: environment)?.path
        let trace = environment["OPEN_COMPUTER_USE_CURSOR_TRACE_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        traceFilePath = trace.isEmpty ? nil : trace
    }
}

/// A cursor label is separate from its private client/session ID.
func cursorAgentName(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 96 else { return nil }
    let name = value.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= 20,
          name.unicodeScalars.first.map(CharacterSet.letters.contains) == true,
          name.unicodeScalars.allSatisfy({
              CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                  || $0 == " " || $0 == "-"
          }) else { return nil }
    return name
}

func availableCursorAgentName(_ name: String, taken: Set<String>) -> String {
    guard taken.contains(name.lowercased()) else { return name }
    var ordinal = 2
    while taken.contains("\(name.lowercased()) \(ordinal)") { ordinal += 1 }
    return "\(name) \(ordinal)"
}

/// The OPEN_COMPUTER_USE_CURSOR_SPEED value that plays the OCU Fast default timing. The number
/// stays on the scale existing callers already use (they pass 2 or 4; 1 was upstream's slow
/// original), so nobody has to change a config to get the default feel.
let visualCursorDefaultSpeedSetting: Double = 4

/// OPEN_COMPUTER_USE_CURSOR_SPEED: how fast the cursor's travel and click pulse play.
/// Unset or 4 is the OCU Fast default: 60 to 140 ms of travel and a 90 ms pulse. 8 is twice as
/// fast, 2 half as fast. There is no upper limit; `instant` (also `inf`, `max`) places the cursor
/// on the target with no travel at all. Anything unreadable means the default.
/// Returns the playback rate relative to the default timing (setting / 4).
func visualCursorSpeed(environment: [String: String] = ProcessInfo.processInfo.environment) -> CGFloat {
    let raw = (environment["OPEN_COMPUTER_USE_CURSOR_SPEED"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["instant", "inf", "infinity", "max", "teleport"].contains(raw) { return .infinity }
    guard let value = Double(raw), !value.isNaN, value > 0 else { return 1 }
    return CGFloat(value / visualCursorDefaultSpeedSetting)
}

/// An animation shorter than one frame cannot be seen; it is skipped and the end state drawn.
let visualCursorMinimumAnimatedDuration: TimeInterval = 1.0 / 120.0

/// How much faster an animation plays when `queuedBehind` others are already waiting, so the cursor
/// catches up with a fast batch instead of replaying it for seconds afterwards.
func visualCursorCatchUpFactor(queuedBehind: Int) -> Double {
    // Floored so a long backlog still glides a little instead of turning every step into a jump.
    max(0.35, 1 / (1 + 0.6 * Double(max(queuedBehind, 0))))
}

/// Seconds one move takes at playback rate `speed`. At 1x a short hop takes about 120 ms and the time rises
/// gently with distance to at most 300 ms across a whole screen: long enough for the eye to follow the glide,
/// short enough that it never feels like waiting. Actions never wait for it (the cursor plays asynchronously).
/// Returns 0 (place directly) for instant speed or when the result would be under one frame.
func visualCursorTravelDuration(distance: CGFloat, speed: CGFloat, queuedBehind: Int = 0) -> TimeInterval {
    guard speed.isFinite, speed > 0, distance.isFinite, distance > 0 else { return 0 }
    let base = 0.12 + 0.18 * (1 - exp(-Double(distance) / 650))
    let duration = base / Double(speed) * visualCursorCatchUpFactor(queuedBehind: queuedBehind)
    return duration < visualCursorMinimumAnimatedDuration ? 0 : duration
}

/// Seconds one click pulse takes at `speed` (150 ms at 1x). 0 means skip the pulse.
func visualCursorClickPulseDuration(speed: CGFloat, queuedBehind: Int = 0) -> TimeInterval {
    guard speed.isFinite, speed > 0 else { return 0 }
    let duration = 0.15 / Double(speed) * visualCursorCatchUpFactor(queuedBehind: queuedBehind)
    return duration < visualCursorMinimumAnimatedDuration ? 0 : duration
}

/// Response time of the spring that carries the drawn tip after the path point. Tight enough that
/// the tip lands with the path, loose enough to lean into the move. Follows the playback rate.
func visualCursorTipSpringResponse(speed: CGFloat) -> CGFloat {
    guard speed.isFinite, speed > 0 else { return 0.04 }
    return (0.07 / speed).clamped(to: 0.04...0.18)
}

/// Where a cursor that is not on screen yet appears: a short step behind the target along the
/// arrow's heading, so it glides in instead of crossing the display from a screen corner.
func visualCursorFreshStartPoint(target: CGPoint, forward: CGVector, distance: CGFloat = 96) -> CGPoint {
    CGPoint(x: target.x - forward.dx * distance, y: target.y - forward.dy * distance)
}

/// The same step, kept on the target's display. Near the bottom or right edge the plain step lies
/// off the display: clamped back, the cursor slid in along the edge with its body out of view, or
/// started on the neighbouring display. Mirrored, it glides in from inside the display instead.
func visualCursorFreshStartPoint(
    target: CGPoint, forward: CGVector, distance: CGFloat = 96, keptInside frame: CGRect
) -> CGPoint {
    let plain = visualCursorFreshStartPoint(target: target, forward: forward, distance: distance)
    guard frame.contains(target) else { return plain }
    return CGPoint(
        x: plain.x < frame.minX || plain.x > frame.maxX ? target.x + (target.x - plain.x) : plain.x,
        y: plain.y < frame.minY || plain.y > frame.maxY ? target.y + (target.y - plain.y) : plain.y
    )
}

func visualCursorNearDisplayEdge(_ point: CGPoint, in frame: CGRect) -> Bool {
    !frame.insetBy(dx: 36, dy: 36).contains(point)
}

func visualCursorFloats(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    let raw = environment["OPEN_COMPUTER_USE_CURSOR_FLOAT"]?.lowercased() ?? "0"
    return ["1", "true", "yes", "on"].contains(raw)
}

/// How long the cursor stays parked after the last action before it fades out
/// (OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS, default 3). Long enough that the next call of the
/// same batch or turn continues from where it is, short enough that it is gone soon after the
/// work stops. `turn-ended` still clears it at once.
func visualCursorPostInteractionIdleTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
    let raw = (environment["OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Double(raw), value.isFinite, value >= 0 else { return 3 }
    return max(value, 0.2)
}

/// The post-action sway stops after this; the static tip stays put until the hide timeout or the
/// turn-ended reset. Only matters when the hide timeout is set longer than this.
func visualCursorIdleSwayTimeout() -> TimeInterval {
    6
}

func visualCursorIdleRotationAmplitude() -> CGFloat {
    0.09
}

public struct VisualCursorObservationPoint: Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(point: CGPoint) {
        x = point.x
        y = point.y
    }
}

public struct VisualCursorObservationSnapshot: Codable, Sendable {
    public let phase: String
    public let tipPosition: VisualCursorObservationPoint?
    public let restingTipPosition: VisualCursorObservationPoint?
    public let rotation: Double?
    public let timestamp: Double

    public init(
        phase: String,
        tipPosition: CGPoint?,
        restingTipPosition: CGPoint?,
        rotation: CGFloat?,
        timestamp: CFTimeInterval
    ) {
        self.phase = phase
        self.tipPosition = tipPosition.map(VisualCursorObservationPoint.init(point:))
        self.restingTipPosition = restingTipPosition.map(VisualCursorObservationPoint.init(point:))
        self.rotation = rotation.map(Double.init)
        self.timestamp = timestamp
    }
}

struct VisualCursorIdlePose {
    let tipPosition: CGPoint
    let angleOffset: CGFloat
}

func visualCursorIdlePose(restingTipPosition: CGPoint, phase: CGFloat) -> VisualCursorIdlePose {
    VisualCursorIdlePose(
        tipPosition: restingTipPosition,
        angleOffset: sin(phase * 0.8) * visualCursorIdleRotationAmplitude()
    )
}

public func visualCursorObservationFileURL(environment: [String: String]) -> URL? {
    guard
        let rawPath = environment["OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !rawPath.isEmpty
    else {
        return nil
    }

    return URL(fileURLWithPath: rawPath)
}

public let openComputerUseTurnEndedNotificationName = Notification.Name("com.ifuryst.opencomputeruse.turn-ended")

public func postOpenComputerUseTurnEndedNotification() {
    DistributedNotificationCenter.default().postNotificationName(
        openComputerUseTurnEndedNotificationName,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

/// Prepares the software cursor at startup so the first action's glide starts without a hitch.
@MainActor
public func prewarmOpenComputerUseVisualCursor() {
    SoftwareCursorOverlay.prewarm()
}

@MainActor
public func resetOpenComputerUseVisualCursor() {
    SoftwareCursorOverlay.resetWhenIdle()
}

struct CursorTargetWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let layer: Int
}

struct CursorWindowGeometry {
    let windowSize: CGSize
    let tipAnchor: CGPoint

    func origin(forTipPosition tipPosition: CGPoint) -> CGPoint {
        CGPoint(
            x: tipPosition.x - tipAnchor.x,
            y: tipPosition.y - tipAnchor.y
        )
    }

    func tipPosition(forOrigin origin: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + tipAnchor.x,
            y: origin.y + tipAnchor.y
        )
    }
}

private struct CursorArtwork {
    let geometry: CursorWindowGeometry
    static let active = CursorArtwork(
        geometry: CursorWindowGeometry(
            windowSize: SoftwareCursorGlyphMetrics.windowSize,
            tipAnchor: SoftwareCursorGlyphMetrics.tipAnchor
        ),
    )
}

// MARK: - Glide and pose math

/// Short moves use a straight path with a small lean.
let visualCursorStraightDistance: CGFloat = 160

/// One cursor glide, a pure function of time so every frame lands exactly on it whatever the frame clock does.
///
/// Long glides use a shallow curve. Short moves, drags, and window following travel straight.
/// A glide that replaces one in flight carries forward its current speed.
struct CursorGlide {
    enum Shape {
        case planned(CursorMotionPath)
        /// Straight line; `tilt` is the peak lean (radians) into the hop.
        case straight(tilt: CGFloat)
    }

    let start: CGPoint
    let end: CGPoint
    let shape: Shape
    let startTime: CFTimeInterval
    let duration: CFTimeInterval
    /// Progress rate at the start (1 = the average rate), from a carried velocity.
    let initialRate: CGFloat
    let fadesIn: Bool

    /// - Parameters:
    ///   - startForward: the arrow's current heading (AppKit).
    ///   - restForward: the arrow's resting heading (AppKit).
    ///   - planned: false forces a straight path for drags, window following, and screen edges.
    init(
        start: CGPoint,
        end: CGPoint,
        startVelocity: CGVector,
        startForward: CGVector,
        restForward: CGVector,
        bounds: CGRect?,
        planned: Bool,
        startTime: CFTimeInterval,
        speed: CGFloat,
        queuedBehind: Int,
        fadesIn: Bool = false,
        fixedDuration: CFTimeInterval? = nil
    ) {
        self.start = start
        self.end = end
        self.startTime = startTime
        self.fadesIn = fadesIn
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        let carriedSpeed = hypot(startVelocity.dx, startVelocity.dy)

        var chosen: Shape = .straight(tilt: 0)
        var length = distance
        if planned, distance >= visualCursorStraightDistance {
            let route = CursorPathPlanner.plan(
                start: start, end: end, bounds: bounds, startForward: startForward, restForward: restForward
            )
            length = route.length
            chosen = .planned(route.path)
        } else if distance > 0.5 {
            let lean = ((restForward.dx * dy - restForward.dy * dx) / distance).clamped(to: -1...1)
            chosen = .straight(tilt: planned ? lean / 3 : 0)
        }
        shape = chosen
        let computed = fixedDuration ?? visualCursorTravelDuration(distance: length, speed: speed, queuedBehind: queuedBehind)
        duration = max(computed, 0.001)

        // Carried momentum continues along the new path's start direction; the part pointing elsewhere is
        // absorbed by the path's own start tangent.
        var rate: CGFloat = 0
        if carriedSpeed > 1, length > 1 {
            let direction: CGVector
            switch chosen {
            case let .planned(path): direction = path.tangent(at: 0)
            case .straight: direction = distance > 0.001 ? CGVector(dx: dx / distance, dy: dy / distance) : CGVector(dx: 0, dy: 0)
            }
            let along = max(0, startVelocity.dx * direction.dx + startVelocity.dy * direction.dy)
            rate = (along * CGFloat(duration) / length).clamped(to: 0...3)
        }
        initialRate = rate
    }

    var endTime: CFTimeInterval { startTime + duration }

    func isFinished(at time: CFTimeInterval) -> Bool { time - startTime >= duration }

    func timeFraction(at time: CFTimeInterval) -> CGFloat {
        CGFloat(((time - startTime) / duration).clamped(to: 0...1))
    }

    /// Cubic Hermite easing carries the initial rate and comes to rest at the target.
    func progress(at time: CFTimeInterval) -> CGFloat {
        let s = timeFraction(at: time)
        let remaining = 1 - s
        return s * s * (3 - 2 * s) + initialRate * s * remaining * remaining
    }

    func point(at time: CFTimeInterval) -> CGPoint {
        point(progress: progress(at: time))
    }

    func point(progress p: CGFloat) -> CGPoint {
        switch shape {
        case let .planned(path):
            return p >= 1 ? end : path.point(at: p)
        case .straight:
            return CGPoint(x: start.x + (end.x - start.x) * p, y: start.y + (end.y - start.y) * p)
        }
    }

    /// Velocity in points per second, from a symmetric difference of the exact curve.
    func velocity(at time: CFTimeInterval) -> CGVector {
        guard !isFinished(at: time) else { return CGVector(dx: 0, dy: 0) }
        let h = min(0.004, duration / 8)
        let a = point(at: max(startTime, time - h))
        let b = point(at: min(endTime, time + h))
        let span = CGFloat(min(endTime, time + h) - max(startTime, time - h))
        guard span > 0 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: (b.x - a.x) / span, dy: (b.y - a.y) / span)
    }

    /// Path tangent (AppKit) for a planned glide, nil for a straight one.
    func tangent(at time: CFTimeInterval) -> CGVector? {
        guard case let .planned(path) = shape else { return nil }
        return path.tangent(at: min(progress(at: time), 0.999))
    }

    /// Lean (radians) of a straight hop at `time`: up and back down over the hop.
    func tilt(at time: CFTimeInterval) -> CGFloat {
        guard case let .straight(tilt) = shape, tilt != 0 else { return 0 }
        return tilt * sin(.pi * min(1, progress(at: time)))
    }

    /// Opacity while a fresh cursor glides in.
    func alpha(at time: CFTimeInterval) -> CGFloat {
        guard fadesIn else { return 1 }
        let s = min(1, timeFraction(at: time) / 0.35)
        return s * s * (3 - 2 * s)
    }
}

/// The arrow's angle, body offset and fog trail. The angle follows a target the glide gives (its path tangent,
/// or a scoot's tilt) through a well-damped spring, so it banks smoothly and never flips; body and fog lag
/// with the tip's true velocity.
struct CursorPoseDynamics {
    var angle: CGFloat = 0
    var angleVelocity: CGFloat = 0
    var smoothedVelocity = CGVector(dx: 0, dy: 0)

    /// A critically damped rotation spring with a six-hertz natural frequency.
    static let angleFrequency: CGFloat = 2 * .pi * 6

    /// Advances the pose toward `targetAngle` and returns the render state for `tip`.
    mutating func advance(
        tip: CGPoint,
        velocity: CGVector,
        targetAngle: CGFloat,
        idleAngleOffset: CGFloat,
        dt rawDT: CGFloat,
        baseHeading: CGFloat,
        configuration: CursorVisualDynamicsConfiguration
    ) -> CursorVisualRenderState {
        let dt = rawDT.clamped(to: 0...0.05)
        let blend = dt > 0 ? 1 - exp(-dt / 0.018) : 1
        smoothedVelocity = CGVector(
            dx: smoothedVelocity.dx + (velocity.dx - smoothedVelocity.dx) * blend,
            dy: smoothedVelocity.dy + (velocity.dy - smoothedVelocity.dy) * blend
        )
        // Render state is interpreted y-down (see visualCursorRuntimeRenderYAxisMultiplier).
        let renderVelocity = CGVector(dx: smoothedVelocity.dx, dy: -smoothedVelocity.dy)
        let speed = hypot(renderVelocity.dx, renderVelocity.dy)

        if dt > 0 {
            let displacement = Self.normalize(angle - targetAngle)
            let frequency = Self.angleFrequency
            let carry = angleVelocity + frequency * displacement
            let decay = exp(-frequency * dt)
            angle = Self.normalize(targetAngle + (displacement + carry * dt) * decay)
            angleVelocity = (angleVelocity - frequency * carry * dt) * decay
        }

        let direction: CGVector = speed > 0.001
            ? CGVector(dx: renderVelocity.dx / speed, dy: renderVelocity.dy / speed)
            : CGVector(dx: cos(baseHeading + idleAngleOffset), dy: sin(baseHeading + idleAngleOffset))
        let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
        let back = -min(speed * configuration.bodyOffsetScale, configuration.bodyOffsetMax)
        let lateral = (angleVelocity * configuration.bodyLateralScale)
            .clamped(to: -configuration.bodyLateralMax...configuration.bodyLateralMax)
        let body = CGVector(
            dx: direction.dx * back + perpendicular.dx * lateral,
            dy: direction.dy * back + perpendicular.dy * lateral
        )
        let fogBack = -min(speed * configuration.fogOffsetScale, configuration.fogOffsetMax)
        let fog = CGVector(
            dx: direction.dx * fogBack + perpendicular.dx * lateral * 0.6,
            dy: direction.dy * fogBack + perpendicular.dy * lateral * 0.6
        )
        let offset = idleAngleOffset.clamped(
            to: -configuration.animatedAngleOffsetMax...configuration.animatedAngleOffsetMax
        )
        return CursorVisualRenderState(
            tipPosition: tip,
            rotation: Self.normalize(angle + offset),
            cursorBodyOffset: body,
            fogOffset: fog,
            fogOpacity: min(configuration.fogOpacityBase + speed * configuration.fogOpacityVelocityScale, 0.34),
            fogScale: 1 + min(speed * configuration.fogScaleVelocityScale, configuration.fogScaleMaxDelta)
        )
    }

    var isAtRest: Bool {
        abs(angle) < 0.002 && abs(angleVelocity) < 0.02 && hypot(smoothedVelocity.dx, smoothedVelocity.dy) < 1
    }

    static func normalize(_ value: CGFloat) -> CGFloat {
        var angle = value.truncatingRemainder(dividingBy: 2 * .pi)
        if angle > .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }
        return angle
    }
}

/// Drives the overlay from the display's refresh. A CADisplayLink paces frames to vsync; a slow
/// fallback timer keeps time moving while no display link fires (locked screen, a window that is
/// ordered out). Nothing ever blocks or pumps the main run loop.
@MainActor
private final class CursorFrameClock: NSObject {
    private var link: CADisplayLink?
    private weak var linkedView: NSView?
    private var fallback: Timer?
    private(set) var lastTick: CFTimeInterval = 0
    private let onFrame: @MainActor (CFTimeInterval) -> Void
    private(set) var isRunning = false

    init(onFrame: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
    }

    func start(on view: NSView?) {
        if let view, linkedView !== view || link == nil {
            link?.invalidate()
            let link = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            linkedView = view
        }
        link?.isPaused = false
        if fallback == nil {
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    // Only steps in when the display link has gone quiet.
                    if CACurrentMediaTime() - self.lastTick > 1 / 40 { self.fire() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallback = timer
        }
        if !isRunning { lastTick = CACurrentMediaTime() }
        isRunning = true
    }

    func stop() {
        isRunning = false
        link?.isPaused = true
        fallback?.invalidate()
        fallback = nil
    }

    func invalidate() {
        stop()
        link?.invalidate()
        link = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        fire()
    }

    private func fire() {
        guard isRunning else { return }
        lastTick = CACurrentMediaTime()
        onFrame(lastTick)
    }
}

// MARK: - Overlay

/// One agent's cursor: its own window, queue, path and frame clock. Agents working in parallel each get one,
/// so their glides never pull a shared cursor back and forth between windows.
@MainActor
final class CursorStage {
    let client: String
    private let fallbackName: String
    /// Tint picked when this cursor appears; distinct from the other agents' cursors on screen.
    private var assignedTint: CursorColor?
    /// A turn-end reset that waits for this cursor's queued work to play.
    private var deferredReset = false

    init(client: String, fallbackName: String = "Agent") {
        self.client = client
        self.fallbackName = fallbackName
    }

    private let artwork = CursorArtwork.active
    private let renderBaseHeading = visualCursorRenderBaseHeading()
    private var panel: CursorPanel?
    private var cursorView: SoftwareCursorView?

    /// Where the tip is drawn now; nil while the cursor is hidden.
    private var displayedTipPosition: CGPoint?
    /// Where the tip rests once the current glide lands.
    private var restingTipPosition: CGPoint?
    private var activeTargetWindow: CursorTargetWindow?
    private var restingAnchor: CursorRestingAnchor?
    private var lastAnchorFrame: CGRect?

    private var glide: CursorGlide?
    private var pulse: ActivePulse?
    private var pose = CursorPoseDynamics()
    /// The tip's velocity on the last drawn frame; a new glide starts with it.
    private var tipVelocity = CGVector(dx: 0, dy: 0)
    private var lastFrameTime: CFTimeInterval = 0
    private var nextHousekeeping: CFTimeInterval = 0
    private var nextRetarget: CFTimeInterval = 0
    /// Idle sway: on after an action finishes, off after `visualCursorIdleSwayTimeout`.
    private var swaying = false
    private var swayStart: CFTimeInterval = 0
    /// Feedback marks (typing, scroll, drag) hold the arrow upright under the mark.
    private var interactionIndicator: CursorInteractionIndicator?
    private var timeline: [Step] = []
    private var observationPhase = "hidden"
    private var activeSettings = VisualCursorSettings(environment: [:])

    private var feedbackTimer: Timer?
    private var fadeTimer: Timer?
    /// Checks the target window between actions, while no frame clock runs.
    private var watchTimer: Timer?
    /// Internal (not private) so CursorHideTimerTests can assert scheduling order.
    var swayStopTimer: Timer?
    var hideTimer: Timer?

    private lazy var clock = CursorFrameClock { [weak self] time in self?.tick(at: time) }

    private struct ActivePulse {
        let point: CGPoint
        let startTime: CFTimeInterval
        let beatDuration: CFTimeInterval
        let beats: Int
        let strength: CGFloat
        let isSecondary: Bool
        let reducesMotion: Bool

        var gap: CFTimeInterval { beatDuration * 0.15 }
        var totalDuration: CFTimeInterval { beatDuration * Double(beats) + gap * Double(max(beats - 1, 0)) }

        /// Press depth and ripple for the beat playing at `time`.
        func sample(at time: CFTimeInterval) -> (press: CGFloat, ripple: CursorClickRipple?) {
            if reducesMotion {
                return (0, CursorClickRipple(progress: 0.5, strength: strength, reducesMotion: true, isSecondary: isSecondary))
            }
            let elapsed = time - startTime
            let period = beatDuration + gap
            let beat = min(Int(elapsed / period), beats - 1)
            let local = elapsed - Double(beat) * period
            guard local <= beatDuration else { return (0, nil) }
            let raw = CGFloat((local / beatDuration).clamped(to: 0...1))
            // Quick press, softer release.
            let attack = min(raw / 0.24, 1)
            let release = max((1 - raw) / 0.76, 0)
            let press = min(attack * attack * (3 - 2 * attack), release * release * (3 - 2 * release)) * strength
            return (press, CursorClickRipple(progress: raw, strength: strength, reducesMotion: false, isSecondary: isSecondary))
        }
    }

    /// One queued piece of cursor work. Glides and pulses take time; the others apply at once when
    /// they reach the head of the queue, so a click's pulse always plays after its glide lands.
    private enum Step {
        case glide(target: CGPoint, window: CursorTargetWindow?, anchor: CursorRestingAnchor?, settings: VisualCursorSettings)
        case pulse(target: CGPoint, clickCount: Int, button: MouseButtonKind, window: CursorTargetWindow?, anchor: CursorRestingAnchor?, settings: VisualCursorSettings)
        case settle(target: CGPoint, window: CursorTargetWindow?, anchor: CursorRestingAnchor?, settings: VisualCursorSettings)
        case beginFeedback(CursorInteractionFeedback, target: CGPoint?, window: CursorTargetWindow?, anchor: CursorRestingAnchor?, settings: VisualCursorSettings)
        case endFeedback(CursorInteractionFeedback, target: CGPoint?, window: CursorTargetWindow?, anchor: CursorRestingAnchor?, settings: VisualCursorSettings)
        case cancelFeedback(CursorInteractionFeedback)

        var isGlide: Bool { if case .glide = self { return true } else { return false } }
    }

    /// True while queued or playing cursor work remains.
    var isBusy: Bool { glide != nil || pulse != nil || !timeline.isEmpty }

    /// Steps still waiting behind the one playing; drives catch-up.
    var pendingStepCount: Int { timeline.count }

    var isVisible: Bool { panel?.isVisible == true && displayedTipPosition != nil }

    var currentTintHex: String? { cursorView?.tint?.hexString }
    private(set) var currentAgentName: String?

    /// Builds the window, draws the glyph once and sets up the frame clock without showing anything, so the
    /// first real move does not pay for them (about 110 ms, measured).
    func prewarm() {
        prepareWindowIfNeeded()
        cursorView?.needsDisplay = true
        cursorView?.displayIfNeeded()
        clock.start(on: cursorView)
        clock.stop()
    }

    /// Releases the window and frame clock of a cursor that is no longer needed.
    func shutdown() {
        reset()
        clock.invalidate()
        panel?.close()
        panel = nil
        cursorView = nil
    }

    // MARK: Public entry points (all return immediately)

    func moveCursor(
        to targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else { return }
        deferredReset = false
        // Claim only when another process holds the cursor (or none is shown). Re-claiming on every
        // move reset another OCU process mid-glide each time, so two agents made the cursor flicker.
        if SoftwareCursorOverlay.latestClaimPID != ProcessInfo.processInfo.processIdentifier || displayedTipPosition == nil {
            SoftwareCursorOverlay.claimDesktopCursor()
        }
        enqueue(.glide(target: targetPoint, window: targetWindow, anchor: anchor, settings: VisualCursorSupport.settings))
    }

    func pulseClick(
        at targetPoint: CGPoint,
        clickCount: Int,
        mouseButton: MouseButtonKind,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay, SoftwareCursorOverlay.ownsCursor() else { return }
        enqueue(.pulse(
            target: targetPoint, clickCount: max(clickCount, 1), button: mouseButton,
            window: targetWindow, anchor: anchor, settings: VisualCursorSupport.settings
        ))
    }

    func settle(
        at targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay, SoftwareCursorOverlay.ownsCursor() else { return }
        enqueue(.settle(target: targetPoint, window: targetWindow, anchor: anchor, settings: VisualCursorSupport.settings))
    }

    func beginFeedback(
        _ feedback: CursorInteractionFeedback,
        at targetPoint: CGPoint? = nil,
        in targetWindow: CursorTargetWindow? = nil,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay, SoftwareCursorOverlay.ownsCursor() else { return }
        guard targetPoint != nil || displayedTipPosition != nil || isBusy else { return }
        enqueue(.beginFeedback(feedback, target: targetPoint, window: targetWindow, anchor: anchor, settings: VisualCursorSupport.settings))
    }

    func endFeedback(
        _ feedback: CursorInteractionFeedback,
        at targetPoint: CGPoint? = nil,
        in targetWindow: CursorTargetWindow? = nil,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, SoftwareCursorOverlay.ownsCursor() else { return }
        enqueue(.endFeedback(feedback, target: targetPoint, window: targetWindow, anchor: anchor, settings: VisualCursorSupport.settings))
    }

    func cancelFeedback(_ feedback: CursorInteractionFeedback) {
        guard VisualCursorSupport.isEnabled, SoftwareCursorOverlay.ownsCursor() else { return }
        enqueue(.cancelFeedback(feedback))
    }

    /// The overlay window, exposed for tests that must observe presentation state.
    var overlayPanelForTesting: NSWindow? { panel }

    /// Runs the main run loop until queued cursor work has played (tests and the smoke suite).
    func waitUntilIdleForTesting(timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while isBusy, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
        }
    }

    /// Reset now, or once the queued animations have played (see `VisualCursorSupport.deferredReset`).
    func resetWhenIdle() {
        if VisualCursorSupport.isDraining || isBusy {
            deferredReset = true
        } else {
            fadeOutAndReset()
        }
    }

    /// The end of a turn: a visible cursor fades out (a new action takes it back mid-fade), a
    /// hidden one is simply cleared.
    private func fadeOutAndReset() {
        if panel?.isVisible == true, displayedTipPosition != nil, fadeTimer == nil {
            hideOverlay()
        } else if fadeTimer == nil {
            reset()
        }
    }

    func reset() {
        if panel?.isVisible == true { trace("reset") }
        timeline.removeAll()
        glide = nil
        pulse = nil
        releaseTail = nil
        endFade()
        clearFeedback()
        stopSway()
        cancelPendingHide()
        stopWatch()
        clock.stop()
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        restingAnchor = nil
        lastAnchorFrame = nil
        CursorWindowFrameTracker.forgetAll()
        pose = CursorPoseDynamics()
        tipVelocity = CGVector(dx: 0, dy: 0)
        cursorView?.rotation = 0
        observationPhase = "hidden"
        writeObservationSnapshot(tipPosition: nil, rotation: nil)
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    // MARK: Timeline

    private func enqueue(_ step: Step) {
        timeline.append(step)
        // A glide in flight is replaced by the next glide right away (velocity carries over), instead
        // of finishing its landing first. Pulses and marks still wait for their own glide to land.
        // A drag still lands on its press point first, so the drawn drag starts where the real one did.
        if step.isGlide, timeline.count == 1, let current = glide, pulse == nil,
           interactionIndicator != CursorInteractionIndicator(feedback: .drag) {
            let now = CACurrentMediaTime()
            glide = nil
            render(tip: current.point(at: now), velocity: current.velocity(at: now), angle: targetAngle(for: current, at: now), at: now)
            panel?.alphaValue = 1
        }
        advanceTimeline(at: CACurrentMediaTime())
        if glide != nil || pulse != nil || needsFrames {
            startClock()
        }
    }

    /// Starts every step whose turn has come. Instant steps run synchronously, so a settle or mark
    /// queued while nothing plays shows up at once.
    private func advanceTimeline(at now: CFTimeInterval) {
        if let current = glide, current.isFinished(at: now) { landGlide(current, at: now) }
        if let current = pulse {
            let elapsed = now - current.startTime
            // With more work queued, the press has been seen once its peak passed: the release overlaps
            // the next glide instead of holding a fast batch up.
            let releaseOverlaps = !timeline.isEmpty && current.beats == 1 && elapsed >= current.totalDuration * 0.5
            if elapsed >= current.totalDuration || releaseOverlaps { finishPulse(at: now) }
        }
        while glide == nil, pulse == nil, !timeline.isEmpty {
            let step = timeline.removeFirst()
            // Consecutive glides collapse: only the last one of a run is drawn, from wherever the tip is.
            if step.isGlide, timeline.first?.isGlide == true { continue }
            run(step, at: now)
        }
        if glide == nil, pulse == nil, timeline.isEmpty, deferredReset, !VisualCursorSupport.isDraining {
            deferredReset = false
            fadeOutAndReset()
        }
    }

    private func run(_ step: Step, at now: CFTimeInterval) {
        switch step {
        case let .glide(target, window, anchor, settings):
            adopt(settings)
            beginGlide(to: target, window: window, anchor: anchor, at: now)
        case let .pulse(target, clickCount, button, window, anchor, settings):
            adopt(settings)
            beginPulse(at: target, clickCount: clickCount, button: button, window: window, anchor: anchor, now: now)
        case let .settle(target, window, anchor, settings):
            adopt(settings)
            arrive(at: target, window: window, anchor: anchor, now: now)
            observationPhase = "settling"
            if interactionIndicator == nil { resumeIdle(at: now) }
        case let .beginFeedback(feedback, target, window, anchor, settings):
            adopt(settings)
            guard let point = target ?? displayedTipPosition else { return }
            clearFeedback()
            stopSway()
            cancelPendingHide()
            if target != nil {
                arrive(at: point, window: window, anchor: anchor, now: now, keepsIdle: true)
            }
            interactionIndicator = CursorInteractionIndicator(feedback: feedback)
            observationPhase = interactionIndicator?.phase ?? observationPhase
            // The mark shows at once, not on the next frame.
            if glide == nil, let tip = restingTipPosition ?? displayedTipPosition {
                render(tip: tip, velocity: CGVector(dx: 0, dy: 0), at: now)
            }
            // Recover if an interrupted operation never queues its completion.
            scheduleHide(after: max(activeSettings.idleHideDelay, 12))
            startClock()
        case let .endFeedback(feedback, target, window, anchor, settings):
            guard interactionIndicator == CursorInteractionIndicator(feedback: feedback) else { return }
            adopt(settings)
            cancelPendingHide()
            if let target {
                arrive(at: target, window: window, anchor: anchor, now: now, keepsIdle: true)
            }
            interactionIndicator?.isCompleted = true
            observationPhase = interactionIndicator?.phase ?? observationPhase
            if glide == nil, let tip = restingTipPosition ?? displayedTipPosition {
                render(tip: tip, velocity: CGVector(dx: 0, dy: 0), at: now)
            }
            startClock()
            feedbackTimer?.invalidate()
            let timer = Timer(timeInterval: feedback.completionDuration, repeats: false) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    clearFeedback()
                    observationPhase = "settling"
                    resumeIdle(at: CACurrentMediaTime())
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            feedbackTimer = timer
        case let .cancelFeedback(feedback):
            guard interactionIndicator == CursorInteractionIndicator(feedback: feedback) else { return }
            clearFeedback()
            observationPhase = "settling"
            resumeIdle(at: now)
        }
    }

    private func adopt(_ settings: VisualCursorSettings) {
        let nameChanged = activeSettings.agentName != settings.agentName
        activeSettings = settings
        if displayedTipPosition == nil || panel?.isVisible != true {
            assignedTint = SoftwareCursorOverlay.tintForAppearingCursor(client: client)
        }
        if nameChanged || currentAgentName == nil {
            currentAgentName = SoftwareCursorOverlay.nameForCursor(client: client, preferred: settings.agentName ?? fallbackName)
            cursorView?.agentName = currentAgentName
        }
        cursorView?.tint = settings.color ?? assignedTint
        cursorView?.lensEnabled = settings.lensEnabled
    }

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func beginGlide(
        to targetPoint: CGPoint, window: CursorTargetWindow?, anchor: CursorRestingAnchor?, at now: CFTimeInterval
    ) {
        if interactionIndicator != CursorInteractionIndicator(feedback: .drag) { clearFeedback() }
        prepareWindowIfNeeded()
        endFade()
        stopSway()
        cancelPendingHide()
        // A move alone must still own a disappearance: if the pipeline throws before any settle or
        // pulse is queued, nothing else schedules the hide. Long enough for a slow action to finish.
        scheduleHide(after: max(activeSettings.idleHideDelay, 12))

        adoptAnchor(anchor)
        lastAnchorFrame = anchor.flatMap { CursorWindowFrameTracker.liveFrame(for: $0.windowID) } ?? anchor?.windowBounds
        let target = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        restingTipPosition = target
        let visible = displayedTipPosition != nil && panel?.isVisible == true
        let screenFrame = (screen(containing: target) ?? nearestScreen(to: target))?.frame
        let start = visible ? displayedTipPosition! : clampTipPosition(visualCursorFreshStartPoint(
            target: target, forward: restingForwardVector(), keptInside: screenFrame ?? .null
        ))
        let distance = hypot(target.x - start.x, target.y - start.y)
        let velocity = visible ? tipVelocity : CGVector(dx: 0, dy: 0)
        let dragging = interactionIndicator == CursorInteractionIndicator(feedback: .drag)
        let nearEdge = screenFrame.map { visualCursorNearDisplayEdge(start, in: $0) || visualCursorNearDisplayEdge(target, in: $0) } ?? false
        let speed = activeSettings.speed
        let instant = reducesMotion || !speed.isFinite || speed <= 0
        // A drag travels straight, like the mouse events it draws; next to a display edge the arc could
        // leave the display, so it scoots straight too.
        let candidate = instant ? nil : CursorGlide(
            start: start,
            end: target,
            startVelocity: nearEdge ? CGVector(dx: 0, dy: 0) : velocity,
            startForward: forwardVector(renderRotation: visible ? pose.angle : 0),
            restForward: restingForwardVector(),
            bounds: motionBounds(from: start, to: target),
            planned: !dragging && !nearEdge,
            startTime: now,
            speed: speed,
            queuedBehind: timeline.count,
            fadesIn: !visible
        )
        let duration = candidate.map { $0.duration > 0.0011 ? $0.duration : 0 } ?? 0
        trace("move from=(\(Int(start.x)),\(Int(start.y))) to=(\(Int(target.x)),\(Int(target.y))) fresh=\(!visible) ms=\(Int(duration * 1000))")
        observationPhase = "moving"

        if !visible {
            pose = CursorPoseDynamics()
            panel?.alphaValue = duration > 0 ? 0 : 1
            render(tip: duration > 0 ? start : target, velocity: CGVector(dx: 0, dy: 0), at: now)
        }
        configureOrdering(relativeTo: window)
        startWatch()

        guard let candidate, duration > 0, distance > 0.5 || hypot(velocity.dx, velocity.dy) > 30 else {
            glide = nil
            panel?.alphaValue = 1
            render(tip: target, velocity: CGVector(dx: 0, dy: 0), at: now)
            return
        }
        glide = candidate
        nextRetarget = now + 0.1
        startClock()
    }

    private func landGlide(_ landed: CursorGlide, at now: CFTimeInterval) {
        glide = nil
        panel?.alphaValue = 1
        render(tip: landed.end, velocity: CGVector(dx: 0, dy: 0), at: now)
    }

    /// Puts the cursor on `targetPoint` for a step that does not travel itself (a pulse, a mark, a
    /// settle). A hidden cursor appears there; one still far away (its glide was collapsed into a
    /// later one, or it never had one) glides there first. A close one just takes it as its rest.
    /// Returns true when a glide was started.
    @discardableResult
    private func arrive(
        at targetPoint: CGPoint, window: CursorTargetWindow?, anchor: CursorRestingAnchor?,
        now: CFTimeInterval, keepsIdle: Bool = false
    ) -> Bool {
        prepareWindowIfNeeded()
        endFade()
        adoptAnchor(anchor)
        _ = reanchorIfWindowMoved()
        let target = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let hidden = displayedTipPosition == nil || panel?.isVisible != true
        if hidden {
            pose = CursorPoseDynamics()
            restingTipPosition = target
            panel?.alphaValue = 1
            render(tip: target, velocity: CGVector(dx: 0, dy: 0), at: now)
            configureOrdering(relativeTo: window)
            startWatch()
            return false
        }
        if let shown = displayedTipPosition, hypot(shown.x - target.x, shown.y - target.y) > 24, !reducesMotion {
            beginGlide(to: targetPoint, window: window, anchor: anchor, at: now)
            return glide != nil
        }
        restingTipPosition = target
        configureOrdering(relativeTo: window)
        startWatch()
        if !keepsIdle { startClock() }
        return false
    }

    private func beginPulse(
        at targetPoint: CGPoint, clickCount: Int, button: MouseButtonKind,
        window: CursorTargetWindow?, anchor: CursorRestingAnchor?, now: CFTimeInterval
    ) {
        clearFeedback()
        stopSway()
        cancelPendingHide()
        // The pulse plays where the tip lands. If it still has to get there, glide first and put the
        // pulse back at the head of the queue.
        if arrive(at: targetPoint, window: window, anchor: anchor, now: now) {
            timeline.insert(.pulse(
                target: targetPoint, clickCount: clickCount, button: button,
                window: window, anchor: anchor, settings: activeSettings
            ), at: 0)
            return
        }
        let duration = visualCursorClickPulseDuration(speed: activeSettings.speed, queuedBehind: timeline.count)
        let point = restingTipPosition ?? clampTipPosition(targetPoint)
        trace("pulse at=(\(Int(point.x)),\(Int(point.y))) count=\(clickCount) ms=\(Int(duration * 1000))")
        observationPhase = "pulse"
        guard duration > 0 else {
            resumeIdle(at: now)
            return
        }
        // Multi-click beats stay readable without holding up later actions.
        let requested = min(max(clickCount, 1), 3)
        let beats = duration / sqrt(Double(requested)) < 0.04 ? 1 : requested
        pulse = ActivePulse(
            point: point,
            startTime: now,
            beatDuration: duration / sqrt(Double(beats)),
            beats: beats,
            strength: button == .right ? 0.82 : 1,
            isSecondary: button == .right,
            reducesMotion: reducesMotion
        )
        startClock()
    }

    private func finishPulse(at now: CFTimeInterval) {
        if let current = pulse, !current.reducesMotion {
            let elapsed = now - current.startTime
            let progress = CGFloat((elapsed / current.beatDuration).clamped(to: 0...1))
            if progress < 1 {
                // Cut short for queued work: the press and ripple finish over a short tail as the cursor moves on.
                releaseTail = ReleaseTail(
                    press: cursorView?.clickProgress ?? 0, rippleProgress: progress,
                    strength: current.strength, isSecondary: current.isSecondary, startTime: now
                )
            }
        }
        pulse = nil
        resumeIdle(at: now)
    }

    private struct ReleaseTail {
        let press: CGFloat
        let rippleProgress: CGFloat
        let strength: CGFloat
        let isSecondary: Bool
        let startTime: CFTimeInterval
        static let duration: CFTimeInterval = 0.09

        func sample(at time: CFTimeInterval) -> (press: CGFloat, ripple: CursorClickRipple?)? {
            let t = CGFloat((time - startTime) / Self.duration)
            guard t < 1 else { return nil }
            let eased = 1 - (1 - t) * (1 - t)
            return (press * (1 - eased), CursorClickRipple(
                progress: rippleProgress + (1 - rippleProgress) * eased,
                strength: strength, reducesMotion: false, isSecondary: isSecondary
            ))
        }
    }

    private var releaseTail: ReleaseTail?

    // MARK: Frame loop

    private var needsFrames: Bool {
        guard panel?.isVisible == true, displayedTipPosition != nil else { return false }
        return glide != nil || pulse != nil || releaseTail != nil || swaying || !pose.isAtRest
    }

    private func startClock() {
        guard panel != nil else { return }
        if !clock.isRunning { lastFrameTime = CACurrentMediaTime() }
        clock.start(on: cursorView)
        stopWatch()
    }

    private func tick(at now: CFTimeInterval) {
        guard panel?.isVisible == true || glide != nil || pulse != nil || !timeline.isEmpty else {
            clock.stop()
            return
        }

        // Window bookkeeping is a few window-server round trips. Ten times a second is plenty to
        // stay above a target window that gets raised, and never costs a frame.
        if now >= nextHousekeeping {
            let moving = glide != nil || pulse != nil
            nextHousekeeping = now + (moving ? 0.25 : 0.1)
            if !refreshActiveOrdering(reorder: !moving) { return }
        }
        if now >= nextRetarget {
            nextRetarget = now + 0.05
            followMovedWindow(at: now)
        }

        advanceTimeline(at: now)

        guard displayedTipPosition != nil else {
            if glide == nil, pulse == nil, timeline.isEmpty { clock.stop() }
            return
        }

        if let glide {
            panel?.alphaValue = glide.alpha(at: now)
            render(tip: glide.point(at: now), velocity: glide.velocity(at: now), angle: targetAngle(for: glide, at: now), at: now)
        } else {
            render(tip: restingTipPosition ?? displayedTipPosition!, velocity: CGVector(dx: 0, dy: 0), at: now)
        }

        if !needsFrames, timeline.isEmpty {
            clock.stop()
            startWatch()
        }
    }

    /// Draws one frame. Position is exact; the lean comes from the pose spring.
    private func render(tip: CGPoint, velocity: CGVector, angle targetAngle: CGFloat = 0, at now: CFTimeInterval) {
        guard let panel, let cursorView else { return }
        let dt = CGFloat(max(0, now - lastFrameTime))
        lastFrameTime = now

        var idleOffset: CGFloat = 0
        if swaying, !reducesMotion {
            // Starts from zero and fades in, so the sway never jolts the resting pose.
            let t = CGFloat(now - swayStart)
            let fadeIn = min(1, t / 0.6)
            idleOffset = sin(t * 2.4) * visualCursorIdleRotationAmplitude() * fadeIn * fadeIn
        }
        // A mark (typing, scroll, drag) stands the arrow upright under it.
        if interactionIndicator != nil, interactionIndicator?.feedback != .drag { idleOffset = 0 }

        var state = pose.advance(
            tip: tip,
            velocity: reducesMotion ? CGVector(dx: 0, dy: 0) : velocity,
            // The sway goes through the spring too: when it stops or a mark starts, the arrow eases upright
            // instead of jumping by the sway's current angle.
            targetAngle: reducesMotion ? 0 : targetAngle + idleOffset,
            idleAngleOffset: 0,
            dt: dt,
            baseHeading: renderBaseHeading,
            configuration: .fast(speed: activeSettings.speed.isFinite ? activeSettings.speed : 1)
        )
        if reducesMotion {
            pose = CursorPoseDynamics()
            state = initialRenderState(at: tip)
        }

        var press: CGFloat = 0
        var ripple: CursorClickRipple?
        if let pulse {
            (press, ripple) = pulse.sample(at: now)
            releaseTail = nil
        } else if let tail = releaseTail {
            if let sample = tail.sample(at: now) { (press, ripple) = sample } else { releaseTail = nil }
        }

        let origin = artwork.geometry.origin(forTipPosition: state.tipPosition)
        // Whole-pixel steps on a 1x display and half-pixel on Retina keep the glyph crisp at rest
        // without making a slow glide visibly step.
        let scale = (screen(containing: state.tipPosition) ?? panel.screen)?.backingScaleFactor ?? 2
        let snapped = CGPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale)
        if panel.frame.origin != snapped { panel.setFrameOrigin(snapped) }

        let changed = cursorView.rotation != state.rotation
            || cursorView.cursorBodyOffset != state.cursorBodyOffset
            || cursorView.fogOffset != state.fogOffset
            || cursorView.fogOpacity != state.fogOpacity
            || cursorView.fogScale != state.fogScale
            || cursorView.clickProgress != press
            || (cursorView.ripple == nil) != (ripple == nil)
            || ripple != nil
            || cursorView.indicator != interactionIndicator
            || cursorView.lensEnabled != activeSettings.lensEnabled
        cursorView.rotation = state.rotation
        cursorView.cursorBodyOffset = state.cursorBodyOffset
        cursorView.fogOffset = state.fogOffset
        cursorView.fogOpacity = state.fogOpacity
        cursorView.fogScale = state.fogScale
        cursorView.clickProgress = press
        cursorView.ripple = ripple
        cursorView.indicator = interactionIndicator
        cursorView.lensEnabled = activeSettings.lensEnabled
        if changed || displayedTipPosition == nil { cursorView.needsDisplay = true }
        displayedTipPosition = state.tipPosition
        tipVelocity = velocity
        writeObservationSnapshot(tipPosition: state.tipPosition, rotation: state.rotation)
    }

    private func initialRenderState(at tipPosition: CGPoint) -> CursorVisualRenderState {
        CursorVisualRenderState(
            tipPosition: tipPosition,
            rotation: 0,
            cursorBodyOffset: CGVector(dx: 0, dy: 0),
            fogOffset: CGVector(dx: 0, dy: 0),
            fogOpacity: CursorVisualDynamicsConfiguration.officialInspired.fogOpacityBase,
            fogScale: 1
        )
    }

    // MARK: Idle, hide, fade

    private func resumeIdle(at now: CFTimeInterval) {
        scheduleHide(after: activeSettings.idleHideDelay)
        guard !reducesMotion, interactionIndicator == nil else {
            startWatch()
            return
        }
        observationPhase = "idle"
        swaying = true
        swayStart = now
        scheduleSwayStop()
        startClock()
    }

    private func stopSway() {
        swaying = false
        swayStopTimer?.invalidate()
        swayStopTimer = nil
    }

    private func scheduleSwayStop() {
        swayStopTimer?.invalidate()
        let timer = Timer(timeInterval: visualCursorIdleSwayTimeout(), repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // The arrow eases back upright; the frame clock stops once it rests.
                swaying = false
                swayStopTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        swayStopTimer = timer
    }

    func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                hideTimer = nil
                // Work still queued or playing owns the cursor; it schedules its own hide.
                guard !isBusy else { return }
                hideOverlay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func cancelPendingHide() {
        hideTimer?.invalidate()
        hideTimer = nil
        swayStopTimer?.invalidate()
        swayStopTimer = nil
    }

    private func clearFeedback() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        interactionIndicator = nil
        cursorView?.indicator = nil
        cursorView?.needsDisplay = true
    }

    private func endFade() {
        guard let fadeTimer else { return }
        fadeTimer.invalidate()
        self.fadeTimer = nil
        panel?.alphaValue = 1
    }

    private func hideOverlay() {
        guard let panel, panel.isVisible else { return }
        // A fade already running owns the hide.
        guard fadeTimer == nil else { return }
        timeline.removeAll()
        glide = nil
        pulse = nil
        releaseTail = nil
        stopSway()
        cancelPendingHide()
        clearFeedback()
        stopWatch()
        clock.stop()
        trace("hide")
        if reducesMotion {
            finishHide(panel)
            return
        }
        // 180 ms smoothstep fade on its own timer; any new action ends it at once (see endFade).
        let start = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.18
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let t = CGFloat(min(1, (CACurrentMediaTime() - start) / duration))
                if t >= 1 {
                    finishHide(panel)
                    return
                }
                panel.alphaValue = 1 - t * t * (3 - 2 * t)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func finishHide(_ panel: CursorPanel) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        restingAnchor = nil
        lastAnchorFrame = nil
        CursorWindowFrameTracker.forgetAll()
        pose = CursorPoseDynamics()
        tipVelocity = CGVector(dx: 0, dy: 0)
        // The next fresh start reads the glyph's heading; a stale turn from the last session would bend it.
        cursorView?.rotation = 0
        observationPhase = "hidden"
        writeObservationSnapshot(tipPosition: nil, rotation: nil)
    }

    // MARK: Window following and ordering

    /// Between actions, a light 10 Hz check keeps the cursor above its window and on it.
    private func startWatch() {
        guard !clock.isRunning, activeTargetWindow != nil || restingAnchor != nil, panel?.isVisible == true,
              fadeTimer == nil else { return }
        guard watchTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard panel?.isVisible == true, fadeTimer == nil, !clock.isRunning else {
                    stopWatch()
                    return
                }
                guard refreshActiveOrdering() else { return }
                if movedAnchorTarget() != nil { startClock() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func stopWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// Keeps a resting or gliding cursor on its window when that window moves: a glide bends toward
    /// the new spot from where it is (velocity kept); a resting cursor follows directly.
    private func followMovedWindow(at now: CFTimeInterval) {
        guard let moved = movedAnchorTarget() else { return }
        observationPhase = glide == nil ? "reanchored" : "retargeted"
        if let current = glide {
            let tip = current.point(at: now)
            let remaining = max(current.endTime - now, 0.08)
            glide = CursorGlide(
                start: tip, end: moved, startVelocity: current.velocity(at: now),
                startForward: forwardVector(renderRotation: pose.angle), restForward: restingForwardVector(),
                bounds: nil, planned: false, startTime: now, speed: activeSettings.speed, queuedBehind: 0,
                fixedDuration: remaining
            )
        } else {
            render(tip: moved, velocity: CGVector(dx: 0, dy: 0), at: now)
        }
    }

    /// Returns false when the cursor's window is gone and the cursor started fading out.
    @discardableResult
    private func refreshActiveOrdering(reorder: Bool = true) -> Bool {
        guard let activeTargetWindow else { return true }
        // On screen, not merely listed: a window moved to another Space or minimized is still listed,
        // and the cursor would float over the desktop the user is on.
        guard let info = windowInfo(activeTargetWindow.windowID),
              info[kCGWindowIsOnscreen as String] as? Bool == true else {
            hideOverlay()
            return false
        }
        if reorder, let panel, !activeSettings.floats {
            panel.order(.above, relativeTo: Int(activeTargetWindow.windowID))
        }
        return true
    }

    private var canPresentOverlay: Bool {
        !NSScreen.screens.isEmpty
    }

    private func prepareWindowIfNeeded() {
        guard panel == nil else { return }
        let panel = CursorPanel(
            contentRect: CGRect(origin: .zero, size: artwork.geometry.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        let view = SoftwareCursorView(frame: CGRect(origin: .zero, size: artwork.geometry.windowSize))
        panel.contentView = view
        self.panel = panel
        cursorView = view
        view.agentName = currentAgentName
    }

    private func configureOrdering(relativeTo targetWindow: CursorTargetWindow?) {
        guard let panel else { return }
        let effectiveTargetWindow = targetWindow.flatMap { target -> CursorTargetWindow? in
            guard let info = windowInfo(target.windowID),
                  info[kCGWindowIsOnscreen as String] as? Bool == true,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            return CursorTargetWindow(windowID: target.windowID, layer: layer)
        }

        // OPEN_COMPUTER_USE_CURSOR_FLOAT=1: draw above every window, so the cursor is visible even when
        // the app it drives sits behind other windows (background control). Click-through either way.
        if activeSettings.floats {
            if panel.level != .floating { panel.level = .floating }
            if !panel.isVisible { panel.orderFrontRegardless() }
            activeTargetWindow = effectiveTargetWindow
            return
        }

        let desiredLevel = NSWindow.Level(rawValue: effectiveTargetWindow?.layer ?? 0)
        if panel.level != desiredLevel { panel.level = desiredLevel }

        if shouldReorderCursorPanel(
            activeTargetWindow: activeTargetWindow,
            effectiveTargetWindow: effectiveTargetWindow,
            panelIsVisible: panel.isVisible,
            forceReorder: false
        ) {
            if let effectiveTargetWindow {
                panel.order(.above, relativeTo: Int(effectiveTargetWindow.windowID))
            } else if let behind = cursorBehindWindowID(
                windowList: CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [],
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            ) {
                // No window to point at: stay behind the user's frontmost app, never in front of the work they see.
                panel.order(.below, relativeTo: Int(behind))
            } else {
                panel.orderBack(nil)
            }
            activeTargetWindow = effectiveTargetWindow
        }
    }

    private func windowInfo(_ windowID: CGWindowID) -> [String: Any]? {
        guard windowID != 0,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] else {
            return nil
        }
        return windows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
    }

    /// Re-derive a target point that was computed from a snapshot taken before
    /// the window moved. Element frames are window-relative, so the anchored
    /// point follows the window instead of staying on the display it just left.
    private func liveTargetPoint(_ targetPoint: CGPoint, anchor: CursorRestingAnchor?) -> CGPoint {
        guard let anchor,
              let liveFrame = CursorWindowFrameTracker.liveFrame(for: anchor.windowID),
              let screenStatePoint = anchor.screenStatePoint(liveFrame: liveFrame)
        else {
            return targetPoint
        }
        return screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: screenStatePoint,
            screenMappings: currentVisualCursorScreenMappings()
        )
    }

    private func adoptAnchor(_ anchor: CursorRestingAnchor?) {
        // Register this anchor's own window now, when its animation runs. Registering when the
        // action was queued let a later action in a batch swap the source before this one played.
        if let anchor, let source = anchor.frameSource {
            CursorWindowFrameTracker.register(windowID: anchor.windowID, element: source.element)
        }
        if restingAnchor != anchor {
            restingAnchor = anchor
            lastAnchorFrame = anchor?.windowBounds
        }
    }

    /// The anchored target re-derived from the window's live frame, when the window moved since the
    /// last look. Updates the remembered frame and resting tip; does not draw.
    private func movedAnchorTarget() -> CGPoint? {
        guard let anchor = restingAnchor,
              let liveFrame = CursorWindowFrameTracker.liveFrame(for: anchor.windowID),
              !framesNearlyEqual(liveFrame, lastAnchorFrame),
              let screenStatePoint = anchor.screenStatePoint(liveFrame: liveFrame)
        else {
            return nil
        }
        let constrainedTarget = clampTipPosition(
            screenStatePointToAppKitGlobalPoint(
                fromScreenStatePoint: screenStatePoint,
                screenMappings: currentVisualCursorScreenMappings()
            )
        )
        lastAnchorFrame = liveFrame
        restingTipPosition = constrainedTarget
        return constrainedTarget
    }

    /// Relocate the visible tip, not just its target. Otherwise it is drawn on the
    /// previous display for a frame after reanchoring.
    @discardableResult
    private func reanchorIfWindowMoved() -> Bool {
        guard let constrainedTarget = movedAnchorTarget() else { return false }
        observationPhase = "reanchored"
        if displayedTipPosition != nil, glide == nil {
            render(tip: constrainedTarget, velocity: CGVector(dx: 0, dy: 0), at: CACurrentMediaTime())
        }
        return true
    }

    /// The arrow's heading (AppKit) when drawn at `renderRotation`.
    private func forwardVector(renderRotation: CGFloat) -> CGVector {
        let angle = visualCursorAppKitForwardHeading(renderRotation: renderRotation)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    /// The render rotation that points the arrow along an AppKit direction.
    private func renderRotation(along direction: CGVector) -> CGFloat {
        CursorPoseDynamics.normalize(-renderBaseHeading - atan2(direction.dy, direction.dx))
    }

    /// What the arrow's angle aims for during a glide: the planned path's tangent, or a scoot's tilt.
    private func targetAngle(for glide: CursorGlide, at now: CFTimeInterval) -> CGFloat {
        if let tangent = glide.tangent(at: now), hypot(tangent.dx, tangent.dy) > 0.001 {
            // Lean into the move while keeping the cursor recognizable in every direction.
            let lean = renderRotation(along: tangent).clamped(to: -1 / 3...1 / 3)
            return lean * sin(.pi * glide.timeFraction(at: now))
        }
        return glide.tilt(at: now)
    }

    /// The display area paths are kept inside: the visible frames of the start's and the target's displays.
    private func motionBounds(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let first = screen(containing: start) ?? nearestScreen(to: start)
        let second = screen(containing: end) ?? nearestScreen(to: end)
        switch (first, second) {
        case let (a?, b?): return a === b ? a.visibleFrame : a.visibleFrame.union(b.visibleFrame)
        case let (a?, nil), let (nil, a?): return a.visibleFrame
        default: return nil
        }
    }

    private func restingForwardVector() -> CGVector {
        let angle = visualCursorAppKitForwardHeading(renderRotation: 0)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    // MARK: Debug output

    private func writeObservationSnapshot(tipPosition: CGPoint?, rotation: CGFloat?) {
        // Every frame: the path was captured with the request, no environment lookup here.
        guard let path = activeSettings.observationFilePath else { return }
        let snapshot = VisualCursorObservationSnapshot(
            phase: interactionIndicator?.phase ?? observationPhase,
            tipPosition: tipPosition,
            restingTipPosition: restingTipPosition,
            rotation: rotation,
            timestamp: CACurrentMediaTime()
        )
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            // Observation is debug-only and must not affect tool execution.
        }
    }

    /// OPEN_COMPUTER_USE_CURSOR_TRACE_FILE: one line per cursor event (move with its start and end,
    /// pulse, hide, reset), to check what the cursor did without watching the screen.
    private func trace(_ event: String) {
        guard let path = activeSettings.traceFilePath ?? VisualCursorSupport.settings.traceFilePath,
              let data = String(format: "%.3f pid=%d %@\n", CACurrentMediaTime(), ProcessInfo.processInfo.processIdentifier, event).data(using: .utf8)
        else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Geometry

    /// Keeps the tip on a display. Only the tip is clamped, to the display's full frame: keeping the whole
    /// 126 px panel inside the visible frame drew the cursor 40 to 70 px away from targets near an edge
    /// (traffic lights, sidebar toggles). The borderless panel may hang off-screen.
    private func clampTipPosition(_ tipPosition: CGPoint) -> CGPoint {
        guard let screen = screen(containing: tipPosition) ?? nearestScreen(to: tipPosition) else {
            return tipPosition
        }
        let frame = screen.frame.insetBy(dx: 1, dy: 1)
        return CGPoint(
            x: tipPosition.x.clamped(to: frame.minX...frame.maxX),
            y: tipPosition.y.clamped(to: frame.minY...frame.maxY)
        )
    }

    /// The display closest to a point that lies on none (a window partly off-screen, a gap between displays).
    private func nearestScreen(to point: CGPoint) -> NSScreen? {
        func distance(_ frame: CGRect) -> CGFloat {
            let dx = point.x - point.x.clamped(to: frame.minX...frame.maxX)
            let dy = point.y - point.y.clamped(to: frame.minY...frame.maxY)
            return hypot(dx, dy)
        }
        return NSScreen.screens.min { distance($0.frame) < distance($1.frame) } ?? NSScreen.main
    }

    /// Snapshot and live AX frames differ by sub-pixel rounding; that is not a move.
    private func framesNearlyEqual(_ a: CGRect, _ b: CGRect?) -> Bool {
        guard let b else { return false }
        return abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5
            && abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}



/// Routes cursor work to the calling agent's own cursor (see `CursorStage`) and hands the desktop
/// cursor between Godspeed processes.
@MainActor
enum SoftwareCursorOverlay {
    private static var stages: [String: CursorStage] = [:]
    private static var nextAgentOrdinal = 1

    static func stage(for client: String) -> CursorStage {
        if let stage = stages[client] { return stage }
        // Hidden cursors of agents that went away are dropped before a new one is made.
        if stages.count >= 8 {
            for (name, stage) in stages where name != "main" && !stage.isVisible { stage.shutdown(); stages[name] = nil }
        }
        let ordinal = nextAgentOrdinal
        if client != "main" { nextAgentOrdinal += 1 }
        let stage = CursorStage(client: client, fallbackName: ordinal == 1 ? "Agent" : "Agent \(ordinal)")
        stages[client] = stage
        return stage
    }

    private static var current: CursorStage { stage(for: VisualCursorSupport.cursorClient) }

    /// Creates the first cursor ahead of use (see `CursorStage.prewarm`). Safe to call when the cursor is off.
    static func prewarm() {
        guard VisualCursorSupport.isEnabled, !NSScreen.screens.isEmpty else { return }
        stage(for: "main").prewarm()
    }

    /// True while any agent's cursor has queued or playing work.
    static var isBusy: Bool { stages.values.contains { $0.isBusy } }

    static func moveCursor(to targetPoint: CGPoint, in targetWindow: CursorTargetWindow?, anchor: CursorRestingAnchor? = nil) {
        current.moveCursor(to: targetPoint, in: targetWindow, anchor: anchor)
    }

    static func pulseClick(
        at targetPoint: CGPoint, clickCount: Int, mouseButton: MouseButtonKind,
        in targetWindow: CursorTargetWindow?, anchor: CursorRestingAnchor? = nil
    ) {
        current.pulseClick(at: targetPoint, clickCount: clickCount, mouseButton: mouseButton, in: targetWindow, anchor: anchor)
    }

    static func settle(at targetPoint: CGPoint, in targetWindow: CursorTargetWindow?, anchor: CursorRestingAnchor? = nil) {
        current.settle(at: targetPoint, in: targetWindow, anchor: anchor)
    }

    static func beginFeedback(
        _ feedback: CursorInteractionFeedback, at targetPoint: CGPoint? = nil,
        in targetWindow: CursorTargetWindow? = nil, anchor: CursorRestingAnchor? = nil
    ) {
        current.beginFeedback(feedback, at: targetPoint, in: targetWindow, anchor: anchor)
    }

    static func endFeedback(
        _ feedback: CursorInteractionFeedback, at targetPoint: CGPoint? = nil,
        in targetWindow: CursorTargetWindow? = nil, anchor: CursorRestingAnchor? = nil
    ) {
        current.endFeedback(feedback, at: targetPoint, in: targetWindow, anchor: anchor)
    }

    static func cancelFeedback(_ feedback: CursorInteractionFeedback) {
        current.cancelFeedback(feedback)
    }

    static func scheduleHide(after delay: TimeInterval) { current.scheduleHide(after: delay) }

    static var hideTimer: Timer? { current.hideTimer }
    static var swayStopTimer: Timer? { current.swayStopTimer }
    static var overlayPanelForTesting: NSWindow? { current.overlayPanelForTesting }
    static var currentAgentNameForTesting: String? { current.currentAgentName }

    static func waitUntilIdleForTesting(timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while isBusy, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
        }
    }

    /// Every cursor, now.
    static func reset() {
        for stage in stages.values { stage.reset() }
    }

    /// End of a turn: every cursor fades out once its queued work has played.
    static func resetWhenIdle() {
        for stage in stages.values { stage.resetWhenIdle() }
    }

    /// A cursor that appears while another agent's cursor is on screen takes its own colour, so two agents
    /// working side by side can be told apart. Alone, a cursor keeps the standard artwork.
    static func tintForAppearingCursor(client: String) -> CursorColor? {
        let others = stages.values.filter { $0.client != client && $0.isVisible }
        guard !others.isEmpty else { return nil }
        let palette = ["#5C9CFA", "#C77BF2", "#35BA9A", "#F19A5B", "#E876A4", "#8CA965"]
        let taken = Set(others.compactMap { $0.currentTintHex })
        let start = client.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
        for offset in 0..<palette.count {
            let hex = palette[(start + offset) % palette.count]
            if !taken.contains(hex) { return CursorColor(hex: hex) }
        }
        return CursorColor(hex: palette[start])
    }

    static func nameForCursor(client: String, preferred: String) -> String {
        let taken = Set(stages.values.compactMap { stage -> String? in
            guard stage.client != client else { return nil }
            return stage.currentAgentName?.lowercased()
        })
        return availableCursorAgentName(preferred, taken: taken)
    }

    // MARK: Cross-process ownership

    private static let claimNotification: Notification.Name = {
        // Isolation is useful for smoke fixtures; normal sessions share one name.
        let namespace = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_CURSOR_NAMESPACE"] ?? ""
        return Notification.Name("com.michael.ocufast.cursor.claim" + (namespace.isEmpty ? "" : "." + namespace))
    }()
    private static var claimObserver: NSObjectProtocol?
    private static var latestClaimTime: CFTimeInterval = 0
    static var latestClaimPID: Int32 = 0

    /// Hand the desktop cursors to the latest active Godspeed process. Agents inside one app agent each keep their
    /// own cursor; a separate process (a direct CLI or a second app agent) takes over and this one's cursors go.
    static func claimDesktopCursor() {
        if claimObserver == nil {
            claimObserver = DistributedNotificationCenter.default().addObserver(
                forName: claimNotification, object: nil, queue: .main
            ) { notification in
                guard let time = notification.userInfo?["time"] as? Double,
                      let pid = notification.userInfo?["pid"] as? Int32 else { return }
                MainActor.assumeIsolated {
                    guard pid != ProcessInfo.processInfo.processIdentifier else { return }
                    guard time > latestClaimTime || (time == latestClaimTime && pid > latestClaimPID) else { return }
                    latestClaimTime = time
                    latestClaimPID = pid
                    reset()
                }
            }
        }
        let time = CACurrentMediaTime()
        let pid = ProcessInfo.processInfo.processIdentifier
        latestClaimTime = time
        latestClaimPID = pid
        DistributedNotificationCenter.default().postNotificationName(
            claimNotification, object: nil, userInfo: ["time": time, "pid": pid], deliverImmediately: true
        )
    }

    static func ownsCursor() -> Bool {
        if latestClaimPID == 0 { claimDesktopCursor() }
        return latestClaimPID == ProcessInfo.processInfo.processIdentifier
    }
}

/// The topmost on-screen normal-layer window of the frontmost app, from a window list in front-to-back order.
/// The cursor is ordered just below it when it has no target window of its own.
func cursorBehindWindowID(windowList: [[String: Any]], frontmostPID: pid_t) -> CGWindowID? {
    guard frontmostPID > 0 else { return nil }
    for window in windowList {
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              number != 0
        else {
            continue
        }
        return CGWindowID(number)
    }
    return nil
}

func shouldReorderCursorPanel(
    activeTargetWindow: CursorTargetWindow?,
    effectiveTargetWindow: CursorTargetWindow?,
    panelIsVisible: Bool,
    forceReorder: Bool
) -> Bool {
    forceReorder || activeTargetWindow != effectiveTargetWindow || panelIsVisible == false
}

private final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SoftwareCursorView: NSView {
    var rotation: CGFloat = 0
    var cursorBodyOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOpacity: CGFloat = 0.12
    var fogScale: CGFloat = 1
    var clickProgress: CGFloat = 0
    var ripple: CursorClickRipple?
    var indicator: CursorInteractionIndicator?
    var lensEnabled = false
    var agentName: String? {
        didSet {
            guard agentName != oldValue else { return }
            label = agentName.map(Self.agentLabel)
            labelWidth = ceil(label?.size().width ?? 0) + 14
            needsDisplay = true
        }
    }
    private var label: NSAttributedString?
    private var labelWidth: CGFloat = 0
    /// This cursor's colour; the glyph renderer's tint is shared, so it is set per draw.
    var tint: CursorColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        // The lens: a recent picture of the screen under this window, refreshed while the cursor is shown.
        SoftwareCursorGlyphRenderer.backdrop = nil
        if let window, window.isVisible, lensEnabled {
            let frame = window.convertToScreen(convert(bounds, to: nil))
            SoftwareCursorGlyphRenderer.backdrop = CursorBackdrop.shared.current(for: frame)
            CursorBackdrop.shared.refreshIfNeeded(windowFrame: frame, windowNumber: window.windowNumber) { [weak self] in
                DispatchQueue.main.async { self?.needsDisplay = true }
                // Look again a little later, so text that appears under a resting cursor shows through correctly.
                DispatchQueue.main.asyncAfter(deadline: .now() + CursorBackdrop.maxAge * 0.8) {
                    if self?.window?.isVisible == true { self?.needsDisplay = true }
                }
            }
        }

        SoftwareCursorGlyphRenderer.tint = tint
        SoftwareCursorGlyphRenderer.draw(
            in: bounds,
            context: context,
            state: SoftwareCursorGlyphRenderState(
                rotation: rotation,
                cursorBodyOffset: cursorBodyOffset,
                fogOffset: fogOffset,
                fogOpacity: fogOpacity,
                fogScale: fogScale,
                clickProgress: clickProgress
            ),
            ripple: ripple,
            indicator: indicator
        )
        drawAgentLabel()
    }

    private static func agentLabel(_ name: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
    }

    private func drawAgentLabel() {
        guard let label else { return }
        let tip = SoftwareCursorGlyphMetrics.tipAnchor
        let padding: CGFloat = 7
        var available = bounds.insetBy(dx: 4, dy: 0)
        if let window, let screen = window.screen, let contentRect = window.contentView?.bounds {
            let onScreen = window.convertToScreen(contentRect)
            let localScreen = screen.frame.offsetBy(dx: -onScreen.minX, dy: -onScreen.minY)
            available = available.intersection(localScreen.insetBy(dx: 2, dy: 2))
        }
        let width = min(labelWidth, available.width)
        guard width > padding * 2 else { return }
        let x = min(max(tip.x - width / 2, available.minX), available.maxX - width)
        let y = tip.y - 40 >= available.minY ? tip.y - 40 : tip.y + 9
        let frame = CGRect(x: x, y: y, width: width, height: 19)
        let background = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        NSColor(white: 0.085, alpha: 0.93).setFill()
        background.fill()
        NSColor(white: 1, alpha: 0.24).setStroke()
        background.lineWidth = 1
        background.stroke()
        label.draw(in: frame.insetBy(dx: padding, dy: 2))
    }
}

extension CursorColor {
    /// "#RRGGBB", as the cursor palette spells it.
    var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
