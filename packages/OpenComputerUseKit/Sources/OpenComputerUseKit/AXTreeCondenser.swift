import Foundation

/// Shrinks the rendered accessibility tree (GODSPEED's state text) before a model reads it.
///
/// Input is the compact text: one tab per tree level and lines such as `\t\t12 button Play`.
/// Every line the condenser keeps has its element index unchanged. It never removes a line
/// that is selected, focused, settable, an action-capable control, or that carries secondary actions.
///
/// Rules, each switchable in `Options`:
/// 1. `dropStructuralNoise`: an unlabeled container line (group, generic, section, scroll area,
///    splitter, layout area) with no text, traits or actions is removed. Its children move up one level.
/// 2. `collapseRuns`: a run of sibling rows, cells, list items or links with the same role and
///    indentation keeps its first `keepRuns` and last `keepLast` blocks. Removable middle blocks become
///    one `…(N more <role>s like these; use query to find one)` line. A block is kept when any of its
///    lines is protected. Fewer than two removable blocks means nothing is collapsed.
/// 3. `truncateText`: text lines longer than `maxTextLength` characters end in `…`.
/// 4. `dedupeText`: a text line with the same indentation and text as the text line directly before it is removed.
/// 5. Header lines (before the first tree line) are never changed.
/// 6. `dropHidden`: lines marked hidden or offscreen, and bare images or separators, go unless they hold state or an action.
/// 7. `maxDescriptionLength`, 8. `dropRepeatedProperties`: shorter lines. 1b. `unwrapSingleChild`: one-child wrappers go.
/// 9. `maxCharacters`: a total budget with a visible cut line. A run's removable middle is folded in separate
/// markers around any row that carries state (selected, checked, a value), and such a row is never folded.
enum AXTreeCondenser {
    struct Options: Equatable {
        /// Rule 1: remove unlabeled container lines and re-indent their children.
        var dropStructuralNoise = true
        /// Rule 2: collapse long runs of sibling rows, cells, list items and links.
        var collapseRuns = true
        /// Rule 2: sibling blocks kept at the start of a run.
        var keepRuns = 6
        /// Rule 2: sibling blocks kept at the end of a run.
        var keepLast = 2
        /// Rule 3: truncate long text lines.
        var truncateText = true
        /// Rule 3: maximum characters of text kept before `…`.
        var maxTextLength = 160
        /// Rule 4: remove consecutive duplicate text lines.
        var dedupeText = true
        /// Rule 6: remove hidden or offscreen lines (and what is under them) that hold no state or action,
        /// plus unnamed decoration (bare image, separator) with nothing under it.
        var dropHidden = true
        /// Rule 1b: remove a neutral group that has one child and no name of its own (or the child's name).
        var unwrapSingleChild = true
        /// Rule 7: cut `Description:` text to this many characters. 0 turns it off.
        var maxDescriptionLength = 80
        /// Rule 8: remove a `Help:` or `Description:` that repeats the previous sibling's.
        var dropRepeatedProperties = true
        /// Rule 9: total size of the output in characters. Beyond it only lines with state or an action stay,
        /// up to 1.5 times the budget, and a visible line says how many were cut. 0 turns it off.
        var maxCharacters = 12_000

        static let `default` = Options()
    }

    static func condense(_ text: String, options: Options = .default) -> String {
        condenseLines(text, options: options).text
    }

    /// Compact native observation retains labelled context and all visible control evidence.
    /// Only bare structural wrappers and decoration are omitted. Repeated rows, offscreen
    /// controls and state lines survive regardless of their position or the output length.
    static func compactObservation(_ text: String, preserving indexes: Set<String> = []) -> String {
        let parts = text.components(separatedBy: "\n")
        guard let firstTree = parts.firstIndex(where: { parseLine($0).isTree }) else { return text }

        let header = parts[..<firstTree]
        let packedIndentation = header.contains("[tab=4 w=settable]")
        let lines = parts[firstTree...].map(parseLine)
        var output = Array(header)
        var removedDepths: [Int] = []
        for (position, original) in lines.enumerated() {
            guard original.isTree else {
                output.append(original.raw)
                continue
            }

            let depth = packedIndentation ? original.width : original.indent.count
            while let last = removedDepths.last, last >= depth {
                removedDepths.removeLast()
            }

            let isBare = original.rest == original.role && !indexes.contains(original.index)
            let isLeaf = position + 1 == lines.count || !lines[position + 1].isTree
                || lines[position + 1].width <= original.width
            if isBare && wrapperRoles.contains(original.role) {
                removedDepths.append(depth)
                continue
            }
            if isBare && isLeaf && decorationRoles.contains(original.role) {
                continue
            }

            var line = original
            let adjustedDepth = depth - removedDepths.count
            line.indent = packedIndentation
                ? String(repeating: "\t", count: adjustedDepth / 4) + String(repeating: " ", count: adjustedDepth % 4)
                : String(original.indent.prefix(adjustedDepth))
            output.append(line.render())
        }
        return output.joined(separator: "\n")
    }

