import ApplicationServices
import Foundation

/// Reacts to accessibility notifications from the apps Godspeed acts on. A poll
/// may wake on a change instead of sleeping its full interval, and a batch effect
/// check may reuse its last read. A silent app keeps today's polling: the caps and
/// read cadence stay the same, and only a sleep can end early.
final class AXChangeMonitor: @unchecked Sendable {
    /// Handle for one app's observer. Cancelling removes it.
    protocol Subscription: AnyObject {
        func cancel()
    }

    /// Where notifications come from. The real source wraps AXObserver; tests use a fake.
    protocol NotificationSource: AnyObject {
        func subscribe(pid: pid_t, names: [String], handler: @escaping (String) -> Void) -> Subscription?
    }

    /// `unknown` until a notification arrives; `silent` after an action produced none within the grace window.
    enum Support: Equatable {
        case unknown
        case notifying
        case silent
    }

    /// Only an effect check may reuse a quiet read. A done_when proof always reads the app.
    enum Purpose: Equatable {
        case effectCheck
        case doneProof
    }

    struct Snapshot: Equatable {
        let generation: UInt64
        let dirtySince: UInt64?
        let reason: String?
        let support: Support
        let notifications: Int
    }

    static let watchedNotifications: [String] = [
        kAXFocusedUIElementChangedNotification, kAXValueChangedNotification,
        kAXUIElementDestroyedNotification, kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXTitleChangedNotification, kAXMenuOpenedNotification, kAXSheetCreatedNotification,
    ]
    /// An action should be followed by a notification within this long, or the app counts as silent.
    static let actionGraceSeconds: TimeInterval = 2
    /// An app with no tracking activity for this long loses its observer.
    static let idleSeconds: TimeInterval = 60

    static let shared = AXChangeMonitor(source: AXObserverSource(), now: TimingLog.now)

    private struct App {
        var subscription: Subscription?
        var attempted = false
        var lastActivity: TimeInterval
        /// Bumped by every notification. A read started at generation N saw everything before N.
        var generation: UInt64 = 0
        /// Generation of the first notification since the last clean read, if any.
        var dirtySince: UInt64?
        var reason: String?
        var notifications = 0
        var wakes = 0
        var support: Support = .unknown
        var pendingActionAt: TimeInterval?
        var readGeneration: UInt64?
        var readComplete = false
    }

    /// Guards `apps` and wakes waiters when a generation moves.
    private let lock = NSCondition()
    private var apps: [pid_t: App] = [:]
    private let source: NotificationSource
    private let now: () -> TimeInterval

    init(source: NotificationSource, now: @escaping () -> TimeInterval) {
        self.source = source
        self.now = now
    }

    // MARK: Tracking

    /// Starts watching `pid` (its observer is created on first use) and returns its current generation.
    @discardableResult
    func track(_ pid: pid_t) -> UInt64 {
        var attempt = false
        let generation = locked { apps -> UInt64 in
            var app = apps[pid] ?? App(lastActivity: now())
            app.lastActivity = now()
            attempt = !app.attempted
            app.attempted = true
            apps[pid] = app
            return app.generation
        }
        if attempt {
            // Subscribe outside the lock: a source may call back synchronously.
            let subscription = source.subscribe(pid: pid, names: Self.watchedNotifications) { [weak self] name in
                self?.receive(pid: pid, name: name)
            }
            let dropped = locked { apps -> Bool in
                guard apps[pid] != nil else { return true }
                apps[pid]?.subscription = subscription
                return false
            }
            if dropped { subscription?.cancel() }
        }
        return generation
    }

    /// Current generation for `pid`; 0 when the app is not tracked.
    func generation(_ pid: pid_t) -> UInt64 {
        locked { apps in apps[pid]?.generation ?? 0 }
    }

    /// Drops apps idle past `idleSeconds`. Every access sweeps, so no timer thread is needed.
    func sweepIdle() {
        locked { _ in () }
    }

    // MARK: Waiting

