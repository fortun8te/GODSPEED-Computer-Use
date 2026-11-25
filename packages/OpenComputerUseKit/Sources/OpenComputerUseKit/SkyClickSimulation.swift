import AppKit
import CoreGraphics
import Foundation

struct SkyClickTarget {
    let screenPoint: CGPoint
    let windowPoint: CGPoint
    let windowBounds: CGRect
    let windowID: CGWindowID
    let pid: pid_t
}

enum SkyClickEventKind: Equatable, Sendable {
    case moved
    case down
    case up

    var cgEventType: CGEventType {
        switch self {
        case .moved:
            return .mouseMoved
        case .down:
            return .leftMouseDown
        case .up:
            return .leftMouseUp
        }
    }
}

enum SkyClickPointKind: Equatable, Sendable {
    case target
    case primer
}

struct SkyClickEventStep: Equatable, Sendable {
    let kind: SkyClickEventKind
    let pointKind: SkyClickPointKind
    let clickState: Int64
    let phase: Int64
    let delayAfter: TimeInterval
}

func skyClickEventRecipe(clickCount: Int) throws -> [SkyClickEventStep] {
    guard (1...2).contains(clickCount) else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports click_count 1 or 2"
        )
    }

    var steps = [
        SkyClickEventStep(kind: .moved, pointKind: .target, clickState: 0, phase: 2, delayAfter: 0.015),
        SkyClickEventStep(kind: .down, pointKind: .primer, clickState: 1, phase: 1, delayAfter: 0.001),
        SkyClickEventStep(kind: .up, pointKind: .primer, clickState: 1, phase: 2, delayAfter: 0.100),
    ]

    for pairIndex in 1...clickCount {
        steps.append(
            SkyClickEventStep(
                kind: .down,
                pointKind: .target,
                clickState: Int64(pairIndex),
                phase: 3,
                delayAfter: 0.001
            )
        )
        steps.append(
            SkyClickEventStep(
                kind: .up,
                pointKind: .target,
                clickState: Int64(pairIndex),
                phase: 3,
                delayAfter: pairIndex < clickCount ? 0.080 : 0
            )
        )
    }

    return steps
}

/// The window must still exist and belong to the snapshot's process. It does
/// not need to be on-screen: SkyLight routes by window id, so a covered window
/// or one on another Space is a valid target (verified live on macOS 27).
func skyClickWindowMatchesTarget(
    windowInfo: [[String: Any]],
    windowID: CGWindowID,
    pid: pid_t
) -> Bool {
    skyKeyWindowMatchesTarget(windowInfo: windowInfo, windowID: windowID, pid: pid)
}

enum SkyClickDispatcher {
    private static let primerScreenPoint = CGPoint(x: -1, y: -1)
    private static let primerWindowPoint = CGPoint(x: -1, y: -1)
    private static let dispatchLock = NSLock()

    // Raw private event fields used by the Chromium-compatible Cua Driver path.
    private enum EventField {
        static let gesturePhase: UInt32 = 0
        static let clickState: UInt32 = 1
        static let buttonNumber: UInt32 = 3
        static let subtype: UInt32 = 7
        static let targetPID: UInt32 = 40
        static let windowNumber: UInt32 = 51
        static let clickGroupID: UInt32 = 58
        static let windowUnderPointer: UInt32 = 91
        static let handlingWindowUnderPointer: UInt32 = 92
    }

    static func click(
        target: SkyClickTarget,
        clickCount: Int,
        spi: SkyLightSPI = .shared
    ) throws {
        let delivery = NativeInputDelivery()
        try delivery.check()
        try requireUsableComputerUseSession()
        guard spi.capability.isAvailable else {
            throw ComputerUseError.message(
                "click_method 'sky_click' is unavailable: \(spi.capability.unavailableReason)"
            )
        }

        dispatchLock.lock()
        let start = TimingLog.now()
        defer {
            TimingLog.log("sky_click.total", since: start)
            dispatchLock.unlock()
        }

        try delivery.check()
        try validate(target: target)
        let recipe = try skyClickEventRecipe(clickCount: clickCount)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create SkyLight HID event source.")
        }

