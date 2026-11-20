import Foundation

/// Short, plain events for what changed between two rendered states.
///
/// The main model reads "Save dialog opened" instead of raw tree lines. This is a pure function
/// over two strings: no accessibility calls, no models, no I/O. Element indexes are ignored, so a
/// tree that only renumbers or re-indents gives no events.
///
/// Event order: window title, sheets/dialogs/alerts, field values, checkboxes and toggles,
/// selection, button enabled state, then labelled elements that appeared or were removed.
enum SemanticChanges {
    /// Field values longer than this are cut and end in "…".
    static let maxValueLength = 40

    /// Returns at most `limit` events. Empty when nothing meaningful changed, or when `before`
    /// is empty (there is nothing to compare with).
    static func events(before: String, after: String, limit: Int = 8) -> [String] {
        guard limit > 0, !before.isEmpty else { return [] }
        let oldSnap = Snapshot(text: before)
        let newSnap = Snapshot(text: after)

        var titleEvents: [String] = []
        var dialogEvents: [String] = []
        var fieldEvents: [String] = []
        var toggleEvents: [String] = []
        var selectionEvents: [String] = []
        var buttonEvents: [String] = []
        var appearEvents: [String] = []

        // 1. Window title.
        if let a = oldSnap.title, let b = newSnap.title, a != b {
            titleEvents.append("Window title changed: \(clip(a, to: 60)) → \(clip(b, to: 60))")
        }

        // 2. Sheets, dialogs and alerts that opened or closed.
        let dialogs = pair(oldSnap.dialogs, newSnap.dialogs)
        dialogEvents += dialogs.added.map { "\(dialogName($0)) opened" }
        dialogEvents += dialogs.removed.map { "\(dialogName($0)) closed" }

        // 3. Matched controls: value, checked state and enabled state.
        let controls = pair(oldSnap.tracked, newSnap.tracked)
        for (a, b) in controls.matched {
            if a.isToggle {
                if let x = a.checked, let y = b.checked, x != y {
                    toggleEvents.append("\(cap(describe(a))) turned \(y ? "on" : "off")")
                }
            } else if a.role == "button" {
                if a.isDisabled != b.isDisabled {
                    buttonEvents.append("\(cap(describe(a))) \(b.isDisabled ? "disabled" : "enabled")")
                }
            } else if let x = a.value, let y = b.value, x != y {
                fieldEvents.append(fieldChange(a, from: x, to: y))
            }
        }

        // 4. Selection: compare the sets of selected elements, then name the first one on each side.
        let oldSelected = oldSnap.tracked.filter(\.isSelected)
        let newSelected = newSnap.tracked.filter(\.isSelected)
        if Set(oldSelected.map(\.key)) != Set(newSelected.map(\.key)) {
            let from = oldSelected.first?.label ?? ""
            let to = newSelected.first?.label ?? ""
            switch (from.isEmpty, to.isEmpty) {
            case (true, true): selectionEvents.append("Selection changed")
            case (true, false): selectionEvents.append("Selected: \(clip(to))")
            case (false, true): selectionEvents.append("Selection cleared: \(clip(from))")
            case (false, false): selectionEvents.append("Selection changed: \(clip(from)) → \(clip(to))")
            }
        }

        // 5. Labelled elements that appeared or disappeared. Dialog contents are left out,
        // because the dialog event already covers them.
        appearEvents += controls.added
            .filter { !$0.insideDialog && !$0.label.isEmpty }
            .map { "New \(describe($0))" }
        appearEvents += controls.removed
            .filter { !$0.insideDialog && !$0.label.isEmpty }
            .map { "Removed \(describe($0))" }

        let all = titleEvents + dialogEvents + fieldEvents + toggleEvents
            + selectionEvents + buttonEvents + appearEvents
        return Array(all.prefix(limit))
    }

    /// One line joining the first few events, or nil when nothing meaningful changed.
    static func summary(before: String, after: String, limit: Int = 3) -> String? {
        let items = events(before: before, after: after, limit: limit)
        return items.isEmpty ? nil : items.joined(separator: "; ")
    }

    // MARK: - Words

