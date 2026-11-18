import AppKit
import Foundation

/// Renames a file through Finder's scripting when the accessibility path cannot (Finder's inline name editor
/// takes no keys while Finder is in the background). Used only after the normal step failed in Finder.
enum FinderRename {
    static func attempt(tool: String, arguments: [String: Any]) -> ToolCallResult? {
        guard let app = arguments["app"] as? String, app.lowercased().contains("finder") || app == "com.apple.finder" else { return nil }
        let newName: String
        let target: String
        switch tool {
        case "type_text":
            guard let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 255, !text.contains("/"), !text.contains("\n") else { return nil }
            newName = text
            target = "item 1 of (get selection)"
            // A name without an extension only renames a folder that was just made ("untitled folder").
            if !text.contains(".") {
                let check = "tell application id \"com.apple.finder\" to return name of item 1 of (get selection)"
                guard let current = AppleEventsGate.run(check, bundle: "com.apple.finder")?.stringValue,
                      current.lowercased().hasPrefix("untitled folder") else { return nil }
            }
        case "set_value":
            guard let value = (arguments["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), isFileName(value),
                  let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), isFileName(label) else { return nil }
            newName = value
            target = "item \(quoted(label)) of (target of Finder window 1)"
        default:
            return nil
        }
        let source = """
        tell application id "com.apple.finder"
            set theItem to \(target)
            set oldName to name of theItem
            set name of theItem to \(quoted(newName))
            return oldName
        end tell
        """
        guard let old = AppleEventsGate.run(source, bundle: "com.apple.finder")?.stringValue else { return nil }
        return .text("Renamed \"\(old)\" to \"\(newName)\" (through Finder, in the background). No Return needed.")
    }

    /// A plain file name: no path separators, not empty, not a key name.
    static func isFileName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 255 && !text.contains("/") && !text.contains("\n") && text.contains(".")
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Finder's copy, cut and paste of files, done through Finder's scripting: in the background the keys reach
/// a Finder window that is not key and do nothing. ⌘C / ⌘X remember the selected items; ⌘V (or ⌥⌘V) copies or
/// moves them into the folder the front Finder window shows.
enum FinderClipboard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: (paths: [String], move: Bool)?

    static func handle(key normalized: String) -> String? {
        switch normalized {
        case "cmd+c", "cmd+x":
            let source = """
            tell application id "com.apple.finder"
                set out to ""
                repeat with i in (get selection)
                    set out to out & (POSIX path of (i as alias)) & linefeed
                end repeat
                return out
            end tell
            """
            guard let text = AppleEventsGate.run(source, bundle: "com.apple.finder")?.stringValue else { return nil }
            let paths = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            guard !paths.isEmpty else { return "Nothing is selected in Finder; click the item first." }
            let move = normalized == "cmd+x"
            lock.withLock { held = (paths, move) }
            let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return (move ? "Cut " : "Copied ") + names + ". Open the destination folder, then press cmd+v to " + (move ? "move" : "copy") + " it there."
        case "cmd+o", "cmd+down":
            return FinderOpen.selection()
        case "cmd+[", "cmd+up":
            let source = """
            tell application id "com.apple.finder"
                set target of Finder window 1 to (container of (target of Finder window 1))
                return name of (target of Finder window 1)
            end tell
            """
            return AppleEventsGate.run(source, bundle: "com.apple.finder")?.stringValue.map { "Went up to \($0)." }
        case "cmd+shift+n":
            let source = """
            tell application id "com.apple.finder"
                set f to make new folder at (target of Finder window 1)
                select f
                return name of f
            end tell
            """
            return AppleEventsGate.run(source, bundle: "com.apple.finder")?.stringValue
                .map { "Made a new folder \"\($0)\" (selected). Now type_text its name; no Return needed." }
        case "cmd+v", "alt+cmd+v":
            guard let pending = lock.withLock({ held }) else { return nil }
            let move = pending.move || normalized != "cmd+v"
            let list = pending.paths.map { "(POSIX file " + FinderRename.quoted($0) + " as alias)" }.joined(separator: ", ")
            let verb = move ? "move" : "duplicate"
            // Into the one selected folder when a folder is selected (what the model means by "click the
            // destination, then paste"), else into the folder the window shows.
            let source = """
            tell application id "com.apple.finder"
                set dest to (target of Finder window 1)
                set sel to (get selection)
                if (count of sel) is 1 then
                    set one to item 1 of sel
                    if class of one is folder and {\(list)} does not contain (one as alias) then set dest to one
                end if
                \(verb) {\(list)} to dest
                return POSIX path of (dest as alias)
            end tell
            """
            guard let dest = AppleEventsGate.run(source, bundle: "com.apple.finder")?.stringValue else { return nil }
            if move { lock.withLock { held = nil } }
            let names = pending.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return (move ? "Moved " : "Copied ") + names + " into " + dest + "."
        default:
            return nil
        }
    }
}

/// A click on a label that is not in the window but is an item of the app's menus ("Make Plain Text",
/// "New Folder", "Duplicate"): the menu path that holds it, top menu first. Nil when no single item matches.
enum MenuItemLookup {
    static func path(for label: String, pid: pid_t) -> [String]? {
        let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        guard !wanted.isEmpty else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        func value(_ e: AXUIElement, _ a: String) -> AnyObject? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        func title(_ e: AXUIElement) -> String { (value(e, kAXTitleAttribute) as? String) ?? "" }
        func children(_ e: AXUIElement) -> [AXUIElement] { (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func clean(_ t: String) -> String {
            t.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        guard let bar = value(app, kAXMenuBarAttribute) else { return nil }
        var hits: [[String]] = []
        for top in children(bar as! AXUIElement) {
            let topTitle = title(top)
            guard !topTitle.isEmpty, topTitle != "Apple" else { continue }
            for menu in children(top) {
                for item in children(menu) {
                    let itemTitle = title(item)
                    if clean(itemTitle) == wanted { hits.append([topTitle, itemTitle]) }
                    for sub in children(item) {
                        for subItem in children(sub) where clean(title(subItem)) == wanted {
                            hits.append([topTitle, itemTitle, title(subItem)])
                        }
                    }
                }
            }
        }
        return hits.count == 1 ? hits[0] : nil
    }
}

/// Opening in Finder without focus: a double click on a row, or ⌘O / ⌘↓ on the selection. A folder opens in the
/// same window (as a double click does); a file opens in its app.
enum FinderOpen {
    static func item(named label: String) -> String? {
        run(target: "item \(FinderRename.quoted(label)) of (target of Finder window 1)")
    }

    static func selection() -> String? {
        run(target: "item 1 of (get selection)")
    }

    private static func run(target: String) -> String? {
        let source = """
        tell application id "com.apple.finder"
            set t to \(target)
            if class of t is folder or class of t is disk then
                set target of Finder window 1 to t
                return "Opened folder " & (name of t) & " in the Finder window."
            else
                open t
                return "Opened " & (name of t) & "."
            end if
        end tell
        """
        return AppleEventsGate.run(source, bundle: "com.apple.finder")?.stringValue
    }
}
