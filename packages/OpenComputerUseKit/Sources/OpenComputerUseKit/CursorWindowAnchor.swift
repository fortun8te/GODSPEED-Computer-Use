import ApplicationServices
import CoreGraphics
import Foundation

/// A window's accessibility element, boxed so a cursor anchor can carry it across threads.
/// AX elements are immutable references; reading them from the main thread is supported.
final class CursorFrameSource: @unchecked Sendable, Equatable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: CursorFrameSource, rhs: CursorFrameSource) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

/// The point a cursor target was derived from, expressed relative to the
/// window frame the snapshot reported.
///
/// A window that moves between the snapshot and the action keeps its
/// window-local geometry, so this is what lets the overlay re-derive the point
/// from the window's live frame instead of drawing on the display the window
/// just left.
struct CursorRestingAnchor: Equatable, Sendable {
    let windowID: CGWindowID
    let layer: Int
    /// Element centre relative to the window's top-left corner, screen-state space.
    let windowLocalPoint: CGPoint
    /// Window frame the anchor was derived from, screen-state space.
    let windowBounds: CGRect
    /// The window's accessibility element. The overlay registers it when the queued animation
    /// runs, so a batch that alternates windows follows each one instead of whichever window
    /// was registered last when the actions were queued.
    var frameSource: CursorFrameSource? = nil

    /// The anchored point re-expressed against a live window frame.
    ///
    /// Returns `nil` when the live frame carries no usable size, so callers can
    /// fall back to the point they already have.
    func screenStatePoint(liveFrame: CGRect) -> CGPoint? {
        guard Self.isUsable(liveFrame), windowLocalPoint.x.isFinite, windowLocalPoint.y.isFinite else {
            return nil
        }

        let localX = windowLocalPoint.x.clamped(to: 0...liveFrame.width)
        let localY = windowLocalPoint.y.clamped(to: 0...liveFrame.height)
        return CGPoint(x: liveFrame.minX + localX, y: liveFrame.minY + localY)
    }

    static func isUsable(_ frame: CGRect) -> Bool {
        !frame.isInfinite && !frame.isNull && frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }
}

/// Live frames for target windows.
///
/// `CGWindowListCopyWindowInfo` keeps reporting the pre-move frame for about a
/// second after a window is dragged to another display — measured while fixing
/// this: 83 identical frames at the cursor travel's 120 Hz pump. The
/// accessibility element the snapshot already holds reports the move
/// immediately, so it is the preferred source. Read it on a serial worker,
/// cache the last usable frame, and limit requests to 30 Hz. The window list is
/// used only when no accessibility element was registered; a failed AX read
/// must not replace a good frame with the window list's stale origin.
enum CursorWindowFrameTracker {
    private final class Source: @unchecked Sendable {
        let element: AXUIElement?
        var owners: Set<String>
        var frame: CGRect?
        var nextRefresh: TimeInterval = 0
        var waiting = false

        init(element: AXUIElement?, owners: Set<String>) {
            self.element = element
            self.owners = owners
        }
    }

    /// Lock-protected box so the tracker can be used from the service thread
    /// and the overlay's main-thread pump alike.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        // Retain only the windows an active cursor is following.
        var sources: [CGWindowID: Source] = [:]
        var pending: [CGWindowID] = []
        var draining = false
        /// Test seam: consulted before any real lookup.
        var override: ((CGWindowID) -> CGRect?)?
        var reader: (@Sendable (CGWindowID) -> CGRect?)?
    }

    private static let state = State()
    private static let queue = DispatchQueue(label: "com.ifuryst.ocu.cursor-frame", qos: .userInitiated)
    private static let refreshInterval: TimeInterval = 1 / 30

    static func register(windowID: CGWindowID?, element: AXUIElement?, owner: String = "") {
        guard let windowID else {
            return
        }

        state.lock.lock()
        defer { state.lock.unlock() }
        if let existing = state.sources[windowID] {
            existing.owners.insert(owner)
            switch (existing.element, element) {
            case let (lhs?, rhs?) where CFEqual(lhs, rhs): return
            case (_, nil): return
            default: break
            }
            let replacement = Source(element: element, owners: existing.owners)
            replacement.frame = existing.frame
            state.sources[windowID] = replacement
        } else {
            state.sources[windowID] = Source(element: element, owners: [owner])
        }
    }

    static func forget(windowID: CGWindowID, owner: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let source = state.sources[windowID] else { return }
        source.owners.remove(owner)
        if source.owners.isEmpty {
            state.sources[windowID] = nil
            state.pending.removeAll { $0 == windowID }
        }
    }

    static func forgetAll() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.sources.removeAll()
        state.pending.removeAll()
        // An in-flight IPC read cannot be cancelled safely. Keep its slot busy
        // until it returns; its result will be discarded by source identity.
    }

    static func installFrameOverrideForTesting(_ body: ((CGWindowID) -> CGRect?)?) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.override = body
    }

    static func installFrameReaderForTesting(_ body: (@Sendable (CGWindowID) -> CGRect?)?) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.reader = body
    }

    static func liveFrame(for windowID: CGWindowID) -> CGRect? {
        state.lock.lock()
        if let body = state.override {
            state.lock.unlock()
            return body(windowID)
        }
        guard let source = state.sources[windowID] else {
            state.lock.unlock()
            return nil
        }
        let frame = source.frame
        let now = ProcessInfo.processInfo.systemUptime
        var startWorker = false
        if !source.waiting && now >= source.nextRefresh {
            source.waiting = true
            if !state.pending.contains(windowID) { state.pending.append(windowID) }
            startWorker = !state.draining
            state.draining = true
        }
        state.lock.unlock()
        if startWorker { queue.async { drainPendingFrames() } }
        return frame
    }

    private static func drainPendingFrames() {
        while true {
            state.lock.lock()
            guard !state.pending.isEmpty else {
                state.draining = false
                state.lock.unlock()
                return
            }
            let windowID = state.pending.removeFirst()
            let source = state.sources[windowID]
            let reader = state.reader
            if let source { source.waiting = true }
            state.lock.unlock()
            guard let source else { continue }

            // Only one AX call runs at a time. Each active window owns at
            // most one queued read, so slow apps never block cursor drawing.
            let observed: CGRect?
            if let reader { observed = reader(windowID) }
            else if let element = source.element { observed = accessibilityFrame(element) }
            else { observed = windowListFrame(for: windowID) }

            state.lock.lock()
            if state.sources[windowID] === source, let observed, CursorRestingAnchor.isUsable(observed) {
                source.frame = observed
            }
            source.waiting = false
            source.nextRefresh = ProcessInfo.processInfo.systemUptime + refreshInterval
            state.lock.unlock()
        }
    }

    /// Frame read from the registered accessibility element, which reflects a
    /// move immediately.
    private static func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              CursorRestingAnchor.isUsable(CGRect(origin: position, size: size))
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    /// Fallback frame from the window server. Kept last because it can report
    /// the pre-move origin for about a second.
    static func windowListFrame(for windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]],
            let entry = info.first,
            let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }

        return frame
    }
}