        // Cua uses the nanosecond component of wall-clock time here, which is
        // always below one billion. Keep the same narrow raw-field range;
        // WindowServer does not publish field 58's accepted width.
        let clickGroupID = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)

        // Prepare and stamp releases before taking focus or pressing. A later
        // allocation, expired lease or cancellation cannot leave a button held.
        let prepared = try recipe.map { step -> (step: SkyClickEventStep, event: CGEvent) in
            let screenPoint = step.pointKind == .target ? target.screenPoint : primerScreenPoint
            let windowPoint = step.pointKind == .target ? target.windowPoint : primerWindowPoint
            guard let event = CGEvent(mouseEventSource: source, mouseType: step.kind.cgEventType,
                                      mouseCursorPosition: screenPoint, mouseButton: .left) else {
                throw ComputerUseError.message("Failed to prepare sky_click mouse event \(step.kind.cgEventType.rawValue).")
            }
            try stamp(event, target: target, windowPoint: windowPoint, clickState: step.clickState,
                      phase: step.phase, clickGroupID: clickGroupID, spi: spi)
            return (step, event)
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusContext: SkyLightSyntheticFocusContext?
        try delivery.check()
        if frontmostPID == target.pid {
            focusContext = nil
        } else {
            focusContext = try spi.beginSyntheticTargetFocus(
                targetPID: target.pid,
                targetWindowID: target.windowID
            )
        }

        do {
            try deliverPreparedEvents(prepared, delivery: delivery, validate: {
                try requireUsableComputerUseSession()
                try validate(target: target)
            }, post: { event in
                // The current Cua Driver Chromium recipe deliberately posts through
                // both channels: SkyLight reaches Chromium/Catalyst while the public
                // path preserves AppKit compatibility. This is one dispatch policy,
                // not a retry after an observed failure.
                try spi.postToPid(event, pid: target.pid, delivery: delivery)
                event.postToPid(target.pid)
            }, release: { event in
                let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                guard skyClickWindowMatchesTarget(windowInfo: windows, windowID: target.windowID, pid: target.pid) else { return }
                spi.releaseMouseToPid(event, pid: target.pid)
                event.postToPid(target.pid)
            }, delayScale: InputTiming.skyClickDelayScale)
        } catch {
            if let focusContext {
                try? spi.endSyntheticTargetFocus(focusContext)
            }
            throw error
        }

        if let focusContext {
            // SkyLight delivery is asynchronous. Keep the target's AppKit
            // synthetic active state long enough for Chromium's renderer hop
            // to consume the final mouse-up before deactivating only the target.
            let rendererSettle = 0.100 * InputTiming.skyClickDelayScale
            if rendererSettle > 0 {
                Thread.sleep(forTimeInterval: rendererSettle)
            }
            try SyntheticFocusTeardown.endAfterDelivery { try spi.endSyntheticTargetFocus(focusContext) }
        }
    }

    /// The recipe contains adjacent down/up pairs. Keep the up ready before its
    /// down and send it without cancellation/session checks once that down posts.
    static func deliverPreparedEvents(
        _ prepared: [(step: SkyClickEventStep, event: CGEvent)],
        delivery: NativeInputDelivery = NativeInputDelivery(),
        validate: () throws -> Void,
        post: (CGEvent) throws -> Void,
        release: (CGEvent) -> Void,
        delayScale: TimeInterval = 1,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        for index in prepared.indices {
            switch prepared[index].step.kind {
            case .down:
                guard index + 1 < prepared.count, prepared[index + 1].step.kind == .up else {
                    throw ComputerUseError.notSent("The click recipe has no matching release. Nothing was sent.")
                }
            case .up:
                guard index > 0, prepared[index - 1].step.kind == .down else {
                    throw ComputerUseError.notSent("The click recipe contains an unmatched release. Nothing was sent.")
                }
            case .moved: break
            }
        }
        var pendingRelease: CGEvent?
        defer {
            if let pendingRelease {
                pendingRelease.timestamp = DispatchTime.now().uptimeNanoseconds
                release(pendingRelease)
            }
        }
        do {
            for (index, item) in prepared.enumerated() {
                if item.step.kind == .up {
                    item.event.timestamp = DispatchTime.now().uptimeNanoseconds
                    release(item.event)
                    pendingRelease = nil
                } else {
                    try delivery.check()
                    try validate()
                    try delivery.check()
                    item.event.timestamp = DispatchTime.now().uptimeNanoseconds
                    try post(item.event)
                    delivery.didPost()
                    if item.step.kind == .down { pendingRelease = prepared[index + 1].event }
                }
                try delivery.check()
                let delay = item.step.delayAfter * delayScale
                if delay > 0 { pause(delay) }
            }
            try delivery.check()
        } catch {
            throw delivery.failure(error)
        }
    }

    private static func validate(target: SkyClickTarget) throws {
        guard
            target.screenPoint.x.isFinite,
            target.screenPoint.y.isFinite,
            target.windowPoint.x.isFinite,
            target.windowPoint.y.isFinite,
            target.windowBounds.width > 0,
            target.windowBounds.height > 0
        else {
            throw ComputerUseError.message("sky_click requires finite target coordinates and window bounds")
        }

        let localBounds = CGRect(origin: .zero, size: target.windowBounds.size)
        guard localBounds.contains(target.windowPoint) else {
            throw ComputerUseError.message("sky_click target is outside the snapshot window bounds")
        }

        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw ComputerUseError.stateUnavailable(
                "sky_click target app is hidden. Unhide it first; sky_click does not change window visibility."
            )
        }
        let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard skyClickWindowMatchesTarget(
            windowInfo: windowInfo,
            windowID: target.windowID,
            pid: target.pid
        ) else {
            throw ComputerUseError.stateUnavailable(
                "sky_click target window no longer exists or is no longer owned by the target app. Run get_app_state again."
            )
        }
    }

    private static func stamp(
        _ event: CGEvent,
        target: SkyClickTarget,
        windowPoint: CGPoint,
        clickState: Int64,
        phase: Int64,
        clickGroupID: Int64,
        spi: SkyLightSPI
    ) throws {
        let windowID = Int64(target.windowID)
        try spi.setIntegerField(event, field: EventField.gesturePhase, value: phase)
        try spi.setIntegerField(event, field: EventField.clickState, value: clickState)
        try spi.setIntegerField(event, field: EventField.buttonNumber, value: 0)
        try spi.setIntegerField(event, field: EventField.subtype, value: 3)
        try spi.setIntegerField(event, field: EventField.targetPID, value: Int64(target.pid))
        try spi.setIntegerField(event, field: EventField.windowNumber, value: windowID)
        try spi.setIntegerField(event, field: EventField.clickGroupID, value: clickGroupID)
        try spi.setIntegerField(event, field: EventField.windowUnderPointer, value: windowID)
        try spi.setIntegerField(event, field: EventField.handlingWindowUnderPointer, value: windowID)
        try spi.setWindowLocation(event, point: windowPoint)
    }

}