    /// Same output as `condense`, plus line counts before and after (header included).
    static func condenseWithStats(_ text: String, options: Options = .default) -> (text: String, before: Int, after: Int) {
        condenseLines(text, options: options)
    }

    // MARK: - Pipeline

    private static func condenseLines(_ text: String, options: Options) -> (text: String, before: Int, after: Int) {
        guard !text.isEmpty else { return ("", 0, 0) }

        var parts = text.components(separatedBy: "\n")
        let hasTrailingNewline = parts.count > 1 && parts.last == ""
        if hasTrailingNewline { parts.removeLast() }

        // Rule 5: the header is everything before the first tree line.
        let firstTree = parts.firstIndex(where: { parseLine($0).isTree }) ?? parts.count
        let header = Array(parts[..<firstTree])
        var lines = parts[firstTree...].map { parseLine($0) }

        if options.dropHidden { lines = dropHidden(lines) }
        if options.dropStructuralNoise { lines = dropStructuralNoise(lines, unwrapSingleChild: options.unwrapSingleChild) }
        if options.dedupeText { lines = dedupeText(lines) }
        if options.dropRepeatedProperties { lines = dropRepeatedProperties(lines) }
        if options.collapseRuns { lines = collapseRuns(lines, options: options) }
        if options.truncateText { lines = truncateText(lines, limit: options.maxTextLength) }
        if options.maxDescriptionLength > 0 { lines = cutDescriptions(lines, limit: options.maxDescriptionLength) }
        if options.maxCharacters > 0 {
            lines = applyBudget(lines, headerCount: header.reduce(0) { $0 + $1.count + 1 }, budget: options.maxCharacters)
        }

        let output = header + lines.map { $0.render() }
        let joined = output.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        return (joined, parts.count, output.count)
    }

    // MARK: - Parsing

    private struct Line {
        var raw: String = ""
        var isTree = false
        var indent = ""
        var index = ""
        /// Everything after `<index> `, for example `button Play (selected)`.
        var rest = ""
        var role = ""

        /// Tabs count four columns, spaces one. Only used for ordering lines by depth.
        var width: Int { indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }

        func render() -> String { isTree ? indent + index + " " + rest : raw }
    }

    private static func parseLine(_ line: String) -> Line {
        let scan = line.drop(while: { $0 == "\t" || $0 == " " })
        let indent = String(line.prefix(line.count - scan.count))
        let digits = scan.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, scan.dropFirst(digits.count).first == " " else {
            return Line(raw: line)
        }
        let rest = String(scan.dropFirst(digits.count + 1))
        return Line(raw: line, isTree: true, indent: indent, index: String(digits), rest: rest, role: roleName(of: rest))
    }

    private static let multiWordRoles = [
        "secure text field", "scroll area", "layout area", "list item", "outline row", "pop up button",
        "radio button", "check box", "combo box", "text field", "text area", "menu item", "menu button",
        "search field", "web area", "split group", "tab group", "color well", "disclosure triangle", "date field",
    ]

    private static func roleName(of rest: String) -> String {
        for role in multiWordRoles where rest == role || rest.hasPrefix(role + " ") { return role }
        if textParts(rest) != nil { return "text" }
        return String(rest.prefix(while: { $0 != " " }))
    }

    /// For text lines: the prefix kept as-is (`text ` or `static text `) and the text itself.
    private static func textParts(_ rest: String) -> (head: String, payload: String)? {
        // "text field ..." and "text area ..." are inputs, not text lines.
        if rest.hasPrefix("text field") || rest.hasPrefix("text area") || rest.hasPrefix("text entry area") { return nil }
        for head in ["static text ", "text "] where rest.hasPrefix(head) {
            return (head, String(rest.dropFirst(head.count)))
        }
        if rest == "static text" { return ("static text", "") }
        if rest == "text" { return ("text", "") }
        return nil
    }

