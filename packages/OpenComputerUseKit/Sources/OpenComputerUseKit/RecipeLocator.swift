import Foundation

/// Self-healing locators for saved recipes. A recipe step stores, next to its label, what the element
/// looked like when it was saved: its role, its parent's label and a few neighbouring labels. On replay the
/// label is tried first; when it no longer matches, the element is found again by fuzzy match on those
/// clues, and the healed label is written back to the recipe. Pure functions over the state text.
enum RecipeLocator {
    struct Locator: Equatable {
        var role: String
        var label: String
        var parent: String
        var nearby: [String]

        var dictionary: [String: Any] {
            ["role": role, "label": label, "parent": parent, "near": nearby]
        }

        init(role: String, label: String, parent: String, nearby: [String]) {
            self.role = role
            self.label = label
            self.parent = parent
            self.nearby = nearby
        }

        init?(dictionary: Any?) {
            guard let dict = dictionary as? [String: Any], let label = dict["label"] as? String else { return nil }
            self.init(role: (dict["role"] as? String) ?? "", label: label,
                      parent: (dict["parent"] as? String) ?? "", nearby: (dict["near"] as? [String]) ?? [])
        }
    }

    enum Resolution: Equatable {
        /// The label still finds the element; nothing to change.
        case found
        /// The element was found by its clues under a new label.
        case healed(label: String, locator: Locator)
        /// No element matches well enough; the tool will report the failure as usual.
        case missing
    }

    struct Line: Equatable {
        let depth: Int
        let role: String
        let text: String
        /// A secure text field (its role reads "secure text field").
        var secure = false
    }

    // MARK: Parsing

    static func lines(of state: String) -> [Line] {
        var result: [Line] = []
        for raw in state.split(separator: "\n") {
            let line = String(raw)
            guard LeanOutput.leadingIndex(line) != nil else { continue }
            let depth = line.prefix { $0 == "\t" }.count
            let body = AXStateDiff.strippedContent(of: line)
            var words = body.split(separator: " ").map(String.init)
            guard let role = words.first else { continue }
            words.removeFirst()
            if let first = words.first, first.hasPrefix("(") {
                while let word = words.first {
                    words.removeFirst()
                    if word.hasSuffix(")") { break }
                }
            }
            var text = words.joined(separator: " ")
            for marker in [" Secondary Actions:", ", Secondary Actions:", " Frame: x=", " ID:", " Help:", " = "] {
                if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
            }
            let secure = role == "secure" && words0(body).dropFirst().first == "text"
            result.append(Line(depth: depth, role: role, text: text.trimmingCharacters(in: .whitespaces), secure: secure))
        }
        return result
    }

    private static func words0(_ body: String) -> [String] { body.split(separator: " ").map(String.init) }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func norm(_ text: String) -> String { tokens(text).joined(separator: " ") }

    // MARK: Context

    /// Role, parent label and neighbouring labels of line `i`.
    static func locator(for lines: [Line], at i: Int, label: String) -> Locator {
        let line = lines[i]
        var parent = ""
        var j = i - 1
        while j >= 0 {
            if lines[j].depth < line.depth, !lines[j].text.isEmpty {
                parent = lines[j].text
                break
            }
            j -= 1
        }
        var near: [String] = []
        for k in [i - 2, i - 1, i + 1, i + 2] where lines.indices.contains(k) {
            let other = lines[k]
            if other.depth == line.depth, !other.text.isEmpty { near.append(clip(other.text)) }
        }
        return Locator(role: line.role, label: label, parent: clip(parent), nearby: near)
    }

