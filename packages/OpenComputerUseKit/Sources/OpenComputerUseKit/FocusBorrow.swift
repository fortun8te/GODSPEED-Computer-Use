import AppKit
import ApplicationServices
import Foundation

/// Brings an app to the front for a short moment, then gives focus back.
///
/// Some app steps only work while the app is the active one: a Save sheet or a Finder rename does not
/// open or take input in the background, and macOS reserves keyboard focus for the key window. So a
/// batch borrows focus around those steps only, and returns it afterwards. The pointer is never moved;
/// only the active application changes.
///
/// Rules:
/// - The app that was in front before the first borrow is restored when the last borrow ends, and only
///   if the user did not switch to another app meanwhile.
/// - Borrows nest: an inner borrow adds to the count and does not restore anything on its own.
/// - Every lease is released by `defer`, so an error still gives focus back.
/// - Off by default. `OPEN_COMPUTER_USE_FOCUS_BORROW=1` turns it on; background-only and strict modes always keep it off.
///
/// Every step that needs the app in front tries the background route first. Only when that fails for want of focus
/// does the reply say so (`needsBorrowingMessage`), typed as BACKGROUND_UNSUPPORTED while borrowing is off.
enum FocusBorrow {
    /// The process-wide borrow state used by the tools.
    static let shared = FocusBorrowController(activator: WorkspaceFocusActivator())

    /// The exact reply for a step that could only succeed with the app in front, while focus borrowing is off.
    static let needsBorrowingMessage = "This needs focus borrowing: set OPEN_COMPUTER_USE_FOCUS_BORROW=1 or allow it in Settings"

    /// The refusal for a step that failed only because it needed the app in front. Borrowing off: the typed
    /// BACKGROUND_UNSUPPORTED reply with the exact sentence. Borrowing on: the ordinary refusal (unsent unless `unsent`
    /// is false, which keeps the read's stateUnavailable delivery) with the retry hint when the app is not borrowed.
    static func focusRequiredError(_ detail: String, enabled: Bool, borrowed: Bool, unsent: Bool = true) -> ComputerUseError {
        guard enabled else { return .backgroundUnsupported(needsBorrowingMessage) }
        let text = borrowed ? detail : detail + " If nothing else works, those steps can be sent in a batch with \"foreground\": true (only done while the user is away)."
        return unsent ? .notSent(text) : .stateUnavailable(text)
    }

    /// `focusRequiredError` for the current settings and the app `pid`.
    static func focusRequiredError(_ detail: String, pid: pid_t, unsent: Bool = true) -> ComputerUseError {
        focusRequiredError(detail, enabled: isEnabled, borrowed: isBorrowed(pid: pid), unsent: unsent)
    }

    /// A dialog-opening step (Save, Export, a save chord) that failed in the background with focus borrowing off failed for
    /// want of focus: the typed reply replaces the bare failure. Policy refusals and steps that did not fail are kept as they are.
    static func dialogStepReply(_ result: ToolCallResult, opensDialog: Bool, appIsFrontmost: Bool, enabled: Bool) -> ToolCallResult {
        guard opensDialog, result.isError, !enabled, !appIsFrontmost, result.failureCode?.isActionRefusal != true else {
            return result
        }
        return .failure(ComputerUseError.backgroundUnsupported(needsBorrowingMessage))
    }

    /// The sentence a `foreground: true` batch adds to its reply when it failed with focus borrowing off. Nil otherwise.
    static func foregroundBatchNote(foreground: Bool, failed: Bool, enabled: Bool) -> String? {
        foreground && failed && !enabled ? needsBorrowingMessage : nil
    }

    /// Menu titles that open a dialog or an editor, so the steps after them need the app in front.
    /// Matched after dropping a trailing "…" or "...", case-insensitively.
    static let dialogMenuTitles: Set<String> = [
        "save", "save as", "export", "rename", "new folder", "open", "print", "duplicate", "move to",
    ]

