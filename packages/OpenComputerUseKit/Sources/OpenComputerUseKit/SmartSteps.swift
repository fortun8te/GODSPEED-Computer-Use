import AppKit
import CoreGraphics
import Foundation

/// Smart steps: tools that finish a multi-step job in one call (`save_as`, `open`), and the rules the
/// dispatcher uses to heal a miss (label, stale index, no visible effect) and to report a dialog.
///
/// The pure rules live here as plain functions so tests can run them without an app. The glue that
/// reads the accessibility tree or drives an app is at the bottom and takes the service as a parameter.
enum SmartSteps {
    static let saveAsName = "save_as"
    static let openName = "open"
    static let names: Set<String> = [saveAsName, openName]

    /// Actions after which a sheet, dialog or alert that opened is reported.
    static let actionTools: Set<String> = [
        "click", "press_key", "press_menu", "type_text", "set_value", "select_text",
        "perform_secondary_action", "scroll", "drag",
    ]

    /// Actions whose no-effect result is looked at: a harmless one is retried once inside a focus borrow, any
    /// other is only reported (see `repeatSafeRoles`). set_value and type_text verify themselves by read-back.
    static let retryTools: Set<String> = ["click", "press_key", "perform_secondary_action"]

    /// Roles a second click cannot harm: it only focuses or selects.
    static let repeatSafeRoles: Set<String> = [
        "textfield", "textarea", "searchfield", "securetextfield", "combobox", "textentryarea",
        "radiobutton", "tabbutton", "tab", "row", "cell", "outlinerow", "statictext",
    ]

    /// Phrases the healing code looks for in error messages raised by the service.
    static let notFoundPhrase = "no element labelled"
    static let ambiguousPhrase = "matches several controls"
    static let stalePhrase = "no longer has the identity"

    // MARK: - Paths

    /// "~/x" becomes "<home>/x"; other paths are returned unchanged.
    static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Splits a full file path into its folder and file name. nil when the path is not absolute, ends in a
    /// slash, or names no file.
    static func splitSavePath(_ path: String) -> (folder: String, name: String)? {
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
        let nsPath = path as NSString
        let name = nsPath.lastPathComponent
        guard !name.isEmpty else { return nil }
        var folder = nsPath.deletingLastPathComponent
        if folder.isEmpty { folder = "/" }
        return (folder, name)
    }