    /// Blocks up to `seconds` and returns true as soon as `pid` reports a change after `token`.
    /// Returns false on timeout, for an untracked app, or on cancellation. The caller keeps its
    /// own cap and its normal read, so a false return is the same as an ordinary sleep.
    @discardableResult
    func awaitChange(pid: pid_t, since token: UInt64, upTo seconds: TimeInterval) -> Bool {
        guard seconds > 0, !RequestCancellation.requested else { return false }
        locked { apps in apps[pid]?.lastActivity = now() }
        let deadline = Date().addingTimeInterval(seconds)
        lock.lock()
        defer { lock.unlock() }
        // Waits use real time. The injected clock only governs activity and grace windows.
        while generationLocked(pid) == token {
            guard Date() < deadline, !RequestCancellation.requested else { return false }
            _ = lock.wait(until: deadline)
        }
        apps[pid]?.wakes += 1
        if let wakes = apps[pid]?.wakes { TimingLog.count("ax.wakes", wakes) }
        return true
    }

    // MARK: Reads

    /// Records that a read which began at `token` has finished. The dirty flag clears only when no
    /// notification arrived during the read, so a change that landed mid-read stays dirty.
    func finishRead(pid: pid_t, startedAt token: UInt64, complete: Bool) {
        locked { apps in
            guard apps[pid] != nil else { return }
            if apps[pid]!.generation == token {
                apps[pid]!.dirtySince = nil
                apps[pid]!.reason = nil
            }
            apps[pid]!.readGeneration = token
            apps[pid]!.readComplete = complete
        }
    }

    /// True only when an effect check may reuse its last read: the app has notified before, nothing has
    /// arrived since a complete read, and no action is awaiting its notification. A done_when proof is
    /// never allowed to reuse a read.
    func mayReuseQuietRead(pid: pid_t, purpose: Purpose) -> Bool {
        guard purpose == .effectCheck else { return false }
        return locked { apps in
            resolveActions(pid, in: &apps)
            guard let app = apps[pid], app.support == .notifying, app.readComplete,
                  let token = app.readGeneration, app.generation == token, app.dirtySince == nil,
                  app.pendingActionAt == nil
            else { return false }
            return true
        }
    }

    // MARK: Action detection

    /// Call after a mutating step. A notification within the grace window keeps the app `notifying`;
    /// none marks it `silent`, so it is polled as before.
    func noteAction(_ pid: pid_t) {
        locked { apps in
            guard apps[pid] != nil, apps[pid]!.pendingActionAt == nil else { return }
            apps[pid]!.pendingActionAt = now()
        }
    }

    func support(_ pid: pid_t) -> Support {
        locked { apps in
            resolveActions(pid, in: &apps)
            return apps[pid]?.support ?? .unknown
        }
    }

    func snapshot(_ pid: pid_t) -> Snapshot? {
        locked { apps in
            resolveActions(pid, in: &apps)
            guard let app = apps[pid] else { return nil }
            return Snapshot(generation: app.generation, dirtySince: app.dirtySince, reason: app.reason,
                            support: app.support, notifications: app.notifications)
        }
    }

    // MARK: Internals

    /// Runs `body` under the lock after sweeping idle apps. Subscriptions dropped by the sweep are
    /// cancelled after the lock is released.
    @discardableResult
    private func locked<T>(_ body: (inout [pid_t: App]) -> T) -> T {
        lock.lock()
        let removed = sweepLocked()
        let result = body(&apps)
        lock.unlock()
        removed.forEach { $0.cancel() }
        return result
    }

    /// Caller holds the lock.
    private func sweepLocked() -> [Subscription] {
        let current = now()
        var removed: [Subscription] = []
        for (pid, app) in apps where current - app.lastActivity > Self.idleSeconds {
            if let subscription = app.subscription { removed.append(subscription) }
            apps[pid] = nil
        }
        return removed
    }

    /// An action still waiting for its notification after the grace window means the app is silent.
    /// A notification clears `pendingActionAt`, so reaching here means none came.
    private func resolveActions(_ pid: pid_t, in apps: inout [pid_t: App]) {
        guard let at = apps[pid]?.pendingActionAt, now() - at >= Self.actionGraceSeconds else { return }
        apps[pid]?.pendingActionAt = nil
        apps[pid]?.support = .silent
    }

