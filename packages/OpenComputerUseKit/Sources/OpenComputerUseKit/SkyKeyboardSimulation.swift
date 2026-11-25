import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct SkyKeyboardTarget {
    let windowID: CGWindowID
    let pid: pid_t
}

/// A `cmd`-chord expressed the way AppKit menus advertise their key
/// equivalents: `AXMenuItemCmdChar` plus the `AXMenuItemCmdModifiers` bitmask
/// (1 = shift, 2 = option, 4 = control; 8 marks a non-command equivalent).
struct SkyMenuKeyEquivalent: Equatable, Sendable {
    let character: String
    let modifiers: Int
}

/// Menu-bar key equivalents (`cmd+a`, `cmd+c`, `cmd+t`, ...) are dispatched by
/// AppKit through `NSMenu`, which only fires for the active app. A background
/// target instead needs the menu item invoked directly, which is exactly what
/// the user's keypress would have triggered. Only single-character keys with
/// a command modifier map to a menu equivalent; everything else (arrows,
/// return, plain characters, non-command chords) is delivered as key events.
func skyMenuKeyEquivalent(for parsed: ParsedKeyPress) -> SkyMenuKeyEquivalent? {
    guard parsed.modifiers.contains(where: { $0.flag == .maskCommand }),
          parsed.displayValue.count == 1
    else {
        return nil
    }

    var modifiers = 0
    for modifier in parsed.modifiers {
        switch modifier.flag {
        case .maskShift:
            modifiers |= 1
        case .maskAlternate:
            modifiers |= 2
        case .maskControl:
            modifiers |= 4
        default:
            break
        }
    }
    return SkyMenuKeyEquivalent(character: parsed.displayValue.uppercased(), modifiers: modifiers)
}

func skyMenuItemMatches(cmdChar: String?, cmdModifiers: Int?, enabled: Bool?, equivalent: SkyMenuKeyEquivalent) -> Bool {
    guard let cmdChar, enabled != false else {
        return false
    }
    return cmdChar.uppercased() == equivalent.character && (cmdModifiers ?? 0) == equivalent.modifiers
}

/// What a background-only key press found in the menu bar.
enum MenuEquivalentPress: Equatable {
    case notAMenuItem
    case pressed(reportedDisabled: Bool)
}

/// Appended to a reply when a menu item the closed menu listed as disabled was pressed.
let disabledMenuKeyNote = " (the closed menu listed it as disabled; check the state to see whether it ran)"

/// The error for keys that could not reach a background app, with the route that does work.
/// `action` names the call, such as "press_key 'x'" or "type_text".
func backgroundKeyUnavailableMessage(action: String, reason: String) -> String {
    "\(action) could not reach the background app: \(reason). Command shortcuts can be pressed as menu items with press_menu (for example \"File > Save\"). Other keys need the app focused, which background-only mode never does."
}

/// `press_menu`'s path, "Format > Font > Show Fonts": a menu bar title, then each item down to
/// the command. "File/Save" works too when the path has no ">". A title that itself contains
/// the separator cannot be named; use the array form for it.
func menuPathTitles(_ path: String) throws -> [String] {
    let separator: Character = path.contains(">") ? ">" : "/"
    return try menuPathTitles(path.split(separator: separator, omittingEmptySubsequences: false).map(String.init))
}

/// The array form, ["Format", "Font", "Show Fonts"]: one title per menu level.
func menuPathTitles(_ parts: [String]) throws -> [String] {
    let titles = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    // One title ("File") is allowed: the press then answers with that menu's items instead of failing.
    guard !titles.isEmpty, !titles.contains(where: \.isEmpty) else {
        throw ComputerUseError.invalidArguments("path must name a menu and an item, such as \"File > Save\" or [\"File\", \"Save\"]")
    }
    return titles
}