    private static func clip(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(40)) : text
    }

    /// How well `text` carries `label`: 2 equal, 1 contains, 0 no.
    static func labelMatch(_ label: String, _ text: String) -> Int {
        let a = tokens(label), b = tokens(text)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 2 }
        // Whole words only: "OK" is not inside "Book".
        return containsRun(b, a) || containsRun(a, b) ? 1 : 0
    }

    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    /// Words that mark a field as holding a secret. Text typed into such a field is never put in a recipe.
    static let secretWords: Set<String> = [
        "password", "passwd", "passcode", "secret", "token", "pin", "otp", "cvv", "cvc", "ssn", "2fa", "apikey", "passphrase",
    ]

    static func looksSecret(_ text: String) -> Bool {
        let t = tokens(text)
        if t.contains(where: { secretWords.contains($0) }) { return true }
        let joined = t.joined(separator: " ")
        return ["security code", "card number", "verification code", "api key", "credit card", "recovery key"].contains { joined.contains($0) }
    }

    /// True when the state shows a secure (password) text field anywhere.
    static func hasSecureField(_ state: String) -> Bool {
        lines(of: state).contains { $0.secure }
    }

    /// True when the line carrying `label` is a secure field or has a secret-sounding name.
    static func isSecretField(label: String, in state: String) -> Bool {
        if looksSecret(label) { return true }
        return lines(of: state).contains { $0.secure && labelMatch(label, $0.text) > 0 }
    }

    /// The element a label points at in `state`, described for later healing; nil when it is not shown.
    static func capture(label: String, in state: String) -> Locator? {
        let all = lines(of: state)
        let ranked = all.indices.map { ($0, labelMatch(label, all[$0].text)) }.filter { $0.1 > 0 }
        guard let best = ranked.max(by: { $0.1 < $1.1 }) else { return nil }
        // max(by:) keeps the last of equal scores; prefer the first.
        let top = ranked.first { $0.1 == best.1 }!.0
        return locator(for: all, at: top, label: label)
    }

    // MARK: Similarity

    /// Share of label words that appear (or nearly appear) in `text`, 0 to 1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        var sum = 0.0
        for x in ta {
            var best = 0.0
            for y in tb {
                if x == y { best = 1; break }
                if min(x.count, y.count) >= 3, x.hasPrefix(y) || y.hasPrefix(x) { best = max(best, 0.7); continue }
                let ratio = editSimilarity(x, y)
                if ratio >= 0.75 { best = max(best, ratio * 0.8) }
            }
            sum += best
        }
        return sum / Double(max(ta.count, tb.count))
    }

    static func editSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: Resolution

    static let healThreshold = 5.0
    static let healMargin = 1.0
    static let healMinSimilarity = 0.3

    /// Label first; if no line carries it, the best fuzzy match on role, parent, neighbours and label words.
    static func resolve(_ locator: Locator, label: String, in state: String) -> Resolution {
        let all = lines(of: state)
        guard !all.isEmpty else { return .missing }
        if all.contains(where: { labelMatch(label, $0.text) > 0 }) { return .found }

        var scored: [(index: Int, score: Double)] = []
        // Elements that were the target's neighbours or parent when saved are other elements, not the target.
        let known = Set(locator.nearby.map(norm) + [norm(locator.parent)])
        for i in all.indices where !all[i].text.isEmpty && !known.contains(norm(all[i].text)) {
            let candidate = self.locator(for: all, at: i, label: all[i].text)
            let sim = similarity(locator.label, candidate.label)
            let sameRole = !locator.role.isEmpty && candidate.role == locator.role
            let sameParent = !locator.parent.isEmpty && norm(candidate.parent) == norm(locator.parent)
            let stored = Set(locator.nearby.map(norm))
            let overlap = candidate.nearby.filter { stored.contains(norm($0)) }.count
            // Clues alone pick a control only when they are strong (same role, same parent, two same neighbours
            // a plain rename). Otherwise some of the label must carry over.
            if sim < healMinSimilarity, !(sameRole && sameParent && overlap >= 2) { continue }
            var score = 4 * sim
            if sameRole { score += 2 }
            if sameParent { score += 2 }
            score += 0.5 * Double(min(overlap, 3))
            scored.append((i, score))
        }
        let ranked = scored.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= healThreshold else { return .missing }
        // A close runner-up with different text means the clues do not single one element out.
        if let second = ranked.dropFirst().first(where: { norm(all[$0.index].text) != norm(all[best.index].text) }),
           best.score - second.score < healMargin {
            return .missing
        }
        // Never heal a calm control into a risky one (Save -> Delete): the model decides that.
        if HandoffTool.isRisky(label: all[best.index].text), !HandoffTool.isRisky(label: locator.label) { return .missing }
        let healed = self.locator(for: all, at: best.index, label: all[best.index].text)
        return .healed(label: all[best.index].text, locator: healed)
    }
}
