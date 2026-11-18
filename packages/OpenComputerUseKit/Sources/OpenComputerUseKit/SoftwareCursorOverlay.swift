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

    public static var isEnabled: Bool { settings.enabled }

    /// Every cursor setting for the current request. The app agent applies a caller's
    /// OPEN_COMPUTER_USE_* variables only while that request runs, and queued animations
    /// play after it returned, so they must use the values captured when they were queued.
    static var settings: VisualCursorSettings {
        if let snapshot = Thread.current.threadDictionary[settingsSnapshotKey] as? VisualCursorSettings {
            return snapshot
        }
        // PURE's Settings > GODSPEED fill in whatever the environment does not set.
        var settings = VisualCursorSettings(environment: GodspeedSettings.merged(ProcessInfo.processInfo.environment))
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

    @MainActor private static var pendingAnimations: [(kind: AnimationKind, body: @MainActor () -> Void)] = []
    @MainActor private static var isDrainingAnimations = false
    /// A reset asked for by another process or a finished turn while animations play. Resetting then aborted
    /// the glide and the cursor vanished mid-batch, so it waits until the queue is empty.
    @MainActor static var deferredReset = false
    @MainActor static var isAnimating: Bool { isDrainingAnimations || !pendingAnimations.isEmpty }

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
        let perform: @MainActor () -> Void = {
            let dictionary = Thread.current.threadDictionary
            let previous = dictionary[settingsSnapshotKey]
            dictionary[settingsSnapshotKey] = captured
            defer {
                if let previous { dictionary[settingsSnapshotKey] = previous }
                else { dictionary.removeObject(forKey: settingsSnapshotKey) }
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
                pendingAnimations.append((kind, perform))
                // The animation pumps the main run loop. A nested queue callback
                // must enqueue its work, not interrupt the animation in progress.
                guard !isDrainingAnimations else { return }
                isDrainingAnimations = true
                defer { isDrainingAnimations = false }
                while !pendingAnimations.isEmpty {
                    let next = pendingAnimations.removeFirst()
                    backlogLock.lock(); backlog -= 1; backlogLock.unlock()
                    // Coalesce consecutive moves. A pulse or settle is a boundary: dropping a
                    // move across one would make that click jump to its target instead of gliding.
                    if next.kind == .move, pendingAnimations.first?.kind == .move { continue }
                    next.body()
                }
                if deferredReset {
                    deferredReset = false
                    SoftwareCursorOverlay.reset()
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

    init(environment: [String: String]) {
        color = CursorColor(hex: environment["OPEN_COMPUTER_USE_CURSOR_COLOR"])
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

/// Seconds one move takes at playback rate `speed`. At 1x a short hop takes 60 ms and the time rises gently with
/// distance to at most 140 ms across a whole screen, so the eye can follow it without waiting for it.
/// Returns 0 (place directly) for instant speed or when the result would be under one frame.
func visualCursorTravelDuration(distance: CGFloat, speed: CGFloat, queuedBehind: Int = 0) -> TimeInterval {
    guard speed.isFinite, speed > 0, distance.isFinite, distance > 0 else { return 0 }
    let base = 0.06 + 0.08 * (1 - exp(-Double(distance) / 500))
    let duration = base / Double(speed) * visualCursorCatchUpFactor(queuedBehind: queuedBehind)
    return duration < visualCursorMinimumAnimatedDuration ? 0 : duration
}

/// Seconds one click pulse takes at `speed` (90 ms at 1x). 0 means skip the pulse.
func visualCursorClickPulseDuration(speed: CGFloat, queuedBehind: Int = 0) -> TimeInterval {
    guard speed.isFinite, speed > 0 else { return 0 }
    let duration = 0.09 / Double(speed) * visualCursorCatchUpFactor(queuedBehind: queuedBehind)
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

@MainActor
enum SoftwareCursorOverlay {
    private static let artwork = CursorArtwork.active
    private static let renderBaseHeading = visualCursorRenderBaseHeading()
    private static let renderYAxisMultiplier = visualCursorRuntimeRenderYAxisMultiplier()
    private static var panel: CursorPanel?
    private static var cursorView: SoftwareCursorView?
    private static var restingTipPosition: CGPoint?
    private static var displayedTipPosition: CGPoint?
    private static var activeTargetWindow: CursorTargetWindow?
    /// Window frame the current target point was derived from; lets a move
    /// under the cursor be detected and re-derived instead of ignored.
    private static var restingAnchor: CursorRestingAnchor?
    private static var lastAnchorFrame: CGRect?
    private static var visualDynamicsState: CursorVisualDynamicsState?
    private static var idleTimer: Timer?
    /// Checks the target window between moves, so a window that closes while the cursor
    /// rests is noticed within a tenth of a second instead of at the fallback hide.
    private static var watchTimer: Timer?
    private static var fadeTimer: Timer?
    private static var feedbackTimer: Timer?
    private static var interactionIndicator: CursorInteractionIndicator?
    /// Internal (not private) so CursorHideTimerTests can assert scheduling order.
    static var swayStopTimer: Timer?
    static var hideTimer: Timer?
    private static var idlePhase: CGFloat = 0
    private static var idleTicks = 0
    private static var observationPhase = "hidden"
    /// Settings of the request that last drove the cursor. Timers fire after that request
    /// returned, when the process environment no longer holds its values.
    private static var activeSettings = VisualCursorSettings(environment: [:])

    private static func adoptRequestSettings() {
        activeSettings = VisualCursorSupport.settings
        SoftwareCursorGlyphRenderer.tint = activeSettings.color
        cursorView?.lensEnabled = activeSettings.lensEnabled
    }
    private static let claimNotification: Notification.Name = {
        // Isolation is useful for smoke fixtures; normal sessions share one name.
        let namespace = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_CURSOR_NAMESPACE"] ?? ""
        return Notification.Name("com.michael.ocufast.cursor.claim" + (namespace.isEmpty ? "" : "." + namespace))
    }()
    private static var claimObserver: NSObjectProtocol?
    private static var latestClaimTime: CFTimeInterval = 0
    private static var latestClaimPID: Int32 = 0

    /// Hand the shared desktop cursor to the latest active OCU process. Each
    /// process owns a separate panel, so hiding only the local one is not enough.
    private static func claimDesktopCursor() {
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
                    resetWhenIdle()
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
    // Pulse/settle belong to a preceding move. If another process took over
    // while that move was animating, queued work from the older action must not
    // reclaim the cursor. Direct standalone calls may establish the first claim.
    private static func continueOwnedCursor() -> Bool {
        if latestClaimPID == 0 { claimDesktopCursor() }
        return latestClaimPID == ProcessInfo.processInfo.processIdentifier
    }

    /// Bumped by every action that shows the cursor. A hide fade that started
    /// before an action must not wipe the newer action's state when it completes.
    private static var interactionGeneration = 0

    /// Stops an in-flight hide fade when a new action takes the cursor over.
    private static func takeOverFromFade() {
        interactionGeneration += 1
        endFade()
        panel?.alphaValue = 1
    }

    /// Stops the hide fade timer, if one is running. The fade is driven by this timer, so
    /// invalidating it is the only cancel needed; nothing is left ticking.
    private static func endFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    static func moveCursor(
        to targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        adoptRequestSettings()
        if interactionIndicator != CursorInteractionIndicator(feedback: .drag) {
            clearFeedback()
        }
        // A reset that was waiting for the queue to empty belongs to the turn before this action.
        VisualCursorSupport.deferredReset = false
        // Claim only when another process holds the cursor (or none is shown). Re-claiming on every
        // move reset another OCU process mid-glide each time, so two agents made the cursor flicker.
        if latestClaimPID != ProcessInfo.processInfo.processIdentifier || displayedTipPosition == nil {
            claimDesktopCursor()
        }
        prepareWindowIfNeeded()
        takeOverFromFade()
        stopIdleAnimation()
        cancelPendingHide()
        // A move alone must still own a disappearance: if the pipeline throws
        // before any settle or pulse is queued, nothing else schedules the hide.
        // Long enough that a slow action (a busy app, a dialog) finishes first; the pulse or settle that
        // follows sets the normal delay. The plain delay hid the cursor mid-action, then it popped back.
        scheduleHide(after: max(activeSettings.idleHideDelay, 12))

        adoptAnchor(anchor)
        lastAnchorFrame = anchor.flatMap { CursorWindowFrameTracker.liveFrame(for: $0.windowID) } ?? anchor?.windowBounds
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let isFreshStart = displayedTipPosition == nil
        // A cursor that is already on screen continues from where the last action left it. One
        // that is not appears a short step from the target, never in a screen corner.
        let startPoint = displayedTipPosition
            ?? clampTipPosition(visualCursorFreshStartPoint(target: constrainedTarget, forward: restingForwardVector()))
        let now = CACurrentMediaTime()
        let travel = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : visualCursorTravelDuration(
            distance: distanceBetween(startPoint, constrainedTarget),
            speed: activeSettings.speed,
            // A click queues its own pulse behind its move; only later actions count as backlog.
            queuedBehind: VisualCursorSupport.queuedAnimations - 1
        )
        trace("move from=(\(Int(startPoint.x)),\(Int(startPoint.y))) to=(\(Int(constrainedTarget.x)),\(Int(constrainedTarget.y))) fresh=\(isFreshStart) ms=\(Int(travel * 1000)) panel=\(panel?.windowNumber ?? -1)")

        observationPhase = "moving"
        guard travel > 0 else {
            // Instant speed, or nothing visible to animate: draw the cursor on the target.
            visualDynamicsState = CursorVisualDynamicsAnimator.state(at: constrainedTarget, time: CGFloat(now))
            placeCursor(using: initialRenderState(at: constrainedTarget), clickProgress: 0)
            panel?.alphaValue = 1
            configureOrdering(relativeTo: targetWindow)
            startWindowWatch()
            return
        }

        // Position the panel before it is ordered in, so it never shows at a stale place.
        panel?.alphaValue = isFreshStart ? 0 : 1
        if isFreshStart {
            visualDynamicsState = CursorVisualDynamicsAnimator.state(at: startPoint, time: CGFloat(now))
            placeCursor(using: initialRenderState(at: startPoint), clickProgress: 0)
        } else {
            seedVisualDynamicsIfNeeded(at: startPoint, time: now)
            placeCursor(
                using: advanceVisualDynamics(
                    toward: startPoint,
                    at: now
                ),
                clickProgress: 0
            )
        }

        configureOrdering(relativeTo: targetWindow)

        if distanceBetween(startPoint, constrainedTarget) > 2 {
            animateMove(from: startPoint, to: constrainedTarget, relativeTo: targetWindow, duration: travel, fadeIn: isFreshStart)
        }
        panel?.alphaValue = 1
        startWindowWatch()
    }

    static func pulseClick(
        at targetPoint: CGPoint,
        clickCount: Int,
        mouseButton: MouseButtonKind,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        guard continueOwnedCursor() else { return }
        adoptRequestSettings()
        clearFeedback()
        placeOnTargetIfNeeded(targetPoint, anchor: anchor)
        configureOrdering(relativeTo: targetWindow)
        takeOverFromFade()
        // A hide scheduled by an earlier action must not fire mid-click (it would abort the pulse).
        cancelPendingHide()
        let pulseGeneration = interactionGeneration
        stopIdleAnimation()
        adoptAnchor(anchor)
        _ = reanchorIfWindowMoved()
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let now = CACurrentMediaTime()
        seedVisualDynamicsIfNeeded(at: constrainedTarget, time: now)
        restingTipPosition = constrainedTarget
        observationPhase = "pulse"
        animateClickPulse(at: constrainedTarget, clickCount: max(clickCount, 1), mouseButton: mouseButton)
        guard pulseGeneration == interactionGeneration else { return }
        resumeIdleFeedback()
    }

    static func beginFeedback(
        _ feedback: CursorInteractionFeedback,
        at targetPoint: CGPoint? = nil,
        in targetWindow: CursorTargetWindow? = nil,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay,
              let point = targetPoint ?? displayedTipPosition, continueOwnedCursor() else { return }

        adoptRequestSettings()
        clearFeedback()
        takeOverFromFade()
        stopIdleAnimation()
        cancelPendingHide()
        if targetPoint != nil {
            adoptAnchor(anchor)
            prepareWindowIfNeeded()
        }
        interactionIndicator = CursorInteractionIndicator(feedback: feedback)
        drawFeedback(at: clampTipPosition(liveTargetPoint(point, anchor: anchor)))
        if targetPoint != nil {
            configureOrdering(relativeTo: targetWindow)
        }
        startWindowWatch()
        // Recover if an interrupted operation never queues its completion.
        scheduleHide(after: max(activeSettings.idleHideDelay, 12))
    }

    static func endFeedback(
        _ feedback: CursorInteractionFeedback,
        at targetPoint: CGPoint? = nil,
        in targetWindow: CursorTargetWindow? = nil,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled,
              interactionIndicator == CursorInteractionIndicator(feedback: feedback),
              continueOwnedCursor(), let point = targetPoint ?? displayedTipPosition else { return }

        cancelPendingHide()
        if targetPoint != nil {
            adoptAnchor(anchor)
        }
        interactionIndicator?.isCompleted = true
        drawFeedback(at: clampTipPosition(liveTargetPoint(point, anchor: anchor)))
        if targetPoint != nil {
            configureOrdering(relativeTo: targetWindow)
        }
        startWindowWatch()

        let timer = Timer(timeInterval: feedback.completionDuration, repeats: false) { _ in
            MainActor.assumeIsolated {
                clearFeedback()
                observationPhase = "settling"
                if let restingTipPosition {
                    drawFeedback(at: restingTipPosition)
                }
                resumeIdleFeedback()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        feedbackTimer = timer
    }

    static func cancelFeedback(_ feedback: CursorInteractionFeedback) {
        guard VisualCursorSupport.isEnabled,
              interactionIndicator == CursorInteractionIndicator(feedback: feedback),
              continueOwnedCursor() else { return }
        clearFeedback()
        observationPhase = "settling"
        if let displayedTipPosition {
            drawFeedback(at: displayedTipPosition)
        }
        resumeIdleFeedback()
    }

    private static func drawFeedback(at point: CGPoint) {
        restingTipPosition = point
        visualDynamicsState = CursorVisualDynamicsAnimator.state(at: point, time: CGFloat(CACurrentMediaTime()))
        placeCursor(using: initialRenderState(at: point), clickProgress: 0)
    }

    private static func clearFeedback() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        interactionIndicator = nil
        cursorView?.indicator = nil
    }

    private static func resumeIdleFeedback() {
        startIdleAnimation()
        if idleTimer == nil { startWindowWatch() }
        scheduleHide(after: activeSettings.idleHideDelay)
        scheduleSwayStop()
    }

    static func settle(
        at targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        guard continueOwnedCursor() else { return }
        adoptRequestSettings()
        placeOnTargetIfNeeded(targetPoint, anchor: anchor)
        configureOrdering(relativeTo: targetWindow)
        takeOverFromFade()
        adoptAnchor(anchor)
        _ = reanchorIfWindowMoved()
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        restingTipPosition = constrainedTarget
        observationPhase = "settling"
        placeCursor(
            using: advanceVisualDynamics(
                toward: constrainedTarget,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
        if interactionIndicator == nil {
            cancelPendingHide()
            resumeIdleFeedback()
        }
    }

    /// A pulse or settle whose cursor is hidden (idle hide, reset) or still far from the target (its move
    /// was skipped for a later one) is drawn on the target first, so ordering in never flashes it at an old
    /// place and the ring never plays mid-leap.
    private static func placeOnTargetIfNeeded(_ targetPoint: CGPoint, anchor: CursorRestingAnchor?) {
        prepareWindowIfNeeded()
        let target = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let hidden = displayedTipPosition == nil || panel?.isVisible != true
        let far = displayedTipPosition.map { distanceBetween($0, target) > 24 } ?? true
        guard hidden || far else { return }
        visualDynamicsState = CursorVisualDynamicsAnimator.state(at: target, time: CGFloat(CACurrentMediaTime()))
        placeCursor(using: initialRenderState(at: target), clickProgress: 0)
        panel?.alphaValue = 1
    }

    /// The overlay window, exposed for tests that must observe presentation state.
    static var overlayPanelForTesting: NSWindow? { panel }

    /// Reset now, or once the queued animations have played (see `VisualCursorSupport.deferredReset`).
    static func resetWhenIdle() {
        if VisualCursorSupport.isAnimating {
            VisualCursorSupport.deferredReset = true
        } else {
            reset()
        }
    }

    static func reset() {
        if panel?.isVisible == true { trace("reset") }
        takeOverFromFade()
        stopIdleAnimation()
        clearFeedback()
        swayStopTimer?.invalidate()
        swayStopTimer = nil
        cancelPendingHide()
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        restingAnchor = nil
        lastAnchorFrame = nil
        CursorWindowFrameTracker.forgetAll()
        visualDynamicsState = nil
        cursorView?.rotation = 0
        observationPhase = "hidden"
        writeObservationSnapshot(tipPosition: nil, rotation: nil)
        panel?.orderOut(nil)
    }

    /// Re-derive a target point that was computed from a snapshot taken before
    /// the window moved. Element frames are window-relative, so the anchored
    /// point follows the window instead of staying on the display it just left.
    private static func liveTargetPoint(_ targetPoint: CGPoint, anchor: CursorRestingAnchor?) -> CGPoint {
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

    private static func adoptAnchor(_ anchor: CursorRestingAnchor?) {
        // Register this anchor's own window now, when its animation runs. Registering when the
        // action was queued let a later action in a batch swap the source before this one played.
        if let anchor, let source = anchor.frameSource {
            CursorWindowFrameTracker.register(windowID: anchor.windowID, element: source.element)
        }
        if restingAnchor != anchor {
            restingAnchor = anchor
            lastAnchorFrame = anchor?.windowBounds
        }
        // An unanchored action no longer clears the frame source: a queued anchored action after it
        // still needs it. reset() and the hide path clear it.
    }

    /// The anchored target re-derived from the window's live frame, when the window moved since the
    /// last look. Updates the remembered frame and resting tip; does not draw.
    private static func movedAnchorTarget() -> CGPoint? {
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

    /// Relocate the visible tip, not just its spring target. Otherwise an old
    /// travel velocity can leave it on the previous display after reanchoring.
    @discardableResult
    private static func reanchorIfWindowMoved() -> Bool {
        guard let constrainedTarget = movedAnchorTarget() else {
            return false
        }

        visualDynamicsState = CursorVisualDynamicsAnimator.state(at: constrainedTarget, time: CGFloat(CACurrentMediaTime()))
        observationPhase = "reanchored"
        placeCursor(
            using: initialRenderState(at: constrainedTarget),
            clickProgress: 0
        )
        return true
    }

    private static var canPresentOverlay: Bool {
        !NSScreen.screens.isEmpty
    }

    private static func prepareWindowIfNeeded() {
        guard panel == nil else {
            return
        }

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
        self.cursorView = view
    }

    private static func configureOrdering(relativeTo targetWindow: CursorTargetWindow?) {
        configureOrdering(relativeTo: targetWindow, forceReorder: false)
    }

    private static func configureOrdering(relativeTo targetWindow: CursorTargetWindow?, forceReorder: Bool) {
        guard let panel else {
            return
        }

        let effectiveTargetWindow = targetWindow.flatMap { targetWindow in
            isWindowPresent(targetWindow.windowID) ? targetWindow : nil
        }

        // OPEN_COMPUTER_USE_CURSOR_FLOAT=1: draw above every window, so the cursor is visible even when
        // the app it drives sits behind other windows (background control). Click-through either way.
        if activeSettings.floats {
            if panel.level != .floating { panel.level = .floating }
            if !panel.isVisible || forceReorder { panel.orderFrontRegardless() }
            activeTargetWindow = effectiveTargetWindow
            return
        }

        let desiredLevel = NSWindow.Level(rawValue: effectiveTargetWindow?.layer ?? 0)
        if panel.level != desiredLevel {
            panel.level = desiredLevel
        }

        if shouldReorderCursorPanel(
            activeTargetWindow: activeTargetWindow,
            effectiveTargetWindow: effectiveTargetWindow,
            panelIsVisible: panel.isVisible,
            forceReorder: forceReorder
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

    private static func animateMove(
        from start: CGPoint,
        to initialEnd: CGPoint,
        relativeTo targetWindow: CursorTargetWindow?,
        duration: TimeInterval,
        fadeIn: Bool
    ) {
        // A window that is still opening, resizing or moving changes frame during the glide. The glide
        // keeps going and bends toward the window's new position (at most every 100 ms) instead of
        // stopping and jumping the tip there.
        var end = initialEnd
        var endShift = CGPoint.zero
        var nextRetarget: TimeInterval = 0
        let dragging = interactionIndicator == CursorInteractionIndicator(feedback: .drag)
        // The generated mouse drag travels directly between the two event points.
        let path = dragging ? CursorMotionPath(start: start, end: end, curveScale: 0)
            : bestMotionCandidate(from: start, to: end, relativeTo: targetWindow).path
        // The path point follows the recovered official progress spring, compressed into the first
        // part of the move; the rest of the time lets the drawn tip land on the target, so the
        // whole move takes `duration` and the click pulse starts on a cursor that has arrived.
        let pathDuration = CGFloat(duration) * 0.72
        let landingDeadline = duration + 0.03
        let springTargetDuration = OfficialCursorMotionModel.closeEnoughTime
        let generation = interactionGeneration
        let startTime = CACurrentMediaTime()
        var progress: CGFloat = 0
        var springState = CursorMotionSpringState()
        // Ordering is three window-server round trips; doing it every frame made the
        // travel stutter. 50 ms is fast enough to stay above a target window that
        // gets raised mid-flight, matching the idle timer's refresh cadence.
        var nextOrderRefresh = startTime + 0.05

        while true {
            guard generation == interactionGeneration else { return }
            let now = CACurrentMediaTime()
            if now >= nextOrderRefresh {
                refreshActiveOrderingIfNeeded()
                nextOrderRefresh = now + 0.05
                // The window was gone and the cursor is fading out: stop placing the tip.
                guard generation == interactionGeneration else { return }
            }

            if now >= nextRetarget {
                nextRetarget = now + 0.1
                if let moved = movedAnchorTarget() {
                    endShift = CGPoint(x: endShift.x + moved.x - end.x, y: endShift.y + moved.y - end.y)
                    end = moved
                    observationPhase = "retargeted"
                }
            }

            let elapsed = CGFloat(CACurrentMediaTime() - startTime)
            let normalizedElapsed = (elapsed / max(pathDuration, 0.001)).clamped(to: 0...1)
            let springTime = normalizedElapsed * springTargetDuration
            (progress, springState) = CursorMotionProgressAnimator.advance(
                current: progress,
                state: springState,
                to: springTime
            )

            let pathDone = normalizedElapsed >= 1 || CursorMotionProgressAnimator.isCloseEnough(progress: progress)
            let sample = path.sample(at: progress)
            // The path was planned to the original end; shift it by how far the window moved,
            // more as the glide progresses, so it lands on the window's current position.
            let pathPoint = CGPoint(x: sample.point.x + endShift.x * progress, y: sample.point.y + endShift.y * progress)
            let renderState = advanceVisualDynamics(
                toward: pathDone ? end : pathPoint,
                at: CACurrentMediaTime()
            )
            placeCursor(using: renderState, clickProgress: 0)
            if fadeIn {
                panel?.alphaValue = min(1, normalizedElapsed * 2.5)
            }

            if pathDone,
               distanceBetween(renderState.tipPosition, end) < 0.75 || TimeInterval(elapsed) >= landingDeadline {
                break
            }

            pumpFrame()
        }

        panel?.alphaValue = 1
        placeCursor(
            using: advanceVisualDynamics(
                toward: end,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private static func bestMotionCandidate(from start: CGPoint, to end: CGPoint, relativeTo targetWindow: CursorTargetWindow?) -> CursorMotionCandidate {
        let bounds = motionBounds(from: start, to: end)
        let candidates = HeadingDrivenCursorMotionModel.makeCandidates(
            start: start,
            end: end,
            bounds: bounds,
            startForward: currentForwardVector(),
            endForward: restingForwardVector()
        )
        let defaultCandidate = HeadingDrivenCursorMotionModel.chooseBestCandidate(from: candidates)
            ?? CursorMotionCandidate(
                identifier: "legacy-fallback",
                kind: .base,
                side: 0,
                tableAScale: nil,
                tableBScale: nil,
                path: CursorMotionPath(start: start, end: end),
                measurement: CursorMotionPath(start: start, end: end).measure(bounds: bounds),
                score: 0
            )

        guard let targetWindow else {
            return defaultCandidate
        }

        let excludingWindowNumber = max(panel?.windowNumber ?? 0, 0)
        let evaluations = candidates.map { candidate in
            (
                candidate: candidate,
                hitCount: windowConstraintHitCount(
                    for: candidate.path,
                    relativeTo: targetWindow,
                    excludingWindowNumber: excludingWindowNumber
                )
            )
        }

        let totalSampleCount = candidates.first?.path.sampledConstraintPoints().count ?? 0
        let bestHitCount = evaluations.map(\.hitCount).max() ?? 0

        if bestHitCount == totalSampleCount, bestHitCount > 0 {
            return evaluations
                .filter { $0.hitCount == bestHitCount }
                .map(\.candidate)
                .sorted(by: candidatePreference)
                .first ?? defaultCandidate
        }

        if bestHitCount > 0 {
            return evaluations
                .filter { $0.hitCount == bestHitCount }
                .map(\.candidate)
                .sorted(by: candidatePreference)
                .first ?? defaultCandidate
        }

        return defaultCandidate
    }

    private static func currentForwardVector() -> CGVector {
        let renderRotation = cursorView?.rotation ?? 0
        return forwardVector(renderRotation: renderRotation)
    }

    private static func restingForwardVector() -> CGVector {
        forwardVector(renderRotation: 0)
    }

    private static func forwardVector(renderRotation: CGFloat) -> CGVector {
        let angle = visualCursorAppKitForwardHeading(renderRotation: renderRotation)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    private static func windowConstraintHitCount(
        for path: CursorMotionPath,
        relativeTo targetWindow: CursorTargetWindow,
        excludingWindowNumber: Int
    ) -> Int {
        path.sampledConstraintPoints().reduce(into: 0) { result, point in
            if windowID(at: point, excludingWindowNumber: excludingWindowNumber) == targetWindow.windowID {
                result += 1
            }
        }
    }

    private static func motionBounds(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let startScreen = screen(containing: start) ?? NSScreen.main ?? NSScreen.screens.first
        let endScreen = screen(containing: end) ?? startScreen

        switch (startScreen, endScreen) {
        case let (startScreen?, endScreen?) where startScreen === endScreen:
            return startScreen.visibleFrame
        case let (startScreen?, endScreen?):
            return startScreen.visibleFrame.union(endScreen.visibleFrame)
        case let (screen?, nil), let (nil, screen?):
            return screen.visibleFrame
        default:
            return nil
        }
    }

    private static func candidatePreference(_ lhs: CursorMotionCandidate, _ rhs: CursorMotionCandidate) -> Bool {
        if lhs.measurement.staysInBounds != rhs.measurement.staysInBounds {
            return lhs.measurement.staysInBounds && !rhs.measurement.staysInBounds
        }
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        return lhs.identifier < rhs.identifier
    }

    private static func windowID(at point: CGPoint, excludingWindowNumber: Int) -> CGWindowID? {
        let windowNumber = NSWindow.windowNumber(
            at: NSPoint(x: point.x, y: point.y),
            belowWindowWithWindowNumber: excludingWindowNumber
        )

        guard windowNumber > 0 else {
            return nil
        }

        return CGWindowID(windowNumber)
    }

    private static func isWindowPresent(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        else {
            return false
        }

        return !windowInfo.isEmpty
    }

    private static func refreshActiveOrderingIfNeeded() {
        guard let activeTargetWindow else {
            return
        }

        // On screen, not merely listed: a window moved to another Space or minimized is still listed,
        // and the cursor would float over the desktop the user is on.
        if isWindowOnScreen(activeTargetWindow.windowID) {
            configureOrdering(relativeTo: activeTargetWindow, forceReorder: true)
            return
        }

        // The window the cursor pointed at is gone (dialog closed, app went away, left this Space).
        // Left alone, the cursor drifts over the desktop, so fade it out.
        hideOverlay()
    }

    private static func isWindowOnScreen(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = windowInfo.first
        else {
            return false
        }
        return info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Starts the window check that runs between moves (no idle sway or click ring is running).
    /// Only while the cursor is visible and a target is set; a hide in progress owns the cursor.
    private static func startWindowWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
        guard activeTargetWindow != nil, panel?.isVisible == true, fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard panel?.isVisible == true, activeTargetWindow != nil else {
                    watchTimer?.invalidate()
                    watchTimer = nil
                    return
                }
                refreshActiveOrderingIfNeeded()
                if fadeTimer == nil, panel?.isVisible == true {
                    _ = reanchorIfWindowMoved()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private static func animateClickPulse(at point: CGPoint, clickCount: Int, mouseButton: MouseButtonKind) {
        let generation = interactionGeneration
        let pulseBias: CGFloat = mouseButton == .right ? 0.82 : 1
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let duration = visualCursorClickPulseDuration(
            speed: activeSettings.speed,
            queuedBehind: VisualCursorSupport.queuedAnimations
        )
        trace("pulse at=(\(Int(point.x)),\(Int(point.y))) count=\(clickCount) ms=\(Int(duration * 1000))")

        // Keep visual feedback bounded even if a caller requests a long multi-click.
        let visibleClicks = min(clickCount, 2)
        for pulse in 0..<visibleClicks where duration > 0 {
            let startTime = CACurrentMediaTime()

            while true {
                guard generation == interactionGeneration else { return }
                _ = reanchorIfWindowMoved()
                let elapsed = CACurrentMediaTime() - startTime
                let rawProgress = min(max(elapsed / duration, 0), 1)
                let clickProgress = sin(rawProgress * .pi) * pulseBias

                placeCursor(
                    using: advanceVisualDynamics(
                        toward: restingTipPosition ?? point,
                        at: CACurrentMediaTime()
                    ),
                    clickProgress: reducesMotion ? 0 : clickProgress,
                    ripple: CursorClickRipple(
                        progress: rawProgress,
                        strength: pulseBias,
                        reducesMotion: reducesMotion,
                        isSecondary: mouseButton == .right
                    )
                )

                if rawProgress >= 1 {
                    break
                }

                pumpFrame()
            }

            if pulse < visibleClicks - 1 {
                pause(for: duration * 0.3)
            }
        }

        guard generation == interactionGeneration else { return }
        placeCursor(
            using: advanceVisualDynamics(
                toward: restingTipPosition ?? point,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private static func startIdleAnimation() {
        stopIdleAnimation()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard canPresentOverlay, let restingTipPosition else {
            return
        }

        observationPhase = "idle"
        idlePhase = 0
        idleTicks = 0
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard panel != nil, cursorView != nil else {
                    return
                }

                // A refresh is three window-server round trips; every frame they were most of
                // the sway's cost. At 10 Hz the cursor is back above a raised target window
                // within 0.1 s.
                idleTicks += 1
                if idleTicks % 6 == 0 {
                    refreshActiveOrderingIfNeeded()
                }
                _ = reanchorIfWindowMoved()
                guard let currentTipPosition = self.restingTipPosition else { return }

                observationPhase = "idle"
                idlePhase += 0.05
                let idlePose = visualCursorIdlePose(
                    restingTipPosition: currentTipPosition,
                    phase: idlePhase
                )

                placeCursor(
                    using: advanceVisualDynamics(
                        toward: idlePose.tipPosition,
                        idleAngleOffset: idlePose.angleOffset,
                        at: CACurrentMediaTime()
                    ),
                    clickProgress: 0
                )
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer

        placeCursor(
            using: advanceVisualDynamics(
                toward: restingTipPosition,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private static func stopIdleAnimation() {
        idleTimer?.invalidate()
        idleTimer = nil
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private static func scheduleSwayStop() {
        swayStopTimer?.invalidate()
        swayStopTimer = nil
        let timer = Timer(timeInterval: visualCursorIdleSwayTimeout(), repeats: false) { _ in
            MainActor.assumeIsolated {
                // Stop the jiggle early; the hide timer still owns disappearance.
                if idleTimer != nil {
                    stopIdleAnimation()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        swayStopTimer = timer
    }

    static func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = nil
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                hideOverlay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private static func cancelPendingHide() {
        hideTimer?.invalidate()
        hideTimer = nil
        swayStopTimer?.invalidate()
        swayStopTimer = nil
    }

    private static func hideOverlay() {
        guard let panel else {
            return
        }

        stopIdleAnimation()
        cancelPendingHide()
        clearFeedback()
        // A fade already running owns the hide. A second fade would fight it frame by frame, and the
        // window check calls this every 50 ms while its window is gone.
        guard fadeTimer == nil else { return }
        // Abort a move or click pulse still in flight: its window is gone or the hide is due, and its
        // loop would keep placing the tip over the desktop, then clear state under itself.
        interactionGeneration += 1
        let generationAtHide = interactionGeneration
        trace("hide")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishHide(panel)
            return
        }

        // Manual fade (12 eased 10 ms steps) driven by a timer, not a sleep: the
        // Animator API leaves no cancel handle, and sleeping here would stall the
        // queued animation blocks for the whole fade. Timer ticks interleave with
        // them, and takeOverFromFade ends the fade the moment an action takes the
        // cursor over. 10 ms steps keep the fade smooth at 60 Hz.
        let steps = 12
        var step = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard interactionGeneration == generationAtHide else {
                    endFade()
                    panel.alphaValue = 1
                    return
                }
                step += 1
                if step > steps {
                    finishHide(panel)
                    return
                }
                let t = CGFloat(step) / CGFloat(steps)
                panel.alphaValue = 1 - (t * t * (3 - 2 * t)) // smoothstep, eased in and out
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private static func finishHide(_ panel: CursorPanel) {
        endFade()
        panel.orderOut(nil)
        panel.alphaValue = 1
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        restingAnchor = nil
        lastAnchorFrame = nil
        CursorWindowFrameTracker.forgetAll()
        visualDynamicsState = nil
        // The next fresh start reads the glyph's heading; a stale turn from the last session would bend it.
        cursorView?.rotation = 0
        observationPhase = "hidden"
        writeObservationSnapshot(tipPosition: nil, rotation: nil)
    }

    private static func initialRenderState(at tipPosition: CGPoint) -> CursorVisualRenderState {
        CursorVisualRenderState(
            tipPosition: tipPosition,
            rotation: 0,
            cursorBodyOffset: CGVector(dx: 0, dy: 0),
            fogOffset: CGVector(dx: 0, dy: 0),
            fogOpacity: CursorVisualDynamicsConfiguration.officialInspired.fogOpacityBase,
            fogScale: 1
        )
    }

    private static func seedVisualDynamicsIfNeeded(at tipPosition: CGPoint, time: CFTimeInterval) {
        guard visualDynamicsState == nil else {
            return
        }

        visualDynamicsState = CursorVisualDynamicsAnimator.state(
            at: tipPosition,
            time: CGFloat(time)
        )
    }

    private static func advanceVisualDynamics(
        toward targetTipPosition: CGPoint,
        idleAngleOffset: CGFloat = 0,
        at time: CFTimeInterval
    ) -> CursorVisualRenderState {
        let clampedTarget = clampTipPosition(targetTipPosition)
        seedVisualDynamicsIfNeeded(at: clampedTarget, time: time)

        let result = CursorVisualDynamicsAnimator.advance(
            state: visualDynamicsState ?? CursorVisualDynamicsAnimator.state(at: clampedTarget, time: CGFloat(time)),
            targetTipPosition: clampedTarget,
            targetTime: CGFloat(time),
            idleAngleOffset: idleAngleOffset,
            baseHeading: renderBaseHeading,
            renderYAxisMultiplier: renderYAxisMultiplier,
            configuration: .fast(speed: activeSettings.speed)
        )
        visualDynamicsState = result.state
        return result.renderState
    }

    private static func placeCursor(
        using renderState: CursorVisualRenderState, clickProgress: CGFloat, ripple: CursorClickRipple? = nil
    ) {
        guard let panel, let cursorView else {
            return
        }

        let origin = artwork.geometry.origin(forTipPosition: renderState.tipPosition)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        cursorView.rotation = renderState.rotation
        cursorView.cursorBodyOffset = renderState.cursorBodyOffset
        cursorView.fogOffset = renderState.fogOffset
        cursorView.fogOpacity = renderState.fogOpacity
        cursorView.fogScale = renderState.fogScale
        cursorView.clickProgress = clickProgress
        cursorView.ripple = ripple
        cursorView.indicator = interactionIndicator
        cursorView.lensEnabled = activeSettings.lensEnabled
        cursorView.needsDisplay = true
        displayedTipPosition = renderState.tipPosition
        writeObservationSnapshot(
            tipPosition: renderState.tipPosition,
            rotation: renderState.rotation
        )
    }

    private static func writeObservationSnapshot(tipPosition: CGPoint?, rotation: CGFloat?) {
        // Every frame: the path was captured with the request, no environment lookup here.
        guard let path = activeSettings.observationFilePath else {
            return
        }
        let url = URL(fileURLWithPath: path)

        let snapshot = VisualCursorObservationSnapshot(
            phase: interactionIndicator?.phase ?? observationPhase,
            tipPosition: tipPosition,
            restingTipPosition: restingTipPosition,
            rotation: rotation,
            timestamp: CACurrentMediaTime()
        )

        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Observation is debug-only and must not affect tool execution.
        }
    }

    /// OPEN_COMPUTER_USE_CURSOR_TRACE_FILE: one line per cursor event (move with its start and end,
    /// pulse, hide, reset), to check what the cursor did without watching the screen.
    private static func trace(_ event: String) {
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

    /// Keeps the tip on a display. Only the tip is clamped, to the display's full frame: keeping the whole
    /// 126 px panel inside the visible frame drew the cursor 40 to 70 px away from targets near an edge
    /// (traffic lights, sidebar toggles). The borderless panel may hang off-screen.
    private static func clampTipPosition(_ tipPosition: CGPoint) -> CGPoint {
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
    private static func nearestScreen(to point: CGPoint) -> NSScreen? {
        func distance(_ frame: CGRect) -> CGFloat {
            let dx = point.x - point.x.clamped(to: frame.minX...frame.maxX)
            let dy = point.y - point.y.clamped(to: frame.minY...frame.maxY)
            return hypot(dx, dy)
        }
        return NSScreen.screens.min { distance($0.frame) < distance($1.frame) } ?? NSScreen.main
    }

    /// Snapshot and live AX frames differ by sub-pixel rounding; that is not a move.
    private static func framesNearlyEqual(_ a: CGRect, _ b: CGRect?) -> Bool {
        guard let b else { return false }
        return abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5
            && abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func pumpFrame() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
    }

    private static func pause(for duration: TimeInterval) {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < duration {
            pumpFrame()
        }
    }

    private static func distanceBetween(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
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
            SoftwareCursorGlyphRenderer.backdrop = CursorBackdrop.shared.current(for: window.frame)
            CursorBackdrop.shared.refreshIfNeeded(windowFrame: window.frame, windowNumber: window.windowNumber) { [weak self] in
                DispatchQueue.main.async { self?.needsDisplay = true }
                // Look again a little later, so text that appears under a resting cursor shows through correctly.
                DispatchQueue.main.asyncAfter(deadline: .now() + CursorBackdrop.maxAge * 0.8) {
                    if self?.window?.isVisible == true { self?.needsDisplay = true }
                }
            }
        }

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
    }
}