/// Case-insensitive, ignoring surrounding and repeated spaces, and a trailing "…" or "...".
/// What `press_menu`'s AXPress answer proves. A busy app (a long command, a modal dialog)
/// answers kAXErrorCannotComplete and still runs the queued press once it gets to it, so that
/// answer, like the others an app can give after acting, is not a failure: a retry could run
/// the command twice.
func menuPressError(_ result: AXError, path: String) -> ComputerUseError? {
    switch result {
    case .success:
        return nil
    case .cannotComplete, .failure, .attributeUnsupported, .noValue:
        return .stateUnavailable("\(path) was sent, but the app did not confirm it (AXError \(result.rawValue)); it may still run. Read the app before pressing again: a repeat could run it twice.")
    case .actionUnsupported, .invalidUIElement, .apiDisabled:
        return .notSent("Could not press \(path) (AXError \(result.rawValue)).")
    default:
        return .message("Could not press \(path) (AXError \(result.rawValue)).")
    }
}

func menuTitleMatches(_ requested: String, _ title: String?) -> Bool {
    guard let title else {
        return false
    }
    func normalized(_ value: String) -> String {
        var text = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("…") || text.hasSuffix("...") {
            text = String(text.dropLast(text.hasSuffix("…") ? 1 : 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    return normalized(requested) == normalized(title)
}

/// Owner check for keyboard targets. Unlike `sky_click`, the window does not
/// need to be on-screen: keyboard delivery is process-addressed, so a window on
/// another Space or hidden app is a valid target as long as it still exists
/// and belongs to the snapshot's process.
func skyKeyWindowMatchesTarget(
    windowInfo: [[String: Any]],
    windowID: CGWindowID,
    pid: pid_t
) -> Bool {
    windowInfo.contains { info in
        guard
            let number = info[kCGWindowNumber as String] as? NSNumber,
            number.uint32Value == windowID,
            let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber
        else {
            return false
        }

        return ownerPID.int32Value == pid
    }
}

/// `sky_key`: deliver keyboard input to a background window without changing
/// the real foreground app.
///
/// Keyboard events posted to a pid reach any AppKit window, but Chromium and
/// Electron only insert text while their NSWindow is key (page focus is driven
/// by `OnWindowIsKeyChanged`). The recipe therefore reuses the `sky_click`
/// target-only synthetic-active state, then posts yabai's key-window record
/// pair so the target app makes the window key internally, waits for it to
/// take effect, delivers the ordinary `CGEvent.postToPid` keyboard events (or
/// presses the matching menu item for command chords), and releases the
/// synthetic state again. The real frontmost app keeps its active, key and
/// first-responder state throughout; the target is never raised and the
/// pointer never moves.
/// The user's front app and its key window, captured before a synthetic focus on another
/// app and given key focus again afterwards (Cua's `return_key_to`). Never defocuses
/// the user's app: it only re-posts key-window records, and only while that app is
/// still frontmost.
struct UserKeyWindow: Equatable {
    let pid: pid_t
    let windowID: CGWindowID

    static func capture(excludingPID targetPID: pid_t, spi: SkyLightSPI) -> UserKeyWindow? {
        capture(excludingPID: targetPID, foregroundPID: ForegroundApplication.pid,
                focusedWindow: { focusedWindowID(pid: $0, spi: spi) })
    }

    static func capture(excludingPID targetPID: pid_t, foregroundPID: () throws -> pid_t,
                        focusedWindow: (pid_t) -> CGWindowID?) -> UserKeyWindow? {
        guard let front = try? foregroundPID(), front > 0, front != targetPID,
              let windowID = focusedWindow(front), windowID != 0,
              (try? foregroundPID()) == front
        else { return nil }
        return UserKeyWindow(pid: front, windowID: windowID)
    }

    static func focusedWindowID(pid: pid_t, spi: SkyLightSPI) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AppTiming.messagingTimeout(pid: pid, fixed: 0.2))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return spi.windowID(for: value as! AXUIElement)
    }

    /// Only when the user's app is still in front: a user who switched apps meanwhile is left alone.
    func giveBack(spi: SkyLightSPI) {
        giveBack(foregroundPID: ForegroundApplication.pid,
                 focusedWindow: { Self.focusedWindowID(pid: $0, spi: spi) },
                 returnFocus: { spi.returnKeyFocus(pid: pid, windowID: windowID) })
    }

    func giveBack(foregroundPID: () throws -> pid_t, focusedWindow: (pid_t) -> CGWindowID?,
                  returnFocus: () -> Void) {
        guard pid > 0, windowID != 0, (try? foregroundPID()) == pid,
              focusedWindow(pid) == windowID else { return }
        // AX reads can yield while the person switches apps or windows. A
        // cached NSWorkspace owner must never restore their previous focus.
        guard (try? foregroundPID()) == pid, focusedWindow(pid) == windowID,
              (try? foregroundPID()) == pid else { return }
        returnFocus()
    }
}

/// Which route a key action takes. `sky` posts through SkyLight to the target without
/// bringing it forward; `normal` is the frontmost/borrowed path.
struct KeyRouteContext {
    var backgroundOnly: Bool
    var targetIsFrontmost: Bool
    var borrowed: Bool
    var skyLightAvailable: Bool
    var hasTargetWindow: Bool
    var bundleIdentifier: String?
    /// The focused element sits in a sheet or dialog (save/open panels need real keys).
    var focusInSheetOrDialog: Bool
    /// press_key chord names a menu item that opens a dialog.
    var opensDialogFromMenu: Bool
}

func shouldRouteKeysThroughSkyLight(_ context: KeyRouteContext) -> Bool {
    if context.targetIsFrontmost || context.borrowed { return false }
    guard context.skyLightAvailable, context.hasTargetWindow else { return false }
    // Background-only mode can never borrow, so the SkyLight route is the only one there.
    if context.backgroundOnly { return true }
    if context.focusInSheetOrDialog || context.opensDialogFromMenu { return false }
    // Finder's inline rename editor takes only real keys.
    if context.bundleIdentifier == "com.apple.finder" { return false }
    return true
}

enum SkyKeyboardDispatcher {
    private static let dispatchLock = NSLock()
    static let keyWindowFallbackSettleDefaultMilliseconds = 10.0
    static let releaseSettleDefaultMilliseconds = 10.0
    /// The records and key events are ordered, but target applications can
    /// process them asynchronously. macOS 26 live testing dropped occasional
    /// keys with zero delay, so retain a small cross-version safety margin.
    static let keyWindowFallbackSettle = InputTiming.milliseconds(
        "OPEN_COMPUTER_USE_SKY_KEY_SETTLE_MS",
        default: keyWindowFallbackSettleDefaultMilliseconds
    )
    static let releaseSettle = InputTiming.milliseconds(
        "OPEN_COMPUTER_USE_SKY_KEY_RELEASE_MS",
        default: releaseSettleDefaultMilliseconds
    )

    static func typeText(
        target: SkyKeyboardTarget,
        text: String,
        spi: SkyLightSPI = .shared
    ) throws {
        let delivery = NativeInputDelivery()
        try deliver(to: target, spi: spi, delivery: delivery) {
            try InputSimulation.typeText(text, pid: target.pid, authenticated: true, delivery: delivery)
        }
    }

    /// A keypad needs separate key events, but can reuse one target focus for a short group.
    static func typeKeypad(target: SkyKeyboardTarget, keys: String) throws {
        let delivery = NativeInputDelivery()
        try deliverKeypadGroups(keys) { group, precededByKey in
            try delivery.check()
            if precededByKey { Thread.sleep(forTimeInterval: 0.04) }
            try deliver(to: target, spi: .shared, delivery: delivery) {
                for (offset, key) in group.enumerated() {
                    try delivery.check()
                    if offset > 0 { Thread.sleep(forTimeInterval: 0.04) }
                    try InputSimulation.typeText(String(key), pid: target.pid, authenticated: true, delivery: delivery)
                }
            }
        }
    }

    static func deliverKeypadGroups(_ keys: String, send: (Substring, Bool) throws -> Void) rethrows {
        var start = keys.startIndex
        while start < keys.endIndex {
            let end = keys.index(start, offsetBy: 4, limitedBy: keys.endIndex) ?? keys.endIndex
            try send(keys[start..<end], start != keys.startIndex)
            start = end
        }
    }

    /// Delivers `key` to the target window. Returns true when a menu item was pressed that the
    /// closed menu listed as disabled: the press may have done nothing, so the caller says so.
    @discardableResult
    static func pressKey(
        target: SkyKeyboardTarget,
        key: String,
        spi: SkyLightSPI = .shared,
        allowMenuEquivalent: Bool = true
    ) throws -> Bool {
        // Reject bad key specs before touching the target's focus state.
        let parsed = try KeyPressParser.parse(key)
        let delivery = NativeInputDelivery()
        var reportedDisabled = false
        try deliver(to: target, spi: spi, delivery: delivery) {
            if allowMenuEquivalent, let equivalent = skyMenuKeyEquivalent(for: parsed),
               let found = menuItem(matching: equivalent, pid: target.pid) {
                reportedDisabled = found.reportedDisabled
                try pressMenuItem(found, key: key, delivery: delivery)
                return
            }

            try InputSimulation.pressKey(key, pid: target.pid, authenticated: true, delivery: delivery)
        }
        return reportedDisabled
    }

    /// Background-only `press_key` with key_method auto: a command chord that a menu item names is
    /// pressed as that item, with no key event and no focus change. A raw key event to a window that
    /// is not key is dropped without any error, so this is the only background-safe route for chords.
    static func pressMenuKeyEquivalent(_ key: String, pid: pid_t) throws -> MenuEquivalentPress {
        let delivery = NativeInputDelivery()
        try delivery.check()
        let parsed = try KeyPressParser.parse(key)
        guard let equivalent = skyMenuKeyEquivalent(for: parsed),
              let found = menuItem(matching: equivalent, pid: pid)
        else {
            return .notAMenuItem
        }

        try pressMenuItem(found, key: key, delivery: delivery)
        return .pressed(reportedDisabled: found.reportedDisabled)
    }

    /// The title of the menu item that a command chord presses, read without pressing anything. Nil when
    /// the chord is not a menu equivalent or no menu item carries it.
    static func menuItemTitle(forKey key: String, pid: pid_t) -> String? {
        guard let parsed = try? KeyPressParser.parse(key),
              let equivalent = skyMenuKeyEquivalent(for: parsed),
              let found = menuItem(matching: equivalent, pid: pid)
        else {
            return nil
        }
        return copyValue(found.item, kAXTitleAttribute) as? String
    }

    private static func pressMenuItem(_ found: FoundMenuItem, key: String, delivery: NativeInputDelivery) throws {
        try requireUsableComputerUseSession()
        try delivery.check()
        let result = AXUIElementPerformAction(found.item, kAXPressAction as CFString)
        try recordMenuPressResult(result, key: key, delivery: delivery)
        Thread.sleep(forTimeInterval: 0.1)
    }

    static func recordMenuPressResult(_ result: AXError, key: String, delivery: NativeInputDelivery) throws {
        if let error = menuPressError(result, path: key) {
            // Definite AX refusal does not claim that this press reached the
            // app. Earlier input in the same sequence still remains recorded.
            if error.deliveryState != .notSent { delivery.didPost() }
            throw delivery.failure(error)
        }
        delivery.didPost()
    }

    private static func deliver(
        to target: SkyKeyboardTarget,
        spi: SkyLightSPI,
        delivery: NativeInputDelivery,
        _ body: () throws -> Void
    ) throws {
        do {
            try deliverSequence(to: target, spi: spi, delivery: delivery, body)
        } catch {
            throw delivery.failure(error)
        }
    }

    private static func deliverSequence(
        to target: SkyKeyboardTarget,
        spi: SkyLightSPI,
        delivery: NativeInputDelivery,
        _ body: () throws -> Void
    ) throws {
        try delivery.check()
        try requireUsableComputerUseSession()
        guard spi.capability.isAvailable else {
            throw ComputerUseError.message(
                "key_method 'sky_key' is unavailable: \(spi.capability.unavailableReason)"
            )
        }

        dispatchLock.lock()
        defer {
            dispatchLock.unlock()
        }

        try delivery.check()
        try validate(target: target)
        try delivery.check()

        if try ForegroundApplication.pid() == target.pid {
            try body()
            return
        }

        // The user's own key window, read before any synthetic focus so it can be handed back.
        let userKeyWindow = UserKeyWindow.capture(excludingPID: target.pid, spi: spi)
        let start = TimingLog.now()
        try delivery.check()
        let focusContext = try spi.beginSyntheticTargetFocus(
            targetPID: target.pid,
            targetWindowID: target.windowID
        )
        do {
            try delivery.check()
            try spi.makeSyntheticTargetWindowKey(focusContext)
            TimingLog.log("sky_key.activate", since: start)
            let keyStart = TimingLog.now()
            waitForKeyWindow(target, spi: spi)
            TimingLog.log("sky_key.key_window", since: keyStart)
            let deliverStart = TimingLog.now()
            try delivery.check()
            try body()
            TimingLog.log("sky_key.deliver", since: deliverStart)
            if releaseSettle > 0 {
                Thread.sleep(forTimeInterval: releaseSettle)
            }
        } catch {
            try? spi.endSyntheticTargetFocus(focusContext)
            userKeyWindow?.giveBack(spi: spi)
            throw error
        }
        try SyntheticFocusTeardown.endAfterDelivery { try spi.endSyntheticTargetFocus(focusContext) }
        userKeyWindow?.giveBack(spi: spi)
        TimingLog.log("sky_key.total", since: start)
    }

    private static func waitForKeyWindow(_ target: SkyKeyboardTarget, spi: SkyLightSPI) {
        if keyWindowFallbackSettle > 0 {
            Thread.sleep(forTimeInterval: keyWindowFallbackSettle)
        }
    }

    private static func validate(target: SkyKeyboardTarget) throws {
        // A hidden app (cmd+h) never makes its windows key, so keys would be
        // silently dropped. Fail closed instead of unhiding on the user's behalf.
        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw ComputerUseError.stateUnavailable(
                "sky_key target app is hidden. Unhide it first; sky_key does not change window visibility."
            )
        }

        // `.optionAll`, not `.optionIncludingWindow`: the latter omits windows
        // that are off-screen (hidden app, minimized, or on another Space).
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        guard skyKeyWindowMatchesTarget(
            windowInfo: windowInfo,
            windowID: target.windowID,
            pid: target.pid
        ) else {
            throw ComputerUseError.stateUnavailable(
                "sky_key target window no longer exists or is no longer owned by the target app. Run get_app_state again."
            )
        }
    }

    // MARK: - Menu-bar key equivalents

    /// A menu item that carries the chord. `reportedDisabled` is what the menu said when read.
    struct FoundMenuItem {
        let item: AXUIElement
        let reportedDisabled: Bool
    }

    private static func menuItem(matching equivalent: SkyMenuKeyEquivalent, pid: pid_t) -> FoundMenuItem? {
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = copyValue(application, kAXMenuBarAttribute) else {
            return nil
        }
        func search(trustEnabled: Bool) -> AXUIElement? {
            firstMenuItem(in: menuBar as! AXUIElement, levels: 6) { child in
                copyValue(child, kAXRoleAttribute) as? String == kAXMenuItemRole as String
                    && skyMenuItemMatches(
                        cmdChar: copyValue(child, "AXMenuItemCmdChar") as? String,
                        cmdModifiers: (copyValue(child, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
                        enabled: trustEnabled ? (copyValue(child, kAXEnabledAttribute) as? NSNumber)?.boolValue : true,
                        equivalent: equivalent
                    )
            }
        }
        // A closed menu of a background app keeps the enabled states from when it last opened
        // (File > Save reads disabled after typing), so fall back to an item that only reports
        // disabled. Pressing a really disabled item does nothing; a raw key event to a background
        // app is dropped altogether, which is worse. The caller reports the stale case.
        if let item = search(trustEnabled: true) {
            return FoundMenuItem(item: item, reportedDisabled: false)
        }
        guard let item = search(trustEnabled: false) else {
            return nil
        }
        return FoundMenuItem(item: item, reportedDisabled: (copyValue(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == false)
    }

    /// Depth-first, at most `levels` below `element`. A menu bar title's or a submenu's
    /// items sit two levels down, inside its AXMenu.
    private static func firstMenuItem(in element: AXUIElement, levels: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard levels > 0 else {
            return nil
        }

        for child in copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if matches(child) {
                return child
            }

            if let nested = firstMenuItem(in: child, levels: levels - 1, where: matches) {
                return nested
            }
        }

        return nil
    }

    /// A command named without its menu ("Make Plain Text" for "Format > Make Plain Text"): the one item
    /// with that title anywhere under the menu bar. Two or more matches: nil, so the caller lists the menus.
    static func uniqueMenuItemAnywhere(in menuBar: AXUIElement, title: String) -> AXUIElement? {
        var matches: [AXUIElement] = []
        func walk(_ element: AXUIElement, levels: Int) {
            guard levels > 0, matches.count < 2 else { return }
            for child in copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if isMenuItem(child), menuTitleMatches(title, copyValue(child, kAXTitleAttribute) as? String) {
                    matches.append(child)
                }
                walk(child, levels: levels - 1)
            }
        }
        // Menu bar > title > menu > item > submenu > item: eight levels covers two submenu levels.
        walk(menuBar, levels: 8)
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Menu paths

    /// `press_menu`: press the item at `path` (["Format", "Font", "Show Fonts"]) through
    /// AXPress, with no key or pointer event, so the app can stay in the background. Each
    /// title is looked up among the items of the menu named before it; a miss lists them.
    /// Returns the item's key equivalent as AX reports it (read before the press), so press_menu can learn it.
    @discardableResult
    static func pressMenuItem(path: [String], pid: pid_t) throws -> (commandCharacter: String, modifierMask: Int)? {
        let application = AXUIElementCreateApplication(pid)
        var menuBar: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBar)
        guard read == .success, let menuBar else {
            throw read == .cannotComplete ? appNotAnswering : ComputerUseError.notSent("The app has no menu bar.")
        }
        var item = menuBar as! AXUIElement
        for (depth, title) in path.enumerated() {
            let menu = item
            guard let next = firstMenuItem(in: menu, levels: 2, where: {
                isMenuItem($0) && menuTitleMatches(title, copyValue($0, kAXTitleAttribute) as? String)
            }) ?? (depth == 0 ? uniqueMenuItemAnywhere(in: menu, title: title) : nil) else {
                try requireAnswering(menu)
                let place = depth > 0 ? path[..<depth].joined(separator: " > ")
                    : path.count == 1 ? "any menu (a toggled item, like Make Plain Text vs Make Rich Text, shows only its current title)"
                    : "the menu bar"
                throw ComputerUseError.notSent(
                    "No menu item '\(title)' in \(place). Items: \(menuItemTitles(in: menu).joined(separator: ", "))"
                )
            }
            item = next
        }

        let joined = path.joined(separator: " > ")
        // Pressing a menu title or a submenu would open it on screen instead of running a command.
        if firstMenuItem(in: item, levels: 2, where: isMenuItem) != nil {
            throw ComputerUseError.notSent(
                "\(joined) opens a menu. Add one of its items: \(menuItemTitles(in: item).joined(separator: ", "))"
            )
        }

        // AppKit refreshes a menu's enabled states only when the menu opens, so a closed menu of a
        // background app can report "disabled" for an item that works (File > Save after typing).
        // Pressing a really disabled item does nothing, so press anyway and say what the menu reported.
        let reportedDisabled = (copyValue(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == false
        let keyEquivalent = (copyValue(item, "AXMenuItemCmdChar") as? String).map {
            (commandCharacter: $0, modifierMask: (copyValue(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0)
        }

        try requireUsableComputerUseSession()
        if let error = menuPressError(AXUIElementPerformAction(item, kAXPressAction as CFString), path: joined) {
            throw error
        }
        Thread.sleep(forTimeInterval: 0.1)
        if reportedDisabled { lastPressReportedDisabled = true }
        return keyEquivalent
    }

    /// Set when the last press_menu item had reported itself disabled before it was pressed.
    nonisolated(unsafe) static var lastPressReportedDisabled = false

    /// A busy app answers reads with kAXErrorCannotComplete, which would otherwise read as a
    /// missing menu bar or item.
    private static let appNotAnswering = ComputerUseError.timedOut(
        "The app did not answer accessibility in time (it may be busy or showing a dialog), so nothing was pressed. Try again once it responds.",
        delivery: .notSent
    )

    private static func requireAnswering(_ menu: AXUIElement) throws {
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &children) == .cannotComplete {
            throw appNotAnswering
        }
    }

    private static func isMenuItem(_ element: AXUIElement) -> Bool {
        let role = copyValue(element, kAXRoleAttribute) as? String
        return role == kAXMenuItemRole as String || role == kAXMenuBarItemRole as String
    }

    private static func menuItemTitles(in menu: AXUIElement) -> [String] {
        var titles: [String] = []
        _ = firstMenuItem(in: menu, levels: 2) { element in
            if isMenuItem(element), let title = copyValue(element, kAXTitleAttribute) as? String, !title.isEmpty {
                titles.append(title)
            }
            return false
        }
        return titles
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