    /// Roles that are more than one word. Matched before the first word is taken as the role.
    private static let multiWordRoles = [
        "secure text field", "pop up button", "radio button", "check box", "combo box",
        "text field", "text area", "menu item", "menu button", "search field", "static text",
        "list item", "outline row", "scroll area", "layout area", "split group", "tab group",
        "web area", "color well", "disclosure triangle", "date field",
    ]

    private static let dialogRoles: Set<String> = ["dialog", "sheet", "alert"]
    private static let toggleRoles: Set<String> = ["check box", "radio button", "toggle", "switch"]
    private static let textRoles: Set<String> = ["text", "static text"]

    /// Roles that carry no event of their own: containers, plain text, the window and decoration.
    private static let untrackedRoles: Set<String> = [
        "window", "group", "generic", "section", "splitter", "layout area", "scroll area",
        "image", "separator", "text", "static text",
    ]

    /// Trait words that may appear in parentheses, such as `(w:str)` or `(selected, focused)`.
    private static let knownTraits: Set<String> = [
        "selected", "focused", "offscreen", "expanded", "disabled", "settable", "hidden",
        "w", "w:str", "w:bool", "w:float", "string", "boolean", "float",
    ]

    /// Words in a label that mark a field as secret. Its value is never printed.
    private static let secretWords: Set<String> = ["password", "passcode", "passphrase", "pin", "otp", "secret", "token"]

    // MARK: - Items

    /// One element line, reduced to what the events need.
    private struct Item {
        var role: String
        var label: String
        var value: String?
        var traits: Set<String>
        var depth: Int
        /// True when the element sits under a sheet, dialog or alert.
        var insideDialog = false

        /// Matching key: same role and same label. Element numbers are not part of it.
        var key: String { role + "|" + label }
        var isSelected: Bool { traits.contains("selected") }
        var isDisabled: Bool { traits.contains("disabled") }
        var isToggle: Bool { toggleRoles.contains(role) }

        /// `true` or `false` for an on/off value, nil for anything else.
        var checked: Bool? {
            let v = value?.lowercased() ?? ""
            switch v {
            case "on", "1", "true", "checked": return true
            case "off", "0", "false", "unchecked": return false
            default: return nil
            }
        }

        /// Secure fields, and labels with a secret word (such as "PIN code"), never show values.
        var isSecret: Bool {
            if role == "secure text field" { return true }
            let words = label.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            return words.contains { secretWords.contains($0) }
        }
    }

    /// The parsed lines of one rendered state.
    private struct Snapshot {
        var title: String?
        var elements: [Item] = []

        /// Everything except dialogs and untracked decoration. Dialog contents are kept here.
        var tracked: [Item] { elements.filter { !untrackedRoles.contains($0.role) && !dialogRoles.contains($0.role) } }
        var dialogs: [Item] { elements.filter { dialogRoles.contains($0.role) && !$0.insideDialog } }