    /// Caller holds the lock.
    private func generationLocked(_ pid: pid_t) -> UInt64 {
        apps[pid]?.generation ?? 0
    }

    /// Runs on the observer thread.
    private func receive(pid: pid_t, name: String) {
        let count: Int? = locked { apps in
            guard apps[pid] != nil else { return nil }
            apps[pid]!.generation += 1
            if apps[pid]!.dirtySince == nil { apps[pid]!.dirtySince = apps[pid]!.generation }
            apps[pid]!.reason = Self.reason(for: name)
            apps[pid]!.notifications += 1
            apps[pid]!.support = .notifying
            apps[pid]!.pendingActionAt = nil
            lock.broadcast()
            return apps[pid]!.notifications
        }
        if let count { TimingLog.count("ax.notifications", count) }
    }

    /// Coarse reason kept with the dirty flag.
    static func reason(for name: String) -> String {
        switch name {
        case kAXFocusedUIElementChangedNotification: return "focus"
        case kAXValueChangedNotification: return "value"
        case kAXUIElementDestroyedNotification: return "destroyed"
        case kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            return "window"
        case kAXTitleChangedNotification: return "title"
        case kAXMenuOpenedNotification: return "menu"
        case kAXSheetCreatedNotification: return "sheet"
        default: return "other"
        }
    }
}

// MARK: - Real source

/// AXObserver-backed source. Every observer's run loop source lives on one dedicated thread.
final class AXObserverSource: AXChangeMonitor.NotificationSource, @unchecked Sendable {
    func subscribe(pid: pid_t, names: [String], handler: @escaping (String) -> Void) -> AXChangeMonitor.Subscription? {
        let box = HandlerBox(handler: handler)
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return nil }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        let added = names.filter { AXObserverAddNotification(observer, element, $0 as CFString, refcon) == .success }
        guard !added.isEmpty else { return nil }
        let source = AXObserverGetRunLoopSource(observer)
        let thread = AXRunLoopThread.shared
        thread.perform { CFRunLoopAddSource(thread.loop, source, .defaultMode) }
        return ObserverSubscription(observer: observer, element: element, names: added, source: source,
                                    box: box, thread: thread)
    }
}

private final class HandlerBox {
    let handler: (String) -> Void

    init(handler: @escaping (String) -> Void) {
        self.handler = handler
    }
}

private let axObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    Unmanaged<HandlerBox>.fromOpaque(refcon).takeUnretainedValue().handler(notification as String)
}

private final class ObserverSubscription: AXChangeMonitor.Subscription, @unchecked Sendable {
    private let observer: AXObserver
    private let element: AXUIElement
    private let names: [String]
    private let source: CFRunLoopSource
    private let box: HandlerBox
    private let thread: AXRunLoopThread
    private let lock = NSLock()
    private var cancelled = false

    init(observer: AXObserver, element: AXUIElement, names: [String], source: CFRunLoopSource,
         box: HandlerBox, thread: AXRunLoopThread) {
        self.observer = observer
        self.element = element
        self.names = names
        self.source = source
        self.box = box
        self.thread = thread
    }

    func cancel() {
        let shouldCancel = lock.withLock { () -> Bool in
            if cancelled { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        for name in names { AXObserverRemoveNotification(observer, element, name as CFString) }
        // The block keeps `box` alive until the run loop has dropped the source.
        let box = box, source = source, thread = thread
        thread.perform {
            CFRunLoopRemoveSource(thread.loop, source, .defaultMode)
            withExtendedLifetime(box) {}
        }
    }
}

/// One background thread that owns every AXObserver run loop source. A timer that never
/// fires keeps the loop alive.
final class AXRunLoopThread: @unchecked Sendable {
    static let shared = AXRunLoopThread()

    private(set) var loop: CFRunLoop!
    private let started = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [self] in
            let current = CFRunLoopGetCurrent()
            var context = CFRunLoopTimerContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            let keepAlive = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0,
                                                 { _, _ in }, &context)
            CFRunLoopAddTimer(current, keepAlive, .defaultMode)
            loop = current
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "godspeed.ax-observers"
        thread.start()
        started.wait()
    }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }
}