    /// Focus borrowing is opt-in and unavailable in either background-only mode.
    static var isEnabled: Bool {
        isEnabled(environment: GodspeedSettings.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        guard !backgroundOnlyMode(environment: environment) else { return false }
        return StrictBackground.enabledFlag(environment["OPEN_COMPUTER_USE_FOCUS_BORROW"])
    }

    /// Whether a menu item with this title opens a dialog or editor (ends with an ellipsis, or is one of
    /// the dialog titles above).
    static func menuTitleOpensDialog(_ title: String) -> Bool {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("…") {
            return true
        }
        if text.hasSuffix("...") {
            return true
        }
        text = text.lowercased()
        return dialogMenuTitles.contains(text)
    }

    /// Whether a press_menu path (its last title is the item pressed) should borrow focus.
    static func menuPathOpensDialog(_ titles: [String]) -> Bool {
        guard let last = titles.last else { return false }
        return menuTitleOpensDialog(last)
    }

    /// Whether the app of `pid` is currently borrowed (so input may use the normal frontmost paths).
    static func isBorrowed(pid: pid_t) -> Bool {
        !backgroundOnlyMode() && shared.isBorrowed(pid: pid)
    }

    /// Runs `work` with `pid` in front and gives focus back afterwards, also when `work` throws.
    /// When the feature is off, `work` runs without any change to focus.
    static func withBorrow<T>(pid: pid_t, _ work: () throws -> T) rethrows -> T {
        guard isEnabled else { return try work() }
        let lease = shared.acquire(pid: pid)
        defer { shared.release(lease) }
        return try work()
    }

    /// The menu item (title) that a command chord such as "cmd+s" presses, when the frontmost-less app
    /// names it in its menu bar. Used by batches to decide whether a key press opens a dialog.
    static func menuTitle(forKey key: String, pid: pid_t) -> String? {
        SkyKeyboardDispatcher.menuItemTitle(forKey: key, pid: pid)
    }
}

/// Holds the borrows a batch has open, so the batch can add apps as it goes and give everything back at
/// its end (in reverse order). Not thread-safe by itself: one batch runs on one thread.
final class FocusBorrowSession {
    private let controller: FocusBorrowController
    private var leases: [FocusBorrowController.Lease] = []
    private let enabled: Bool
    /// When the first borrow of this session started. The user's own keys go to the borrowed app while it is
    /// in front, so a session gives focus back after `maxAge` and later steps run in the background.
    private var startedAt: Date?
    static let maxAge: TimeInterval = 6

    init(controller: FocusBorrowController = FocusBorrow.shared, enabled: Bool = FocusBorrow.isEnabled) {
        self.controller = controller
        self.enabled = enabled
    }

    /// Brings `pid` forward and keeps it there until `close()`. Returns false when the app could not be
    /// brought forward (the steps then run as they would in the background).
    @discardableResult
    func ensure(pid: pid_t) -> Bool {
        guard enabled, !backgroundOnlyMode() else { return false }
        if let startedAt, Date().timeIntervalSince(startedAt) > Self.maxAge
            || (isActive && FocusBorrowController.secondsSinceUserInput() < Date().timeIntervalSince(startedAt)) {
            // Too long, or the user came back mid-borrow: hand focus back now and run the rest in the background.
            close()
            return false
        }
        if let existing = leases.last(where: { $0.pid == pid }) {
            return existing.activated
        }
        if startedAt == nil { startedAt = Date() }
        let lease = controller.acquire(pid: pid)
        leases.append(lease)
        return lease.activated
    }

    var isActive: Bool { !leases.isEmpty }

    /// Gives focus back: releases the borrows in reverse order.
    func close() {
        while let lease = leases.popLast() {
            controller.release(lease)
        }
    }

    deinit {
        close()
    }
}

/// The bookkeeping behind `FocusBorrow`, with the system calls injected so tests can run it.
final class FocusBorrowController: @unchecked Sendable {
    /// One open borrow of `pid`. Releasing it twice does nothing.
    final class Lease {
        let pid: pid_t
        /// Whether the app was in front (or came to the front) when the borrow started.
        let activated: Bool
        fileprivate var released = false

        fileprivate init(pid: pid_t, activated: Bool) {
            self.pid = pid
            self.activated = activated
        }
    }

    private let lock = NSLock()
    private let activator: FocusActivating
    private var activePIDs: [pid_t] = []
    /// The app in front before the first open borrow; nil when there is nothing to give back.
    private var restorePID: pid_t?

    init(activator: FocusActivating) {
        self.activator = activator
    }

    var isBorrowing: Bool { lock.withLock { !activePIDs.isEmpty } }