        init(text: String) {
            var dialogDepth: Int?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if title == nil, line.hasPrefix("Window: \"") { title = windowTitle(line) }
                guard var item = parse(line) else { continue }
                // Leave the dialog once a line is no deeper than where it started.
                if let depth = dialogDepth, item.depth <= depth { dialogDepth = nil }
                item.insideDialog = dialogDepth != nil
                if dialogDepth == nil, dialogRoles.contains(item.role) { dialogDepth = item.depth }
                elements.append(item)
            }
            // A dialog with no title of its own takes the first text line under it.
            for i in elements.indices where dialogRoles.contains(elements[i].role) && elements[i].label.isEmpty {
                var j = i + 1
                while j < elements.count, elements[j].depth > elements[i].depth {
                    if textRoles.contains(elements[j].role), !elements[j].label.isEmpty {
                        elements[i].label = elements[j].label
                        break
                    }
                    j += 1
                }
            }
        }
    }

    /// Reads `Window: "Title", App: Name.` and returns the title.
    private static func windowTitle(_ line: String) -> String {
        let rest = line.dropFirst("Window: \"".count)
        if let end = rest.range(of: "\", App:") { return String(rest[..<end.lowerBound]) }
        if let end = rest.lastIndex(of: "\"") { return String(rest[..<end]) }
        return String(rest)
    }

    /// Reads one element line such as `\t\t12 text field To = a@x.com (w:str)`.
    /// Returns nil for header lines, which have no element number.
    private static func parse(_ line: String) -> Item? {
        let indent = line.prefix(while: { $0 == "\t" || $0 == " " })
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.dropFirst(indent.count)
        // An element line starts with its number and a space.
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, body.dropFirst(digits.count).first == " " else { return nil }
        let text = body.dropFirst(digits.count + 1)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " Value: ", with: " = ")

        var role = String(text.prefix(while: { $0 != " " }))
        for candidate in multiWordRoles where text == candidate || text.hasPrefix(candidate + " ") {
            role = candidate
            break
        }
        let remainder = text.dropFirst(role.count).trimmingCharacters(in: .whitespaces)

        // Trait groups can sit before or after the label, so take them out first.
        let (plain, traits) = splitTraits(remainder)
        var label = plain
        var value: String?
        if let split = plain.range(of: " = ") {
            label = String(plain[..<split.lowerBound])
            value = String(plain[split.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if plain.hasSuffix(" =") {
            label = String(plain.dropLast(2))
            value = ""
        }
        return Item(
            role: role,
            label: label.trimmingCharacters(in: .whitespaces),
            value: value,
            traits: traits,
            depth: depth
        )
    }

    /// Separates `(trait, trait)` groups from the text. Other parentheses stay in the text.
    private static func splitTraits(_ text: String) -> (text: String, traits: Set<String>) {
        // Splitting on both brackets puts plain text at even offsets and group contents at odd ones.
        let pieces = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "(" || $0 == ")" })
        var plain = ""
        var traits = Set<String>()
        for (offset, piece) in pieces.enumerated() {
            if offset % 2 == 0 {
                plain += piece
                continue
            }
            let tokens = piece.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.allSatisfy(knownTraits.contains) {
                traits.formUnion(tokens)
            } else {
                plain += "(" + piece + ")"
            }
        }
        return (plain.trimmingCharacters(in: .whitespaces), traits)
    }

    // MARK: - Pairing

    private struct Pairing {
        var matched: [(old: Item, new: Item)] = []
        var removed: [Item] = []
        var added: [Item] = []
    }

    /// Pairs items with the same key, in order. Items left over on one side are added or removed.
    /// Pairing ignores position, so a reordered list gives no events.
    private static func pair(_ old: [Item], _ new: [Item]) -> Pairing {
        var waiting: [String: [Int]] = [:]
        for (index, item) in old.enumerated() { waiting[item.key, default: []].append(index) }
        var used = Set<Int>()
        var result = Pairing()
        for item in new {
            if var queue = waiting[item.key], !queue.isEmpty {
                let index = queue.removeFirst()
                waiting[item.key] = queue
                used.insert(index)
                result.matched.append((old[index], item))
            } else {
                result.added.append(item)
            }
        }
        result.removed = old.indices.filter { !used.contains($0) }.map { old[$0] }
        return result
    }

    // MARK: - Wording

    private static func dialogName(_ item: Item) -> String {
        item.label.isEmpty ? cap(item.role) : "\(clip(item.label, to: 60)) \(item.role)"
    }

    /// `button "Send"`, or just the role when there is no label.
    private static func describe(_ item: Item) -> String {
        item.label.isEmpty ? item.role : "\(item.role) \"\(clip(item.label, to: 60))\""
    }

    private static func fieldName(_ item: Item) -> String {
        item.label.isEmpty ? cap(item.role) : item.label
    }

    private static func fieldChange(_ item: Item, from: String, to: String) -> String {
        if item.isSecret { return "\(fieldName(item)) changed" }
        return "\(fieldName(item)): \(display(from)) → \(display(to))"
    }

    private static func display(_ value: String) -> String {
        value.isEmpty ? "(empty)" : clip(value)
    }

    /// Cuts text to `length` characters and adds "…" when it was longer.
    private static func clip(_ text: String, to length: Int = maxValueLength) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }

    private static func cap(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