    /// Whether text is a web address (a scheme such as https:// or a www. host).
    static func looksLikeURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("://") || lower.hasPrefix("www.")
    }

    enum OpenPlan: Equatable {
        case url(String)
        case file(path: String, app: String?)
        case app(String)
        /// An app's own link (x-apple.systempreferences:…, mailto:, a deep link): handed to macOS, not the browser.
        case appLink(String)
    }

    /// A file with this name in the home folder or one or two folders below it (not Library), for a "No file"
    /// reply that points to the real place. Nil when there is none or several.
    static func nearbyFile(named name: String, home: String = NSHomeDirectory()) -> String? {
        guard !name.isEmpty, name != "/", !name.contains("/") else { return nil }
        // One level below home only, plain folders only (no links, mounts or cloud folders, which can hang),
        // on its own thread and given up on after half a second: this once froze the whole agent.
        final class Box: @unchecked Sendable { var hits: [String] = [] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let fm = FileManager.default
            let homeURL = URL(fileURLWithPath: home)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey]
            let items = (try? fm.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for item in items where !["Library", "Applications", "Movies", "Music", "Pictures"].contains(item.lastPathComponent) {
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                      values.isSymbolicLink != true, values.isVolume != true else { continue }
                let candidate = item.appendingPathComponent(name).path
                if fm.fileExists(atPath: candidate) { box.hits.append(candidate) }
                if box.hits.count > 1 { break }
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.5) == .success else { return nil }
        return box.hits.count == 1 ? box.hits[0] : nil
    }

    /// A non-web scheme such as `x-apple.systempreferences:com.apple.Desktop-Settings.extension`.
    static func appLinkScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), !text.hasPrefix("/"), !text.hasPrefix("~") else { return false }
        let scheme = text[..<colon].lowercased()
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) else { return false }
        return !["http", "https", "file"].contains(scheme)
    }

    /// What `open` should do: a URL goes to the browser, a path opens in its default app (or `app`), and an
    /// app name alone launches that app. nil when none of the three is given.
    static func openPlan(path: String?, url: String?, app: String?, home: String) -> OpenPlan? {
        let url = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !url.isEmpty { return appLinkScheme(url) ? .appLink(url) : .url(url) }
        if !path.isEmpty {
            if appLinkScheme(path) { return .appLink(path) }
            if looksLikeURL(path) { return .url(path) }
            return .file(path: expandHome(path, home: home), app: app.isEmpty ? nil : app)
        }
        if !app.isEmpty { return .app(app) }
        return nil
    }

    /// Normalized text for comparing names: no accents, no case, no spaces or punctuation.
    static func normalizedName(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// The installed app whose bundle name matches `query` (ignoring case, spaces, punctuation, accents and a
    /// ".app" suffix). nil when none matches.
    static func appBundleName(query: String, candidates: [String]) -> String? {
        var wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.lowercased().hasSuffix(".app") { wanted = String(wanted.dropLast(4)) }
        let key = normalizedName(wanted)
        guard !key.isEmpty else { return nil }
        return candidates.first { normalizedName($0) == key }
    }

    // MARK: - Label close match

    struct LabelCandidate: Equatable {
        let index: Int
        let name: String
    }

    enum CloseMatch: Equatable {
        case unique(LabelCandidate)
        /// Several controls match equally well; the names are listed so the model can choose.
        case ambiguous([String])
        case none
    }

    /// Ranks controls against a label the model wrote. Tiers, strongest first: the same text once normalized,
    /// then a name that starts with the label (or a name the label starts with, at least 4 characters), then
    /// a name that contains a label of at least 3 characters. A tier with exactly one hit wins; a tier with
    /// several hits is returned as ambiguous and nothing weaker is tried.
    static func closeMatch(query: String, candidates: [LabelCandidate]) -> CloseMatch {
        let wanted = normalizedName(query)
        guard wanted.count >= 2 else { return .none }

        var seen = Set<Int>()
        let pool: [(candidate: LabelCandidate, key: String)] = candidates.compactMap { candidate in
            guard seen.insert(candidate.index).inserted else { return nil }
            let key = normalizedName(candidate.name)
            return key.isEmpty ? nil : (candidate, key)
        }

        let tiers: [(String) -> Bool] = [
            { $0 == wanted },
            // Short labels are too easy to find inside other words ("No" in "Notifications"), and a longer
            // label must not fall back to a much shorter name ("Delete draft" is not "Delete").
            { (wanted.count >= 3 && $0.hasPrefix(wanted)) || (wanted.hasPrefix($0) && $0.count >= 4 && $0.count * 3 >= wanted.count * 2) },
            { wanted.count >= 4 && $0.contains(wanted) },
        ]

        for tier in tiers {
            let hits = pool.filter { tier($0.key) }
            if hits.count == 1, let only = hits.first {
                return .unique(only.candidate)
            }
            if hits.count > 1 {
                var names: [String] = []
                for hit in hits where !names.contains(hit.candidate.name) {
                    names.append(hit.candidate.name)
                }
                return .ambiguous(Array(names.prefix(8)))
            }
        }
        return .none
    }

    // MARK: - Retry decision

    /// Whether an action that reported success should be retried once inside a focus borrow: the window is in
    /// the background, the read-back shows nothing changed, focus borrowing is on, and no borrow is open yet.
    static func shouldRetryWithoutEffect(
        actionSucceeded: Bool,
        before: [String]?,
        after: [String]?,
        appIsFrontmost: Bool,
        borrowingAllowed: Bool,
        alreadyBorrowed: Bool
    ) -> Bool {
        guard actionSucceeded, !appIsFrontmost, borrowingAllowed, !alreadyBorrowed else { return false }
        guard let before, let after else { return false }
        return before == after
    }

    // MARK: - Dialog line

    struct Node: Equatable {
        let index: Int
        let role: String?
        let subrole: String?
        let name: String?
        let frame: CGRect?
    }

    static let dialogRoles: Set<String> = ["sheet", "dialog", "alert", "systemdialog", "systemfloatingdialog"]
    static let fieldRoles: Set<String> = ["textfield", "textarea", "combobox", "popupbutton", "searchfield"]
    static let buttonRoles: Set<String> = ["button"]

    /// Role spelling without the "AX" prefix, lower case, no spaces: "AXTextField" becomes "textfield".
    static func roleKey(_ role: String?) -> String {
        var key = (role ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if key.hasPrefix("ax") { key.removeFirst(2) }
        return key
    }

    /// "A dialog opened: <title>. Its fields: ... buttons: ..." with at most 12 names each.
    static func formatDialogLine(title: String, fields: [String], buttons: [String]) -> String {
        func list(_ names: [String]) -> String {
            guard !names.isEmpty else { return "none" }
            return names.prefix(12).map { String($0.prefix(80)) }.joined(separator: ", ")
        }
        let shownTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "A dialog opened: \(shownTitle.isEmpty ? "untitled" : shownTitle). Its fields: \(list(fields)). buttons: \(list(buttons))."
        // Models fought save panels step by step (Go to folder, typing a path into the document); one call does it.
        let isSave = shownTitle.lowercased().contains("save") || fields.contains { $0.lowercased().hasPrefix("save as") }
        return isSave ? line + " To save under a name and folder in one step, use save_as {app, path}." : line
    }

    /// The dialog line for the first sheet, dialog or alert in `nodes`, or nil when none is open.
    /// Contents are the nodes whose frame lies inside the dialog's frame. Without a frame, the next 60 nodes
    /// in index order are used instead, so names may come from outside the dialog in that case.
    static func dialogLine(in nodes: [Node]) -> String? {
        let sorted = nodes.sorted { $0.index < $1.index }
        guard let dialog = sorted.first(where: {
            dialogRoles.contains(roleKey($0.role)) || dialogRoles.contains(roleKey($0.subrole))
        }) else { return nil }

        let inside: [Node]
        if let frame = dialog.frame, !frame.isEmpty {
            inside = sorted.filter { node in
                guard node.index != dialog.index, let box = node.frame else { return false }
                return frame.contains(CGPoint(x: box.midX, y: box.midY))
            }
        } else {
            inside = Array(sorted.drop(while: { $0.index <= dialog.index }).prefix(60))
        }

        let title = dialog.name
            ?? inside.first(where: { roleKey($0.role) == "statictext" })?.name
            ?? ""
        let fields = inside.filter { fieldRoles.contains(roleKey($0.role)) }.map { $0.name ?? "unnamed field" }
        let buttons = inside.filter { buttonRoles.contains(roleKey($0.role)) }.compactMap { $0.name }
        return formatDialogLine(title: title, fields: fields, buttons: buttons)
    }

    // MARK: - Glue (reads the app through the service)

    /// The name a control is known by: its title, else its accessibility name.
    static func name(of record: ElementRecord) -> String? {
        let text = record.title ?? record.identity?.name
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }

    static func nodes(of snapshot: AppSnapshot) -> [Node] {
        snapshot.elements.values.map { record in
            Node(index: record.index, role: record.role, subrole: record.identity?.subrole,
                 name: name(of: record), frame: record.localFrame)
        }
    }

    /// The app's current accessibility state, read now (not from a cache). nil when the read fails.
    static func freshSnapshot(app: String, service: ComputerUseService) -> AppSnapshot? {
        let observation = SnapshotObservationOptions(includeAX: true, includeScreenshot: false)
        guard (try? service.getAppState(app: app, observation: observation)) != nil else { return nil }
        return try? service.currentSnapshot(for: app, needScreenshot: false)
    }

    /// One text field of a save panel, as far as choosing the name field needs it.
    struct SaveFieldCandidate: Equatable {
        /// Lowercased title, description, identifier and placeholder, joined.
        let label: String
        let isSearch: Bool
        let settable: Bool
    }

    /// The name field among a save panel's text fields: settable, not the search or tags field, and the one labelled
    /// as the name when a label says so. Otherwise the first usable field.
    static func preferredNameFieldIndex(_ fields: [SaveFieldCandidate]) -> Int? {
        let usable = fields.indices.filter { index in
            let field = fields[index]
            return field.settable && !field.isSearch && !field.label.contains("search") && !field.label.contains("tag")
        }
        return usable.first { fields[$0].label.contains("name") || fields[$0].label.contains("save as") } ?? usable.first
    }

    private static func axElement(_ attribute: String, of node: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axElements(_ attribute: String, of node: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func axText(_ attribute: String, of node: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Lists of files: their rows are never the save panel's controls, so the search does not enter them.
    private static let fileListRoles: Set<String> = ["AXOutline", "AXTable", "AXBrowser"]

    private static func isSheetLike(_ node: AXUIElement) -> Bool {
        if axText(kAXRoleAttribute, of: node) == kAXSheetRole as String { return true }
        let subrole = axText(kAXSubroleAttribute, of: node)
        return subrole == "AXDialog" || subrole == "AXSystemDialog"
    }

    /// Every sheet or dialog `pid` shows. A background app often has no focused window, so the focused and main
    /// windows come first, then the whole window list. A window counts when it is a dialog itself, and so do the
    /// sheets inside it (a Replace question sits inside the save panel's own sheet).
    static func sheetCandidates(pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var windows: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] as [String] {
            if let window = axElement(attribute, of: application) { windows.append(window) }
        }
        windows += axElements(kAXWindowsAttribute as String, of: application)
        var found: [AXUIElement] = []
        func add(_ node: AXUIElement) {
            if !found.contains(where: { CFEqual($0, node) }) { found.append(node) }
        }
        func collect(in node: AXUIElement, depth: Int) {
            guard depth > 0 else { return }
            for child in axElements(kAXChildrenAttribute as String, of: node) where isSheetLike(child) {
                add(child)
                collect(in: child, depth: depth - 1)
            }
        }
        for window in windows {
            if isSheetLike(window) { add(window) }
            collect(in: window, depth: 3)
        }
        return found
    }

    /// Whether a sheet or dialog of `pid` is showing.
    static func sheetIsOpen(pid: pid_t) -> Bool {
        !sheetCandidates(pid: pid).isEmpty
    }

    /// The text fields under `node`, not descending into lists of files.
    private static func collectTextFields(in node: AXUIElement, depth: Int, into fields: inout [AXUIElement]) {
        let role = axText(kAXRoleAttribute, of: node)
        if role == kAXTextFieldRole as String { fields.append(node) }
        guard depth > 0, !fileListRoles.contains(role ?? "") else { return }
        for child in axElements(kAXChildrenAttribute as String, of: node) {
            collectTextFields(in: child, depth: depth - 1, into: &fields)
        }
    }

    private static func isSettableValue(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// The name field of a save panel sheet, if it has one.
    private static func saveNameField(in sheet: AXUIElement) -> AXUIElement? {
        var fields: [AXUIElement] = []
        collectTextFields(in: sheet, depth: 8, into: &fields)
        let candidates = fields.map { field in
            SaveFieldCandidate(
                label: [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier", "AXPlaceholderValue"]
                    .compactMap { axText($0 as String, of: field) }
                    .joined(separator: " ")
                    .lowercased(),
                isSearch: axText(kAXSubroleAttribute, of: field) == "AXSearchField",
                settable: isSettableValue(field)
            )
        }
        guard let index = preferredNameFieldIndex(candidates) else { return nil }
        return fields[index]
    }

    /// The sheet of `pid` that is a save panel (it has a name field), with that field.
    private static func savePanel(pid: pid_t) -> (sheet: AXUIElement, nameField: AXUIElement)? {
        for sheet in sheetCandidates(pid: pid) {
            if let nameField = saveNameField(in: sheet) { return (sheet, nameField) }
        }
        return nil
    }

    /// Whether the sheet's "Where" folder choice shows `folder` (the popup shows only the folder's name).
    static func whereMatches(popupValue: String?, folder: String) -> Bool {
        let folderName = (folder as NSString).lastPathComponent
        guard let popupValue, !folderName.isEmpty, folderName != "/" else { return false }
        return popupValue.trimmingCharacters(in: .whitespacesAndNewlines) == folderName
    }

    /// Fills the save sheet with accessibility only: the full path goes into the name field first, and is used when the
    /// panel keeps it. Otherwise the name alone goes in, and the folder must already be the sheet's "Where" choice, or be
    /// picked from that menu. When neither holds, this throws before Save, so nothing lands in the sheet's own folder.
    private static func fillSavePanel(
        _ panel: (sheet: AXUIElement, nameField: AXUIElement),
        folder: String,
        name: String,
        full: String,
        app: String
    ) throws {
        if setFieldValue(panel.nameField, full), axText(kAXValueAttribute, of: panel.nameField) == full {
            return
        }
        guard setFieldValue(panel.nameField, name), axText(kAXValueAttribute, of: panel.nameField) == name else {
            throw ComputerUseError.message("Could not type the file name into the save sheet of \(app), so nothing was saved. Read the app's state and fill it in with set_value.")
        }
        Thread.sleep(forTimeInterval: 0.2)
        guard let popup = wherePopup(in: panel.sheet) else {
            throw ComputerUseError.message("The save sheet of \(app) does not show its folder choice, so nothing was saved. Choose \(folder) in the sheet, then save again.")
        }
        if whereMatches(popupValue: axText(kAXValueAttribute, of: popup), folder: folder) { return }
        if pickWhereFolder(popup, folderName: (folder as NSString).lastPathComponent),
           whereMatches(popupValue: axText(kAXValueAttribute, of: popup), folder: folder) {
            return
        }
        throw ComputerUseError.message("The save sheet of \(app) is set to \"\(axText(kAXValueAttribute, of: popup) ?? "another folder")\", and cannot be pointed at \(folder) through accessibility, so nothing was saved. Choose that folder in the sheet, then save again.")
    }

    private static func setFieldValue(_ field: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success
    }

    /// The "Where:" folder popup of a save sheet, found by its label (not the file format popup).
    private static func wherePopup(in sheet: AXUIElement) -> AXUIElement? {
        var popups: [AXUIElement] = []
        collectPopups(in: sheet, depth: 8, into: &popups)
        return popups.first { popup in
            [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier"]
                .compactMap { axText($0 as String, of: popup) }
                .joined(separator: " ")
                .lowercased()
                .contains("where")
        }
    }

    private static func collectPopups(in node: AXUIElement, depth: Int, into popups: inout [AXUIElement]) {
        let role = axText(kAXRoleAttribute, of: node)
        if role == kAXPopUpButtonRole as String { popups.append(node) }
        guard depth > 0, !fileListRoles.contains(role ?? "") else { return }
        for child in axElements(kAXChildrenAttribute as String, of: node) {
            collectPopups(in: child, depth: depth - 1, into: &popups)
        }
    }

    /// Opens the "Where" popup and presses the item named `folderName`. A menu that lacks it is closed again.
    private static func pickWhereFolder(_ popup: AXUIElement, folderName: String) -> Bool {
        guard AXUIElementPerformAction(popup, kAXPressAction as CFString) == .success else { return false }
        Thread.sleep(forTimeInterval: 0.3)
        let menus = axElements(kAXChildrenAttribute as String, of: popup)
        for menu in menus {
            for item in axElements(kAXChildrenAttribute as String, of: menu) where axText(kAXTitleAttribute, of: item) == folderName {
                guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return false }
                Thread.sleep(forTimeInterval: 0.3)
                return true
            }
        }
        for menu in menus { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        return false
    }

    /// First button under `root` whose title `matches`, not descending into lists of files.
    private static func findButton(in root: AXUIElement, depth: Int, matches: (String) -> Bool) -> AXUIElement? {
        let role = axText(kAXRoleAttribute, of: root)
        if role == kAXButtonRole as String, let title = axText(kAXTitleAttribute, of: root), matches(title) { return root }
        guard depth > 0, !fileListRoles.contains(role ?? "") else { return nil }
        for child in axElements(kAXChildrenAttribute as String, of: root) {
            if let found = findButton(in: child, depth: depth - 1, matches: matches) { return found }
        }
        return nil
    }

    /// Presses the first button titled `matches` within `sheets`. False when none was found or the press failed.
    private static func pressButton(in sheets: [AXUIElement], matches: (String) -> Bool) -> Bool {
        for sheet in sheets {
            if let button = findButton(in: sheet, depth: 8, matches: matches) {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    static func waitForDialog(app: String, service: ComputerUseService, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let snapshot = freshSnapshot(app: app, service: service),
               dialogLine(in: nodes(of: snapshot)) != nil {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    static func isEscapeKey(_ value: Any?) -> Bool {
        guard let key = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return key == "escape" || key == "esc"
    }

    /// The Cancel button of the first open sheet, dialog or alert, or nil when no dialog or no single Cancel.
    static func dialogCancelButton(in nodes: [Node]) -> Int? {
        let sorted = nodes.sorted { $0.index < $1.index }
        guard let dialog = sorted.first(where: {
            dialogRoles.contains(roleKey($0.role)) || dialogRoles.contains(roleKey($0.subrole))
        }) else { return nil }
        // A state covers one window, so a single Cancel after the dialog is the dialog's. With frames, it
        // must also lie inside the dialog.
        let cancels = sorted.filter { node in
            guard node.index > dialog.index, buttonRoles.contains(roleKey(node.role)),
                  node.name?.trimmingCharacters(in: .whitespaces).lowercased() == "cancel" else { return false }
            guard let frame = dialog.frame, !frame.isEmpty, let box = node.frame else { return true }
            return frame.contains(CGPoint(x: box.midX, y: box.midY))
        }
        return cancels.count == 1 ? cancels[0].index : nil
    }

    static let textFieldRoles: Set<String> = ["textfield", "textarea", "combobox", "searchfield"]

    /// The text field a caption such as "Save As:" names, when the caption also matched other controls.
    /// One field whose own name matches wins; else, inside an open sheet or dialog, its only text field, or its
    /// first one when the caption ends in ":" (a save panel's name field comes first). nil when unclear.
    static func captionField(for wanted: String, in nodes: [Node]) -> Int? {
        let sorted = nodes.sorted { $0.index < $1.index }
        let fields = sorted.filter { textFieldRoles.contains(roleKey($0.role)) && roleKey($0.subrole) != "searchfield" }
        let named = fields.filter { node in
            guard let name = node.name else { return false }
            if case .unique = closeMatch(query: wanted, candidates: [LabelCandidate(index: node.index, name: name)]) { return true }
            return false
        }
        if named.count == 1 { return named[0].index }
        guard let dialog = sorted.first(where: {
            dialogRoles.contains(roleKey($0.role)) || dialogRoles.contains(roleKey($0.subrole))
        }) else { return nil }
        let inside = fields.filter { node in
            guard node.index > dialog.index else { return false }
            guard let frame = dialog.frame, !frame.isEmpty, let box = node.frame else { return true }
            return frame.contains(CGPoint(x: box.midX, y: box.midY))
        }
        if inside.count == 1 { return inside[0].index }
        if wanted.trimmingCharacters(in: .whitespaces).hasSuffix(":"), let first = inside.first { return first.index }
        return nil
    }

    /// Resolves a label the normal way failed on: a close match among the current controls, then a text query.
    /// Returns nil when neither finds exactly one control. Throws the list when several controls match.
    static func healLabel(
        _ wanted: String,
        app: String,
        service: ComputerUseService,
        forValue: Bool = false
    ) throws -> (record: ElementRecord, note: String)? {
        guard let snapshot = freshSnapshot(app: app, service: service) else { return nil }
        let records = snapshot.elements.values.sorted { $0.index < $1.index }
        let candidates = records.map { LabelCandidate(index: $0.index, name: name(of: $0) ?? "") }

        switch closeMatch(query: wanted, candidates: candidates) {
        case .unique(let candidate):
            if let record = records.first(where: { $0.index == candidate.index }) {
                return (record, "No element is labelled \"\(wanted)\"; used the close match \"\(candidate.name)\".")
            }
        case .ambiguous(let names):
            // A value goes into a field, never a button or the sheet: "Save As:" also matched "Save" there.
            if forValue, let index = captionField(for: wanted, in: nodes(of: snapshot)),
               let record = records.first(where: { $0.index == index }) {
                return (record, "\"\(wanted)\" also matched buttons; used the text field it captions.")
            }
            throw ComputerUseError.invalidArguments(
                "\"\(wanted)\" \(ambiguousPhrase): \(names.joined(separator: ", ")). Give one of these exact labels, or an element_index."
            )
        case .none:
            break
        }

        // A text query finds controls whose title is only part of the label, or whose title is hidden.
        if let matches = try? service.query(app: app, text: wanted, limit: 5),
           let list = matches["matches"] as? [[String: Any]], list.count == 1,
           let index = list[0]["index"] as? Int {
            let latest = (try? service.currentSnapshot(for: app, needScreenshot: false)) ?? snapshot
            if let record = latest.elements.values.first(where: { $0.index == index }) {
                return (record, "No element is labelled \"\(wanted)\"; a text search found the only match, \"\(name(of: record) ?? "unnamed")\".")
            }
            // Found outside the shown part of the window (a long sidebar): its query number acts on it directly.
            if index >= 1_000_000 {
                let title = (list[0]["title"] as? String) ?? wanted
                let record = ElementRecord(index: index, identifier: list[0]["identifier"] as? String, element: nil, localFrame: nil,
                                           role: list[0]["role"] as? String, title: title, rawActions: [], prettyActions: [])
                return (record, "Found \"\(title)\" by text search.")
            }
        }
        return nil
    }

    /// `save_as`: File > Save As… (File > Save… when the item is missing), then the folder, the name and Save,
    /// all inside a focus borrow. The file is checked on disk before the reply says it was saved.
    /// Saves the app's front document to `path` through AppleScript. False when the app is not scriptable or
    /// the save failed (the caller then uses the save sheet). Never activates the app.
    static func scriptedSave(bundle: String, path: String) -> Bool {
        let scriptable: Set<String> = [
            "com.apple.TextEdit", "com.apple.Preview", "com.apple.iWork.Pages", "com.apple.iWork.Numbers",
            "com.apple.iWork.Keynote", "com.apple.ScriptEditor2",
        ]
        guard scriptable.contains(bundle) else { return false }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "tell application id \(quoted(bundle)) to save document 1 in POSIX file \(quoted(path))"
        return AppleEventsGate.run(source, bundle: bundle) != nil
    }

    static func saveAs(app: String, path rawPath: String, service: ComputerUseService, home: String = NSHomeDirectory()) throws -> ToolCallResult {
        let full = expandHome(rawPath.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
        guard let parts = splitSavePath(full) else {
            throw ComputerUseError.invalidArguments("path must be a full path to the file, e.g. ~/Desktop/notes.txt")
        }
        let descriptor = try AppDiscovery.resolveRunning(app)
        let fileManager = FileManager.default
        let modifiedBefore = (try? fileManager.attributesOfItem(atPath: full)[.modificationDate]) as? Date

        // First choice: the app's own scripting (TextEdit, Preview, Pages, Numbers, Keynote, Script Editor and
        // others). It saves the front document straight to the path, as the type the extension names, with no
        // dialog, no keys and no focus change. A sheet that is already open is closed by it as well.
        if !sheetIsOpen(pid: descriptor.pid), let bundle = NSRunningApplication(processIdentifier: descriptor.pid)?.bundleIdentifier,
           scriptedSave(bundle: bundle, path: full) {
            let deadline = Date().addingTimeInterval(3)
            while !fileManager.fileExists(atPath: full), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            let modified = (try? fileManager.attributesOfItem(atPath: full)[.modificationDate]) as? Date
            if fileManager.fileExists(atPath: full), modifiedBefore == nil || modified != modifiedBefore {
                return .text("Saved \(full).")
            }
        }

        // No keys and no focus change: the sheet is driven through accessibility only (set the name field to the
        // full path, press Save), so the user can keep working in another app. A save panel accepts a full path
        // in its name field.
        if savePanel(pid: descriptor.pid) == nil {
            do {
                _ = try service.pressMenu(app: app, titles: ["File", "Save As"])
            } catch {
                _ = try service.pressMenu(app: app, titles: ["File", "Save"])
            }
            let openDeadline = Date().addingTimeInterval(3)
            while savePanel(pid: descriptor.pid) == nil, Date() < openDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard savePanel(pid: descriptor.pid) != nil else {
                throw ComputerUseError.message("The save sheet did not open, so nothing was saved. Check the app's state.")
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        // The panel is re-found from the app's sheets each time, so a background app's panel is still reached.
        guard let panel = savePanel(pid: descriptor.pid) else {
            throw ComputerUseError.message("Could not find the name field of the save sheet. Read the app's state and fill it in with set_value.")
        }
        try fillSavePanel(panel, folder: parts.folder, name: parts.name, full: full, app: app)
        Thread.sleep(forTimeInterval: 0.2)
        guard pressButton(in: [panel.sheet], matches: { $0 == "Save" }) else {
            throw ComputerUseError.message("Could not find the Save button of the save sheet, so nothing was saved. Read the app's state.")
        }
        // A follow-up question is answered the way a save wants it: Replace, and the extension the path names
        // (never another format's "Use .rtf").
        let extensionName = (full as NSString).pathExtension.lowercased()
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.6)
            if fileManager.fileExists(atPath: full), !sheetIsOpen(pid: descriptor.pid) { break }
            let answered = pressButton(in: sheetCandidates(pid: descriptor.pid)) { buttonTitle in
                let lowered = buttonTitle.lowercased()
                return lowered == "replace" || (!extensionName.isEmpty && lowered.hasPrefix("use") && lowered.contains(".\(extensionName)"))
            }
            if !answered { break }
        }

        // Saved means the file exists and was written just now (a Replace sheet leaves the old file in place).
        let deadline = Date().addingTimeInterval(5)
        func isSaved() -> Bool {
            guard fileManager.fileExists(atPath: full) else { return false }
            let modified = (try? fileManager.attributesOfItem(atPath: full)[.modificationDate]) as? Date
            return modifiedBefore == nil || modified != modifiedBefore
        }
        while !isSaved(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if isSaved() {
            return .text("Saved \(full).")
        }
        var reply = "Save was sent, but \(full) is not on disk."
        reply += sheetIsOpen(pid: descriptor.pid)
            ? " A sheet is still open in \(app) (a question such as Replace or a file format choice): read the app's state and click its answer by label."
            : " Check the app's state."
        return .text(reply, isError: true)
    }

    /// `open`: a URL goes through the browser tool, a path opens in its default app (or in `app`) and an app
    /// name launches it. Nothing is activated (NSWorkspace configuration activates = false).
    static func open(
        arguments: [String: Any],
        browser: ([String: Any]) throws -> ToolCallResult,
        home: String = NSHomeDirectory()
    ) throws -> ToolCallResult {
        func text(_ key: String) -> String? { arguments[key] as? String }
        guard let plan = openPlan(path: text("path"), url: text("url"), app: text("app"), home: home) else {
            throw ComputerUseError.missingArgument("path, url or app")
        }

        switch plan {
        case .appLink(let link):
            guard let target = URL(string: link) else { throw ComputerUseError.invalidArguments("not a valid link: \(link)") }
            try openWorkspace { done in
                NSWorkspace.shared.open(target, configuration: quietConfiguration()) { _, error in done(error) }
            }
            return .text("Opened \(link).")

        case .url(let url):
            guard BrowserBridge.isAvailable else {
                throw ComputerUseError.message("Opening a web address needs the browser tool (Chrome with Open Browser Use).")
            }
            let reply = try browser(["action": "open", "url": url])
            return ToolCallResult(content: [.text("Opened \(url).")] + reply.content, isError: reply.isError)

        case .file(let path, let appName):
            guard FileManager.default.fileExists(atPath: path) else {
                throw ComputerUseError.message("No file at \(path)." + (nearbyFile(named: (path as NSString).lastPathComponent).map { " Found one at \($0); use that path." } ?? ""))
            }
            let fileURL = URL(fileURLWithPath: path)
            if let appName {
                guard let appURL = applicationURL(named: appName) else {
                    throw ComputerUseError.message("No app named \(appName) is installed.")
                }
                try openWorkspace { done in
                    NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: quietConfiguration()) { _, error in
                        done(error)
                    }
                }
                return .text("Opened \(path) in \(appName).")
            }
            try openWorkspace { done in
                NSWorkspace.shared.open(fileURL, configuration: quietConfiguration()) { _, error in
                    done(error)
                }
            }
            return .text("Opened \(path) in its default app.")

        case .app(let name):
            guard let appURL = applicationURL(named: name) else {
                throw ComputerUseError.message("No app named \(name) is installed.")
            }
            // Already running: nothing to send. Re-opening a document app with no window open made it show the
            // system Open dialog, which freezes the app until someone clicks Cancel.
            if let bundle = Bundle(url: appURL)?.bundleIdentifier,
               !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
                if ["com.apple.TextEdit", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote"].contains(bundle),
                   let count = AppleEventsGate.run("tell application id \"\(bundle)\" to count documents", bundle: bundle)?.int32Value, count == 0 {
                    _ = AppleEventsGate.run("tell application id \"\(bundle)\" to make new document", bundle: bundle)
                    return .text("\(name) is open; it had no document, so a new blank one was made.")
                }
                return .text("\(name) is open.")
            }
            try openWorkspace { done in
                NSWorkspace.shared.openApplication(at: appURL, configuration: quietConfiguration()) { _, error in
                    done(error)
                }
            }
            return .text("Opened \(name).")
        }
    }

    private static func quietConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        return configuration
    }

    /// Runs an NSWorkspace call and waits (up to 5 s) for its completion, turning its error into a message.
    private static func openWorkspace(_ start: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        let outcome = OpenOutcome()
        start { error in
            outcome.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else {
            throw ComputerUseError.message("macOS did not answer the open request in time.")
        }
        if let failure = outcome.error {
            throw ComputerUseError.message("macOS could not open it: \(failure.localizedDescription)")
        }
    }

    /// The bundle of an installed app, by name or bundle identifier. nil when none is found.
    static func applicationURL(named query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return url
        }
        // Finder and a few other system apps live in CoreServices, not in an Applications folder.
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
                       "/System/Library/CoreServices", "/Applications/Utilities"]
        var bundles: [String: URL] = [:]
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" {
                bundles[url.deletingPathExtension().lastPathComponent] = url
            }
        }
        guard let name = appBundleName(query: trimmed, candidates: Array(bundles.keys)) else { return nil }
        return bundles[name]
    }

    static func messageText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func isNotFound(_ error: Error) -> Bool { messageText(error).contains(notFoundPhrase) }
    static func isAmbiguous(_ error: Error) -> Bool { messageText(error).contains(ambiguousPhrase) }
    static func isStale(_ error: Error) -> Bool { messageText(error).contains(stalePhrase) }
}

/// The error an NSWorkspace open reported, handed from its completion handler to the waiting caller.
private final class OpenOutcome: @unchecked Sendable {
    var error: Error?
}

/// Carries the exact snapshot built by a service action through the synchronous dispatcher.
final class NativeActionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: AppSnapshot?

    func record(_ snapshot: AppSnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    func read(before: [String]? = nil, fallback: () -> AppSnapshot?) -> AppSnapshot? {
        let captured = lock.withLock { snapshot }
        // An early no-change read may precede a delayed effect. Leave the existing
        // fresh-read and retry decision in place for this case.
        if let captured, captured.treeLines != before,
           DoneCheck.supportsAbsenceCheck(captured.treeLines.joined(separator: "\n")) {
            return captured
        }
        return fallback()
    }
}

/// Notes one call collects while it runs: healing notes go before the reply, a dialog line after it.
final class SmartLog {
    // Internal evidence for the batch that owns this step log.
    var afterActionSnapshot: AppSnapshot?
    private var leading: [String] = []
    private var trailing: [String] = []

    func note(_ text: String) {
        leading.append(text)
    }

    func tail(_ text: String) {
        trailing.append(text)
    }

    /// Every note so far, healing notes first, then the dialog line.
    var notes: [String] { leading + trailing }

    func apply(to result: ToolCallResult) -> ToolCallResult {
        guard !leading.isEmpty || !trailing.isEmpty else { return result }
        let before = leading.map { ToolResultContentItem.text($0) }
        let after = trailing.map { ToolResultContentItem.text($0) }
        return ToolCallResult(
            content: before + result.content + after, isError: result.isError,
            batchReceipt: result.batchReceipt, failureCode: result.failureCode,
            browserObservationURL: result.browserObservationURL,
            browserContinuationTabID: result.browserContinuationTabID,
            browserPreviewPages: result.browserPreviewPages,
            browserFullObservationText: result.browserFullObservationText
        )
    }
}
