import Foundation

/// Selects evidence for the helper from an observation. The result is never used as an action target.
enum RefereeView {
    private struct Row {
        let depth: Int
        let index: Int?
        let role: String
        let label: String
        let text: String
        let body: String
        let parent: Int?
        let isHeader: Bool

        var isFocused: Bool {
            text.hasPrefix("The focused UI element") || text.hasPrefix("Selected text:") ||
                text.contains("[focused") || text.contains("(focused")
        }
    }

    private static let controls = HandoffTool.clickRoles.union(HandoffTool.fieldRoles).union([
        "check box", "search field", "textbox", "combobox", "menuitem", "listbox", "slider",
    ])
    private static let regions: Set<String> = ["web area", "layout area", "canvas"]
    private static let roles = controls.union(regions).union([
        "static text", "standard window", "outline row", "list item", "scroll area", "split group",
        "toolbar", "group", "container", "row", "heading", "dialog", "sheet", "alert",
    ]).sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    private static let furniture: Set<String> = ["scroll bar", "ruler", "ruler marker"]
    private static let stopWords = HandoffTool.stopWords.union([
        "a", "an", "is", "of", "on", "to", "open", "show", "view", "find", "text", "page",
    ])

    static func build(state: String, goal: String, doneWhen: String = "", optionIndexes: [Int] = [],
                      limit: Int = 1_200) -> String {
        guard limit > 0 else { return "" }
        let rows = parse(state)
        let byIndex = Dictionary(rows.indices.compactMap { position in
            rows[position].index.map { ($0, position) }
        }, uniquingKeysWith: { first, _ in first })
        let siblings = Dictionary(grouping: rows.indices, by: { rows[$0].parent })
        let terms = Set(HandoffTool.words(goal + " " + doneWhen)).subtracting(stopWords)
        let ranks = rows.map { row in
            Set(HandoffTool.words(row.body)).intersection(terms).count
        }
        let ranked = rows.indices.filter { ranks[$0] > 0 || controls.contains(rows[$0].role) ||
            ["alert", "sheet", "dialog", "heading"].contains(rows[$0].role) || rows[$0].text.hasPrefix("# ") }
            .sorted { ranks[$0] == ranks[$1] ? $0 < $1 : ranks[$0] > ranks[$1] }

        let noteRoom = 40
        guard limit > noteRoom else { return RefereeSummary.clip("View omitted (budget)", to: limit) }
        var selected: [Int: String] = [:]
        var remaining = limit - noteRoom
        var shortened = false

        func add(_ position: Int, maxLength: Int) {
            guard selected[position] == nil, min(remaining - 1, maxLength) > 0 else { return }
            let row = rows[position]
            let line = excerpt(row, limit: min(remaining - 1, maxLength), terms: terms)
            selected[position] = line
            remaining -= line.unicodeScalars.count + 1
            shortened = shortened || line != row.text
        }

        for position in [rows.firstIndex(where: \.isHeader), rows.firstIndex(where: \.isFocused)].compactMap({ $0 }) {
            add(position, maxLength: min(145, limit / 5))
        }

        let targets = optionIndexes.compactMap { byIndex[$0] }
        let perTarget = min(100, max(0, remaining / max(1, targets.count * 2) - 1))
        for position in targets { add(position, maxLength: perTarget) }

        // Reserve a share for goal and completion evidence before adding neighboring context.
        let matched = ranked.filter { ranks[$0] > 0 }
        let evidenceRoom = remaining / 3
        let afterEvidence = remaining - evidenceRoom
        for position in matched {
            let available = remaining - afterEvidence - 1
            guard available > 20 else { break }
            add(position, maxLength: min(155, available))
        }

        var context: [Int] = []
        for position in targets {
            let row = rows[position]
            var ancestor = row.parent
            while let parent = ancestor, rows[parent].label.isEmpty { ancestor = rows[parent].parent }
            let sibling = siblings[row.parent]?.filter { $0 != position && !rows[$0].label.isEmpty }
                .min { abs($0 - position) < abs($1 - position) }
            for neighbor in [ancestor, sibling].compactMap({ $0 }) where selected[neighbor] == nil && !context.contains(neighbor) {
                context.append(neighbor)
            }
        }
        for (offset, position) in context.enumerated() {
            add(position, maxLength: min(110, remaining / (context.count - offset) - 1))
        }
        for position in ranked {
            guard remaining > 20 else { break }
            add(position, maxLength: 155)
        }

        // Preserve the existing Window/Page line and flat AX lines in observation order.
        let header = rows.firstIndex(where: \.isHeader)
        let body = selected.keys.sorted().filter { $0 != header }
        let lines = ([header].compactMap { $0 } + body).compactMap { selected[$0] }
        let note = "Omitted rows: \(rows.count - selected.count)" + (shortened ? "; some text shortened" : "")
        return (lines + [RefereeSummary.clip(note, to: noteRoom)]).joined(separator: "\n")
    }