    /// Opens a borrow of `pid`: the first borrow records the app in front, then `pid` is brought forward.
    func acquire(pid: pid_t) -> Lease {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let needsActivation: Bool = lock.withLock {
            if activePIDs.isEmpty {
                let front = activator.frontmostPID()
                restorePID = (front == nil || front == pid || front == ownPID) ? nil : front
            }
            activePIDs.append(pid)
            return activator.frontmostPID() != pid
        }
        // Not in the middle of a word: wait for a short pause in the user's typing before taking focus. If the
        // user is still typing when the wait ends, focus is not taken at all; the steps then run in the background.
        var activated = true
        if needsActivation {
            activated = activator.waitForTypingPause() && activator.activate(pid: pid)
        }
        return Lease(pid: pid, activated: activated)
    }

    /// Closes a borrow. When it was the last open one, gives focus back to the app that had it before,
    /// but only if `pid` is still the app in front (the user has not switched apps meanwhile).
    func release(_ lease: Lease) {
        enum Next { case none, handOver(pid_t), restore(pid_t) }
        let next: Next = lock.withLock {
            guard !lease.released else { return .none }
            lease.released = true
            if let index = activePIDs.lastIndex(of: lease.pid) {
                activePIDs.remove(at: index)
            }
            if let remaining = activePIDs.last {
                // Another borrow is still open: if this app is the one in front (not the user's switch), hand
                // focus to the app that is still borrowed.
                return activator.frontmostPID() == lease.pid && remaining != lease.pid ? .handOver(remaining) : .none
            }
            let previous = restorePID
            restorePID = nil
            guard let previous, previous != lease.pid else { return .none }
            return .restore(previous)
        }
        switch next {
        case .none:
            break
        case .handOver(let pid):
            if activator.isAlive(pid: pid) { _ = activator.activate(pid: pid) }
        case .restore(let previous):
            // Restore only if this app is still the one in front (otherwise the user moved on by themselves), and
            // only once the user has paused: taking focus mid-sentence would send their keys to the other app.
            if activator.isAlive(pid: previous), activator.frontmostPID() == lease.pid, awaitTypingPause() {
                _ = activator.activate(pid: previous)
            }
        }
        // An app that was hidden before the borrow is hidden again once nothing borrows it.
        if !isBorrowed(pid: lease.pid) { activator.restoreVisibility(pid: lease.pid) }
    }

    /// Polls for a typing pause for up to `timeout` seconds. False when the user is still typing at the end.
    private func awaitTypingPause(timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if activator.waitForTypingPause() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return activator.waitForTypingPause()
    }

    func isBorrowed(pid: pid_t) -> Bool {
        lock.withLock { activePIDs.contains(pid) }
    }

    /// The app that focus will be given back to once the open borrows end (nil when none).
    var pendingRestorePID: pid_t? {
        lock.withLock { activePIDs.isEmpty ? nil : restorePID }
    }

    /// How many borrows are open.
    var openCount: Int {
        lock.withLock { activePIDs.count }
    }
}

/// The frontmost-app operations the borrow needs. Real code uses `WorkspaceFocusActivator`; tests use a fake.
protocol FocusActivating: AnyObject {
    /// The pid of the app in front, nil when unknown.
    func frontmostPID() -> pid_t?
    /// Brings `pid` to the front and waits (capped at about one second) until it is frontmost.
    func activate(pid: pid_t) -> Bool
    /// Whether the process is still running.
    func isAlive(pid: pid_t) -> Bool
    /// Blocks briefly while the user is typing, so focus is not taken in the middle of a word. Returns false
    /// when the user is still typing at the end of the wait, so the caller must not take focus.
    func waitForTypingPause() -> Bool
    /// Hides `pid` again if `activate` had to unhide it.
    func restoreVisibility(pid: pid_t)
}

extension FocusActivating {
    func waitForTypingPause() -> Bool { true }
    func restoreVisibility(pid: pid_t) {}
}

/// Which hidden apps this process unhid for a borrow, and whether the user hid one of them again before the borrow
/// ended. An app the user hid during the borrow is left as the user left it at release.
struct UnhiddenAppLedger {
    private var unhidden: Set<pid_t> = []
    private var hiddenByUser: Set<pid_t> = []

    mutating func recordUnhide(pid: pid_t) {
        unhidden.insert(pid)
    }

    /// A hide by the user (or the system) of an app this process unhid.
    mutating func recordUserHide(pid: pid_t) {
        if unhidden.contains(pid) { hiddenByUser.insert(pid) }
    }