    /// Parenthesised trait groups, split on ", ". For example `(w:str, selected)` gives `w:str` and `selected`.
    private static func traitTokens(_ rest: String) -> [String] {
        let pieces = rest.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "(" || $0 == ")" })
        var tokens: [String] = []
        for (offset, piece) in pieces.enumerated() where offset % 2 == 1 {
            tokens += piece.components(separatedBy: ", ")
        }
        return tokens
    }

    // MARK: - Rule 1: structural noise

    // "scroll area" is kept: the model scrolls by its index.
    private static let containerRoles: Set<String> = ["group", "generic", "section", "splitter", "layout area"]

    /// Removes containers that have no label, value, traits or actions, and re-indents what is under them.
    /// Re-indenting removes one tab per removed ancestor (or up to four spaces when a line has no tab).
    private static func dropStructuralNoise(_ lines: [Line], unwrapSingleChild: Bool = false) -> [Line] {
        var result: [Line] = []
        result.reserveCapacity(lines.count)
        // Widths of removed containers that still enclose the current line.
        var removedWidths: [Int] = []
        for (position, original) in lines.enumerated() {
            var line = original
            guard line.isTree else {
                result.append(line)
                continue
            }
            let width = line.width
            while let last = removedWidths.last, last >= width { removedWidths.removeLast() }
            if !removedWidths.isEmpty {
                line.indent = outdent(line.indent, levels: removedWidths.count)
            }
            if isUnlabeledContainer(line) || (unwrapSingleChild && isSingleChildWrapper(lines, position)) {
                removedWidths.append(width)
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func isUnlabeledContainer(_ line: Line) -> Bool {
        containerRoles.contains(line.role) && line.rest.trimmingCharacters(in: .whitespaces) == line.role
    }

    private static let wrapperRoles: Set<String> = ["group", "generic", "section", "layout area"]

    /// A neutral group with exactly one child, no traits or actions, and no name or the child's own name.
    private static func isSingleChildWrapper(_ lines: [Line], _ position: Int) -> Bool {
        let line = lines[position]
        guard wrapperRoles.contains(line.role), !line.rest.contains("("), !line.rest.contains("Secondary Actions:"),
              position + 1 < lines.count, lines[position + 1].isTree, lines[position + 1].width > line.width else { return false }
        let childWidth = lines[position + 1].width
        let end = blockEnd(lines, from: position)
        var children = 0
        for k in (position + 1)..<end where lines[k].width <= childWidth { children += 1 }
        guard children == 1 else { return false }
        let name = String(line.rest.dropFirst(line.role.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || lines[position + 1].rest.contains(name)
    }

    private static func outdent(_ indent: String, levels: Int) -> String {
        var result = indent
        for _ in 0..<levels {
            if result.hasPrefix("\t") {
                result.removeFirst()
            } else {
                result.removeFirst(min(4, result.count))
            }
        }
        return result
    }

    // MARK: - Rule 4: duplicate text

    private static func dedupeText(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            if line.isTree, let current = textParts(line.rest),
               let previous = result.last, previous.isTree, previous.indent == line.indent,
               let before = textParts(previous.rest), before.payload == current.payload {
                continue
            }
            result.append(line)
        }
        return result
    }

    // MARK: - Rule 2: runs of siblings

    private static let collapsibleRoles: Set<String> = ["row", "cell", "list item", "link"]

    /// Controls and inputs. A block that holds one of these (or a settable, selected or focused line) is never removed.
    private static let actionableRoles: Set<String> = [
        "button", "textfield", "text field", "secure text field", "text area", "search field", "check box",
        "radio button", "pop up button", "combo box", "slider", "menu button", "menu item", "tab", "switch",
        "toggle", "incrementor", "disclosure triangle", "color well", "date field",
        // macOS names a check box "checkbox" and a stepper "stepper"; a row holding only an unchecked one has no
        // other mark, so without these it was folded away as "rows like these".
        "checkbox", "stepper",
    ]

    private static func collapseRuns(_ lines: [Line], options: Options) -> [Line] {
        var result: [Line] = []
        result.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            let head = lines[i]
            guard head.isTree, collapsibleRoles.contains(head.role) else {
                result.append(head)
                i += 1
                continue
            }

            // Sibling blocks: a row and its deeper children, repeated at the same indentation and role.
            var blocks: [Range<Int>] = []
            var start = i
            while true {
                let end = blockEnd(lines, from: start)
                blocks.append(start..<end)
                guard end < lines.count, lines[end].isTree,
                      lines[end].role == head.role, lines[end].indent == head.indent else { break }
                start = end
            }
            let runEnd = blocks[blocks.count - 1].upperBound

            let keepStart = max(0, options.keepRuns)
            let keepEnd = blocks.count - max(0, options.keepLast)
            var removable = Set<Int>()
            if keepEnd > keepStart {
                for k in keepStart..<keepEnd where !isProtected(lines, blocks[k]) {
                    removable.insert(k)
                }
            }

            guard removable.count >= 2 else {
                result.append(contentsOf: lines[i..<runEnd])
                i = runEnd
                continue
            }

            // Each stretch of removable blocks (two or more) becomes its own marker; a block with state splits it.
            var k = 0
            while k < blocks.count {
                guard removable.contains(k) else {
                    result.append(contentsOf: lines[blocks[k]])
                    k += 1
                    continue
                }
                var stretchEnd = k
                while stretchEnd < blocks.count, removable.contains(stretchEnd) { stretchEnd += 1 }
                if stretchEnd - k >= 2 {
                    result.append(collapsedMarker(count: stretchEnd - k, role: head.role, indent: head.indent))
                } else {
                    result.append(contentsOf: lines[blocks[k]])
                }
                k = stretchEnd
            }
            i = runEnd
        }
        return result
    }

    /// A block is the line at `start` plus every following line indented deeper than it.
    private static func blockEnd(_ lines: [Line], from start: Int) -> Int {
        let width = lines[start].width
        var end = start + 1
        while end < lines.count, lines[end].isTree, lines[end].width > width {
            end += 1
        }
        return end
    }

    private static func isProtected(_ lines: [Line], _ block: Range<Int>) -> Bool {
        block.contains { isProtectedLine(lines[$0]) }
    }

    private static func isProtectedLine(_ line: Line) -> Bool {
        guard line.isTree else { return false }
        if actionableRoles.contains(line.role) { return true }
        if line.rest.contains("Secondary Actions:") { return true }
        if traitTokens(line.rest).contains(where: { token in
            token == "selected" || token == "focused" || token == "settable" || token == "checked" || token == "expanded"
                || token == "w" || token.hasPrefix("w:")
        }) { return true }
        // A value (`= 40` or `Value: 40`) is state too, except in plain text.
        return line.role != "text" && (line.rest.contains(" = ") || line.rest.contains(" Value: "))
    }

    private static func collapsedMarker(count: Int, role: String, indent: String) -> Line {
        Line(raw: "\(indent)…(\(count) more \(role)s like these; use query to find one)")
    }

    // MARK: - Rule 3: long text

    private static func truncateText(_ lines: [Line], limit: Int) -> [Line] {
        let cap = max(0, limit)
        return lines.map { line in
            guard line.isTree, let parts = textParts(line.rest), parts.payload.count > cap else { return line }
            var copy = line
            copy.rest = parts.head + String(parts.payload.prefix(cap)) + "…"
            return copy
        }
    }

    // MARK: - Rule 6: hidden and unnamed leftovers

    private static let decorationRoles: Set<String> = ["image", "separator", "unknown", "value indicator"]

    private static func isHiddenMarked(_ line: Line) -> Bool {
        traitTokens(line.rest).contains { $0 == "hidden" || $0 == "offscreen" || $0 == "off-screen" }
    }

    /// Whether a line holds state or an action that makes it worth keeping even when hidden.
    private static func holdsStateOrAction(_ line: Line) -> Bool {
        guard line.isTree else { return false }
        if line.rest.contains("Secondary Actions:") { return true }
        return traitTokens(line.rest).contains { $0 == "selected" || $0 == "focused" || $0 == "checked" || $0 == "settable" || $0 == "w" || $0.hasPrefix("w:") }
    }

    private static func dropHidden(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        result.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.isTree else {
                result.append(line)
                i += 1
                continue
            }
            let end = blockEnd(lines, from: i)
            if isHiddenMarked(line), !lines[i..<end].contains(where: holdsStateOrAction) {
                i = end
                continue
            }
            // An unnamed image or separator with nothing under it says nothing and cannot be acted on.
            if decorationRoles.contains(line.role), end == i + 1,
               line.rest.trimmingCharacters(in: .whitespaces) == line.role {
                i += 1
                continue
            }
            result.append(line)
            i += 1
        }
        return result
    }

    // MARK: - Rules 7 and 8: shorter lines

    private static let propertyTerminators = [
        ", Help: ", " Help: ", ", URL: ", " ID: ", " Secondary Actions: ", ", Secondary Actions: ",
        " = ", " Value: ", " Placeholder: ", ", Placeholder: ", " Frame: ",
    ]

    /// Range of the text after `Description: ` up to the next property, or nil without a description.
    private static func descriptionPayload(_ rest: String) -> Range<String.Index>? {
        guard let marker = rest.range(of: "Description: ") else { return nil }
        let start = marker.upperBound
        var end = rest.endIndex
        for terminator in propertyTerminators {
            if let found = rest.range(of: terminator, range: start..<rest.endIndex), found.lowerBound < end {
                end = found.lowerBound
            }
        }
        return start..<end
    }

    private static func cutDescriptions(_ lines: [Line], limit: Int) -> [Line] {
        lines.map { line in
            guard line.isTree, let range = descriptionPayload(line.rest), line.rest[range].count > limit else { return line }
            var copy = line
            let cut = line.rest[range].prefix(limit)
            copy.rest = String(line.rest[..<range.lowerBound]) + cut + "…" + String(line.rest[range.upperBound...])
            return copy
        }
    }

    private static func helpPayload(_ rest: String) -> Range<String.Index>? {
        guard let marker = rest.range(of: "Help: ") else { return nil }
        let start = marker.upperBound
        var end = rest.endIndex
        for terminator in propertyTerminators where !terminator.contains("Help") {
            if let found = rest.range(of: terminator, range: start..<rest.endIndex), found.lowerBound < end {
                end = found.lowerBound
            }
        }
        return start..<end
    }

    /// Removes a `Help:` or `Description:` that equals the previous sibling's of the same role, when the line keeps a name.
    private static func dropRepeatedProperties(_ lines: [Line]) -> [Line] {
        var previous: [String: (role: String, help: String?, description: String?)] = [:]
        return lines.map { line in
            guard line.isTree else { return line }
            let width = line.indent
            // Forget deeper levels: a new row starts a new family.
            for key in previous.keys where key.count > width.count { previous[key] = nil }
            var copy = line
            var help: String?
            var description: String?
            for (name, payload) in [("Help", helpPayload), ("Description", descriptionPayload)] as [(String, (String) -> Range<String.Index>?)] {
                guard let range = payload(copy.rest) else { continue }
                let value = String(copy.rest[range])
                if name == "Help" { help = value } else { description = value }
                guard let before = previous[width], before.role == line.role,
                      (name == "Help" ? before.help : before.description) == value,
                      hasName(copy.rest, before: range.lowerBound, role: line.role) else { continue }
                // Take the whole segment: its leading separator, label and payload.
                var segmentStart = copy.rest.range(of: name + ": ", options: .backwards, range: copy.rest.startIndex..<range.lowerBound)?.lowerBound ?? range.lowerBound
                if copy.rest[..<segmentStart].hasSuffix(", ") { segmentStart = copy.rest.index(segmentStart, offsetBy: -2) }
                else if copy.rest[..<segmentStart].hasSuffix(" ") { segmentStart = copy.rest.index(before: segmentStart) }
                copy.rest.removeSubrange(segmentStart..<range.upperBound)
            }
            previous[width] = (line.role, help, description)
            return copy
        }
    }

    /// True when something other than the role and trait groups comes before `index` in the line.
    private static func hasName(_ rest: String, before index: String.Index, role: String) -> Bool {
        var head = String(rest[..<index])
        if head.hasPrefix(role) { head.removeFirst(role.count) }
        var outside = ""
        var depth = 0
        for ch in head {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) } else if depth == 0 { outside.append(ch) }
        }
        let name = outside
            .replacingOccurrences(of: "Description:", with: "")
            .replacingOccurrences(of: "Help:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return !name.isEmpty
    }

    // MARK: - Rule 9: budget

    private static func applyBudget(_ lines: [Line], headerCount: Int, budget: Int) -> [Line] {
        var total = headerCount
        for line in lines { total += line.render().count + 1 }
        guard total > budget else { return lines }

        let hardCap = budget + budget / 2
        var used = headerCount
        var kept: [Line] = []
        var cut = 0
        var lastIndent = ""
        for line in lines {
            let size = line.render().count + 1
            let keep: Bool
            if !line.isTree || used + size <= budget {
                keep = true
            } else {
                keep = used + size <= hardCap && (isProtectedLine(line) || holdsStateOrAction(line))
            }
            if keep {
                used += size
                kept.append(line)
                lastIndent = line.indent
            } else {
                cut += 1
            }
        }
        if cut > 0 {
            kept.append(Line(raw: "\(lastIndent)…(\(cut) more lines cut to fit; use query to find a control)"))
        }
        return kept
    }
}
