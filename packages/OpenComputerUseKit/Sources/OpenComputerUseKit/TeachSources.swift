import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Pure helpers and accessibility reads for the live teach source. Nothing here stores anything, and the
/// clipboard is never read.
enum TeachLive {
    /// Controls a click should resolve to. A click often lands on a label inside one of these.
    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXTextField",
        "AXTextArea", "AXSecureTextField", "AXComboBox", "AXMenuItem", "AXCell", "AXRow", "AXTab",
    ]

    /// "AXPopUpButton" -> "pop up button".
    static func roleWords(_ axRole: String) -> String {
        let name = axRole.hasPrefix("AX") ? String(axRole.dropFirst(2)) : axRole
        var words = ""
        for character in name {
            if character.isUppercase, !words.isEmpty { words += " " }
            words += String(character).lowercased()
        }
        return words
    }

    /// Text that is safe to record as typed text: no control characters (return, tab, escape, ...).
    static func printableText(_ text: String) -> String? {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return text
    }

    /// The characters of a key press, unless it is a shortcut (command or control held).
    static func typedText(of event: CGEvent) -> String? {
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return nil }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return printableText(String(decoding: buffer.prefix(min(length, buffer.count)), as: UTF16.self))
    }

    static func runningApp(named name: String) -> TeachMode.AppTarget? {
        let match = NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular
                && (app.localizedName?.caseInsensitiveCompare(name) == .orderedSame
                    || app.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame)
        }
        guard let match else { return nil }
        return TeachMode.AppTarget(pid: match.processIdentifier, name: match.localizedName ?? name)
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The label a control is known by: its title, else its description, placeholder or help text.
    static func label(of element: AXUIElement) -> String {
        for attribute in ["AXTitle", "AXDescription", "AXPlaceholderValue", "AXHelp"] {
            if let text = string(element, attribute), !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return ""
    }

    /// Role, label and parent label of an element. Secure fields are flagged so their text is never kept.
    static func target(for element: AXUIElement) -> TeachTarget {
        let secure = isSecureTextField(subrole: string(element, "AXSubrole"))
        let parent = elementAttribute(element, "AXParent").map(label(of:)) ?? ""
        return TeachTarget(role: secure ? "secure text field" : roleWords(string(element, "AXRole") ?? ""),
                           label: label(of: element), parent: parent, nearby: [], secure: secure)
    }

    /// The control a click landed on: the hit element, or its nearest control ancestor.
    static func control(atHit hit: AXUIElement) -> AXUIElement {
        var current = hit
        for _ in 0..<4 {
            if controlRoles.contains(string(current, "AXRole") ?? "") { return current }
            guard let parent = elementAttribute(current, "AXParent") else { break }
            current = parent
        }
        return hit
    }

    /// Menu titles from the menu bar item down to the item, e.g. ["File", "Save"].
    static func menuPath(of item: AXUIElement) -> [String] {
        var titles: [String] = []
        var current: AXUIElement? = item
        while let node = current, titles.count < 8 {
            let role = string(node, "AXRole") ?? ""
            if role == "AXMenuBar" { break }
            if role == "AXMenuItem" || role == "AXMenuBarItem", let title = string(node, "AXTitle"), !title.isEmpty {
                titles.insert(title, at: 0)
            }
            current = elementAttribute(node, "AXParent")
        }
        return titles
    }
}

/// Owns the run loop that the observer and the event tap are scheduled on.
private final class TeachLoopHost: @unchecked Sendable {
    private let sources: [CFRunLoopSource]
    let ready = DispatchSemaphore(value: 0)
    private(set) var loop: CFRunLoop?

    init(sources: [CFRunLoopSource]) { self.sources = sources }

    /// Runs on the teach thread. Signals `ready` once its sources are scheduled.
    func run() {
        let current = CFRunLoopGetCurrent()
        for source in sources { CFRunLoopAddSource(current, source, .defaultMode) }
        loop = current
        ready.signal()
        CFRunLoopRun()
    }
}

private let liveAXCallback: AXObserverCallback = { _, element, name, refcon in
    guard let refcon else { return }
    Unmanaged<LiveTeachSource>.fromOpaque(refcon).takeUnretainedValue().axNotification(element, name as String)
}

private let liveTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon, type == .keyDown || type == .leftMouseDown {
        Unmanaged<LiveTeachSource>.fromOpaque(refcon).takeUnretainedValue().tapEvent(type, event)
    }
    // Listen-only: the event is passed on unchanged.
    return Unmanaged.passUnretained(event)
}

/// The live `TeachInputSource`: accessibility notifications for one app, plus a listen-only event tap for
/// clicks and key presses. A click is resolved by hit testing and kept only if it lands in the target app.
/// Value changes are reported only where the app's observer delivers them; typing is also seen by the tap.
final class LiveTeachSource: TeachInputSource {
    private var pid: pid_t = 0
    private var deliver: ((TeachInput) -> Void)?
    private var observer: AXObserver?
    private var tap: CFMachPort?
    private var host: TeachLoopHost?

    func start(pid: pid_t, deliver: @escaping (TeachInput) -> Void) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        self.pid = pid
        self.deliver = deliver
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var created: AXObserver?
        guard AXObserverCreate(pid, liveAXCallback, &created) == .success, let created else {
            self.deliver = nil
            return false
        }
        let app = AXUIElementCreateApplication(pid)
        for name in [kAXFocusedUIElementChangedNotification, kAXValueChangedNotification,
                     kAXMenuItemSelectedNotification, kAXWindowCreatedNotification] {
            _ = AXObserverAddNotification(created, app, name as CFString, refcon)
        }

        let mask: CGEventMask = (1 << CGEventMask(CGEventType.keyDown.rawValue))
            | (1 << CGEventMask(CGEventType.leftMouseDown.rawValue))
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: liveTapCallback, userInfo: refcon),
              let tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            self.deliver = nil
            return false
        }

        let host = TeachLoopHost(sources: [AXObserverGetRunLoopSource(created), tapSource])
        Thread { host.run() }.start()
        host.ready.wait()
        self.observer = created
        self.tap = tap
        self.host = host
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop = host?.loop { CFRunLoopStop(loop) }
        host = nil
        observer = nil
        tap = nil
        deliver = nil
    }

    // MARK: Callbacks (run on the teach thread)

    fileprivate func axNotification(_ element: AXUIElement, _ name: String) {
        guard let deliver, TeachLive.pid(of: element) == pid else { return }
        let event: TeachEvent
        switch name {
        case kAXFocusedUIElementChangedNotification:
            event = .focus(TeachLive.target(for: element))
        case kAXValueChangedNotification:
            let target = TeachLive.target(for: element)
            event = .value(target, target.secure ? nil : TeachLive.string(element, "AXValue"))
        case kAXMenuItemSelectedNotification:
            event = .menu(TeachLive.menuPath(of: element))
        case kAXWindowCreatedNotification:
            event = .windowCreated
        default:
            return
        }
        deliver(TeachInput(pid: pid, event: event))
    }

    fileprivate func tapEvent(_ type: CGEventType, _ event: CGEvent) {
        guard let deliver else { return }
        if type == .keyDown {
            // Key presses belong to whichever app is frontmost; the recorder keeps only the target's.
            guard let text = TeachLive.typedText(of: event) else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            deliver(TeachInput(pid: frontmost, event: .typed(text)))
        } else if type == .leftMouseDown {
            let point = event.location
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return }
            let control = TeachLive.control(atHit: hit)
            guard TeachLive.pid(of: control) == pid else { return }
            deliver(TeachInput(pid: pid, event: .press(TeachLive.target(for: control))))
        }
    }
}