    /// Ends the record for `pid`. True when the app should be hidden again: this process unhid it and the user did not hide it since.
    mutating func takeRehideNeeded(pid: pid_t) -> Bool {
        guard unhidden.remove(pid) != nil else {
            hiddenByUser.remove(pid)
            return false
        }
        return hiddenByUser.remove(pid) == nil
    }
}

/// Ends the synthetic focus that sky_click or sky_key took for an event that was already delivered. A failed teardown
/// is retried once. If it still fails, the caller is told the input went out, so the step is not sent again (a repeated
/// click would click twice).
enum SyntheticFocusTeardown {
    static func endAfterDelivery(_ end: () throws -> Void) throws {
        do {
            try end()
        } catch {
            do {
                try end()
            } catch {
                throw ComputerUseError.message(
                    "The input was delivered, but the target app could not be returned to the background. Do not send this step again; read the app's state first."
                )
            }
        }
    }
}

final class WorkspaceFocusActivator: FocusActivating {
    /// How long to wait for the app to be frontmost with a key window before giving up.
    static let waitCap: TimeInterval = 1.0

    init() {
        // The user hiding an app this process unhid is noted, so the release does not hide it again.
        hideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.unhiddenLock.withLock { self.unhiddenLedger.recordUserHide(pid: app.processIdentifier) }
        }
    }

    private var hideObserver: NSObjectProtocol?

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isAlive(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    private let unhiddenLock = NSLock()
    private var unhiddenLedger = UnhiddenAppLedger()

    /// True only when the user has been hands-off long enough (see `FocusBorrowController.userIdleNeeded`).
    /// Never waits: a busy user is never interrupted, and the steps run in the background instead.
    func waitForTypingPause() -> Bool {
        FocusBorrowController.secondsSinceUserInput() >= FocusBorrowController.userIdleNeeded
    }

    func restoreVisibility(pid: pid_t) {
        guard unhiddenLock.withLock({ unhiddenLedger.takeRehideNeeded(pid: pid) }),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        Self.onMain { app.hide() }
    }

    func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        Self.onMain {
            if app.isHidden {
                self.unhiddenLock.withLock { self.unhiddenLedger.recordUnhide(pid: pid) }
                app.unhide()
            }
            app.activate(options: [.activateIgnoringOtherApps])
        }
        if waitForFront(pid: pid, timeout: 0.4) { return true }
        if let bundleURL = app.bundleURL {
            // The system can refuse a background app's own activate; LaunchServices (like `open -a`) can not be refused.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            let group = DispatchGroup()
            group.enter()
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in group.leave() }
            _ = group.wait(timeout: .now() + 1.5)
        }
        return waitForFront(pid: pid, timeout: Self.waitCap)
    }

    /// Frontmost, and the app's focused window (its key window) exists. Polls every 50 ms up to `timeout`.
    private func waitForFront(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if frontmostPID() == pid, hasFocusedWindow(pid: pid) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return frontmostPID() == pid
    }

    private func hasFocusedWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AppTiming.messagingTimeout(pid: pid, fixed: 0.2))
        var window: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success
            && window != nil
    }

    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}

extension FocusBorrow {
    /// Appended to an error that means the app had to be in front: a batch can borrow focus for it.
    /// Empty when the feature is off or the app is already borrowed.
    static func retryHint(pid: pid_t) -> String {
        guard isEnabled, !isBorrowed(pid: pid) else { return "" }
        return " If nothing else works, those steps can be sent in a batch with \"foreground\": true (only done while the user is away)."
    }
}

extension FocusBorrowController {
    /// How long the user must have been hands-off (no key, click, scroll or mouse move) before focus may be
    /// taken. Taking focus while the user worked put their keys into the borrowed app and raised windows in
    /// front of them. `OPEN_COMPUTER_USE_IDLE_BEFORE_FOREGROUND_S` overrides it (a benchmark on an unattended Mac).
    static let userIdleNeeded: TimeInterval = {
        GodspeedSettings.environment["OPEN_COMPUTER_USE_IDLE_BEFORE_FOREGROUND_S"].flatMap(Double.init) ?? 4
    }()

    /// Seconds since the user's last real input (`hidSystemState`; events this process posts do not count).
    /// Set by tests so they do not depend on whether someone is using the Mac while they run.
    nonisolated(unsafe) static var idleSecondsForTests: TimeInterval?

    static func secondsSinceUserInput() -> TimeInterval {
        if let idleSecondsForTests { return idleSecondsForTests }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .mouseMoved, .leftMouseDragged, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }
}
