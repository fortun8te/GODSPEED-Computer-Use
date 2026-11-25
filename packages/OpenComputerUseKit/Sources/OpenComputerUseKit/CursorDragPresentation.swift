import CoreGraphics
import Foundation

/// Emitted after an event is posted, never while a path is merely being prepared.
/// Posting is not an acknowledgement that the destination app accepted the drop.
struct NativeDragProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case moved, pressed, dragged, released }
    let point: CGPoint
    let phase: Phase
    let timestamp: UInt64

    init(point: CGPoint, phase: Phase, timestamp: UInt64) {
        self.point = point
        self.phase = phase
        self.timestamp = timestamp
    }

    init?(event: CGEvent) {
        switch event.type {
        case .mouseMoved: phase = .moved
        case .leftMouseDown: phase = .pressed
        case .leftMouseDragged: phase = .dragged
        case .leftMouseUp: phase = .released
        default: return nil
        }
        point = event.location
        timestamp = event.timestamp
    }
}

struct CursorDeliveredDragFrame {
    enum Completion: Equatable { case delivered, cancelled }
    let gesture: UInt64
    let target: VisualCursorTarget
    let progress: NativeDragProgress
    var completion: Completion?
}

/// A drag has one pending presentation, not a queue of positions to replay after the drop.
/// The service thread updates this mailbox immediately after posting each real event. The
/// main thread takes the most recent point; a busy display therefore catches up in one frame.
final class CursorDragPresentation: @unchecked Sendable {
    private static let identifierLock = NSLock()
    nonisolated(unsafe) private static var nextIdentifier: UInt64 = 0

    private let lock = NSLock()
    private let gesture: UInt64
    private let generation: UInt64
    private let client: String
    private let settings: VisualCursorSettings
    private let window: CursorTargetWindow?
    private let windowBounds: CGRect?
    private let frameSource: CursorFrameSource?
    private let mappings: [VisualCursorScreenMapping]
    private let present: @MainActor (CursorDeliveredDragFrame) -> Void
    private var latest: CursorDeliveredDragFrame?
    private var pending = false
    private var scheduled = false
    private var finished = false

    init(window: CursorTargetWindow?, windowBounds: CGRect? = nil,
         frameSource: CursorFrameSource? = nil,
         mappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings(),
         present: @escaping @MainActor (CursorDeliveredDragFrame) -> Void = {
             SoftwareCursorOverlay.presentDeliveredDrag($0)
         }) {
        gesture = Self.identifierLock.withLock {
            Self.nextIdentifier &+= 1
            return Self.nextIdentifier
        }
        generation = VisualCursorSupport.animationGeneration
        client = ClientScope.current
        settings = VisualCursorSupport.settings
        self.window = window
        self.windowBounds = windowBounds
        self.frameSource = frameSource
        self.mappings = mappings
        self.present = present
    }

    func delivering<T>(_ deliver: ((NativeDragProgress) -> Void) throws -> T) rethrows -> T {
        do {
            let result = try deliver(record)
            finish()
            return result
        } catch {
            finish(cancelled: true)
            throw error
        }
    }

    func record(_ progress: NativeDragProgress) {
        guard progress.point.x.isFinite, progress.point.y.isFinite,
              generation == VisualCursorSupport.animationGeneration else { return }
        let shouldSchedule = lock.withLock {
            guard !finished, latest.map({ progress.timestamp >= $0.progress.timestamp }) ?? true else { return false }
            let anchor: CursorRestingAnchor?
            if let window, let windowBounds {
                anchor = CursorRestingAnchor(windowID: window.windowID, layer: window.layer,
                    windowLocalPoint: CGPoint(x: progress.point.x - windowBounds.minX,
                                              y: progress.point.y - windowBounds.minY),
                    windowBounds: windowBounds, frameSource: frameSource)
            } else { anchor = nil }
            let target = VisualCursorTarget(
                point: visualCursorAppKitPoint(fromScreenStatePoint: progress.point, screenMappings: mappings),
                window: window, anchor: anchor)
            latest = CursorDeliveredDragFrame(gesture: gesture, target: target, progress: progress)
            pending = true
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule { schedule() }
    }

    /// Failure before the first event has no visual side effects. A partial drag ends at its
    /// last posted point, even when the original intended endpoint was much farther away.
    func finish(cancelled: Bool = false) {
        guard generation == VisualCursorSupport.animationGeneration else { return }
        let shouldSchedule = lock.withLock {
            guard !finished else { return false }
            finished = true
            guard latest != nil else { return false }
            latest?.completion = cancelled ? .cancelled : .delivered
            pending = true
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule { schedule() }
    }

    private func schedule() {
        VisualCursorSupport.performCursorAnimation(capturedSettings: settings, capturedClient: client) { [self] in
            guard generation == VisualCursorSupport.animationGeneration else { return }
            let frame = lock.withLock { () -> CursorDeliveredDragFrame? in
                scheduled = false
                guard pending else { return nil }
                pending = false
                return latest
            }
            if let frame { present(frame) }
        }
    }
}