    static func isThin(_ state: String) -> Bool {
        let rows = parse(state)
        let actionable = rows.filter { controls.contains($0.role) }
        let labelled = actionable.filter { !$0.label.isEmpty }.count
        let detailedRegions = Set(rows.compactMap { row in
            row.label.isEmpty ? nil : row.parent
        })
        return labelled < 3 || actionable.count > labelled || rows.indices.contains {
            regions.contains(rows[$0].role) && rows[$0].label.isEmpty && !detailedRegions.contains($0)
        }
    }

    private static func excerpt(_ row: Row, limit: Int, terms: Set<String>) -> String {
        guard row.text.unicodeScalars.count > limit else { return row.text }
        let words = row.body.split(separator: " ")
        let prefix = row.index.map { "\($0) \(row.role) " } ?? ""
        let room = limit - prefix.unicodeScalars.count
        if !row.isHeader, !row.isFocused, room > 18,
           let match = words.firstIndex(where: { !terms.isDisjoint(with: HandoffTool.words(String($0))) }),
           words[..<match].joined(separator: " ").unicodeScalars.count > limit / 2 {
            return prefix + "…" + RefereeSummary.clip(words[max(0, match - 1)...].joined(separator: " "), to: room - 2) + "…"
        }
        return RefereeSummary.clip(row.text, to: limit - 1) + "…"
    }

    private static func parse(_ state: String) -> [Row] {
        var rows: [Row] = []
        var ancestors: [Int] = []
        for raw in state.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "Controls:", trimmed != "Text:",
                  !trimmed.hasPrefix("App="), !trimmed.hasPrefix("Window ID:"),
                  !trimmed.hasPrefix("[w="), !trimmed.hasPrefix("[tab=") else { continue }
            var text = trimmed.components(separatedBy: ", Secondary Actions:")[0]
            if text.contains(" (w:") || text.contains(", w:") {
                text = text.replacingOccurrences(of: #" \(w:[a-z]+\)|, w:[a-z]+(?=\))"#, with: "", options: .regularExpression)
            }
            let pieces = text.split(separator: " ", maxSplits: 1)
            let index = pieces.first.flatMap { Int($0.hasSuffix("*") ? $0.dropLast() : $0) }
            let body = index == nil ? text : (pieces.dropFirst().first.map(String.init) ?? "")
            if furniture.contains(where: { body == $0 || body.hasPrefix($0 + " ") }) { continue }
            let role = roles.first { body == $0 || body.hasPrefix($0 + " ") } ?? ""
            var label = body.dropFirst(role.count).trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("("), let end = label.firstIndex(of: ")") {
                label = label[label.index(after: end)...].trimmingCharacters(in: .whitespaces)
            }
            if let end = label.range(of: " =") { label = String(label[..<end.lowerBound]) }
            if let end = label.range(of: " (w:") ?? label.range(of: " [") { label = String(label[..<end.lowerBound]) }
            if label.hasPrefix("Secondary Actions:") { label = "" }
            let depth = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if index != nil {
                while let last = ancestors.last, rows[last].depth >= depth { ancestors.removeLast() }
            }
            let parent = index == nil ? nil : ancestors.last
            if index != nil { ancestors.append(rows.count) }
            rows.append(Row(depth: depth, index: index, role: role, label: label, text: text, body: body, parent: parent,
                            isHeader: text.hasPrefix("Window:") || text.hasPrefix("Page:")))
        }
        return rows
    }
}
