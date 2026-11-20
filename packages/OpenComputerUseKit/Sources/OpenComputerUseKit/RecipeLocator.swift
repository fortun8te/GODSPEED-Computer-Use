import Foundation

/// Capture a labelled control's role and parent, then confirm it before a recipe can act.
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
            guard let first = words.first else { continue }
            let role = HandoffTool.roles.first { body == $0 || body.hasPrefix($0 + " ") } ?? first
            words.removeFirst(role.split(separator: " ").count)
            if let first = words.first, first.hasPrefix("(") {
                while let word = words.first {
                    words.removeFirst()
                    if word.hasSuffix(")") { break }
                }
            }
            var text = words.joined(separator: " ")
            for marker in [", Secondary Actions:", " Secondary Actions:", " Frame: x=", " ID:", " Help:", " = "] {
                if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
            }
            if text.hasSuffix(" =") { text.removeLast(2) }
            text = text.replacingOccurrences(of: #"\s*\(w:[a-z]+\)"#, with: "", options: .regularExpression)
            result.append(Line(depth: depth, role: role, text: text.trimmingCharacters(in: .whitespaces), secure: role == "secure text field"))
        }
        return result
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

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
        return Locator(role: line.role, label: label, parent: parent, nearby: near)
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

    static func capture(label: String, in state: String) -> Locator? {
        let all = lines(of: state)
        let matches = all.indices.filter { HandoffTool.sameLabel(label, all[$0].text) }
        guard matches.count == 1, let index = matches.first, !all[index].secure else { return nil }
        return locator(for: all, at: index, label: label)
    }

    static func confirms(_ saved: Locator, label: String, in state: String) -> Bool {
        guard HandoffTool.sameLabel(saved.label, label), let current = capture(label: label, in: state) else {
            return false
        }
        return saved.role == current.role && saved.parent == current.parent && saved.nearby == current.nearby
    }
}
