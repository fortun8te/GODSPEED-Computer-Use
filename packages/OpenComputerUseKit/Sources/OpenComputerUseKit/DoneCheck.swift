import Foundation

/// `done_when` on a batch: conditions the batch's result must meet for the goal to count as reached.
/// They are checked directly (file system, state text, browser URL), so a verified goal needs no model.
///
/// Accepted forms (one object, or a list of them):
/// - `{"file_exists": "~/Desktop/out.pdf"}`
/// - `{"text": "Message sent"}`: appears in the final observation
/// - `{"field": "Volume", "equals": "40"}`: a state line for that label has `= 40`
/// - `{"url_contains": "/thanks"}`
/// - `{"gone": "Loading"}`: no state line mentions that label any more
enum DoneCheck {
    static let clippedFieldNote = "[field preview clipped]"

    enum Condition: Equatable {
        case fileExists(String)
        case text(String)
        case field(label: String, equals: String)
        case urlContains(String)
        case gone(String)

        var arguments: [String: String] {
            switch self {
            case .fileExists(let path): return ["file_exists": path]
            case .text(let text): return ["text": text]
            case .field(let label, let value): return ["field": label, "equals": value]
            case .urlContains(let part): return ["url_contains": part]
            case .gone(let label): return ["gone": label]
            }
        }

        var summary: String {
            switch self {
            case .fileExists(let path): return "file \(path) exists"
            case .text(let text): return "\"\(text)\" is on screen"
            case .field(let label, let value): return "\(label) = \(value)"
            case .urlContains(let part): return "the page URL contains \(part)"
            case .gone(let label): return "\(label) is gone"
            }
        }
    }

    /// What the state and the page showed when the conditions were checked.
    struct Evidence {
        /// The final observed state. Nil when the final read could not be used.
        var screenText: String?
        /// The current page URL, when the batch drove the browser (fetched lazily by the caller).
        var pageURL: () -> String?
        var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var supportsAbsence = true
    }

    enum Result: Equatable {
        case verified(met: [String])
        case missing(unmet: [String])
    }

    /// Parses the `done_when` argument. Nil or missing means no conditions. Any malformed entry throws.
    static func parse(_ raw: Any?) throws -> [Condition] {
        guard let raw, !(raw is NSNull) else { return [] }
        let entries: [Any]
        if let list = raw as? [Any] {
            entries = list
        } else {
            entries = [raw]
        }
        guard entries.count <= 8 else {
            throw ComputerUseError.invalidArguments("done_when allows at most 8 conditions")
        }
        return try entries.map { entry in
            guard let object = entry as? [String: Any] else {
                throw ComputerUseError.invalidArguments(
                    "done_when entries are objects like {\"text\": \"Message sent\"} or {\"file_exists\": \"~/x.pdf\"}"
                )
            }
            if let path = object["file_exists"] as? String, !path.isEmpty {
                return .fileExists((path as NSString).expandingTildeInPath)
            }
            if let text = object["text"] as? String, !text.isEmpty {
                return .text(text)
            }
            if let label = object["field"] as? String, !label.isEmpty {
                guard let value = object["equals"], !(value is NSNull) else {
                    throw ComputerUseError.invalidArguments("done_when field '\(label)' needs an equals value")
                }
                return .field(label: label, equals: "\(value)")
            }
            if let part = object["url_contains"] as? String, !part.isEmpty {
                return .urlContains(part)
            }
            if let label = object["gone"] as? String, !label.isEmpty {
                return .gone(label)
            }
            throw ComputerUseError.invalidArguments(
                "done_when entry needs one of: file_exists, text, field + equals, url_contains, gone"
            )
        }
    }

    /// Checks every condition. Verified only when all of them are met.
    static func check(_ conditions: [Condition], evidence: Evidence) -> Result {
        var met: [String] = []
        var unmet: [String] = []
        var fetchedURL: String?
        var didFetchURL = false
        for condition in conditions {
            let ok: Bool
            switch condition {
            case .fileExists(let path):
                ok = evidence.fileExists(path)
            case .text(let text):
                ok = evidence.screenText.map { contains($0, text) } ?? false
            case .field(let label, let value):
                ok = evidence.screenText.map { fieldEquals($0, label: label, value: value) } ?? false
            case .urlContains(let part):
                if !didFetchURL {
                    fetchedURL = evidence.pageURL()
                    didFetchURL = true
                }
                ok = fetchedURL.map { contains($0, part) } ?? false
            case .gone(let label):
                ok = evidence.supportsAbsence && (evidence.screenText.map {
                    supportsAbsenceCheck($0) && !linesMention($0, label: label)
                } ?? false)
            }
            if ok { met.append(condition.summary) } else { unmet.append(condition.summary) }
        }
        return unmet.isEmpty ? .verified(met: met) : .missing(unmet: unmet)
    }

    /// The one line the batch reply adds: "Done: verified (...)" or "Not done yet: (...)".
    static func line(for result: Result) -> String {
        switch result {
        case .verified(let met):
            return "Done: verified (\(met.joined(separator: "; ")))"
        case .missing(let unmet):
            return "Not done yet: (\(unmet.joined(separator: "; ")) not confirmed)"
        }
    }

    static func supportsAbsenceCheck(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Browser snapshots cap both controls and text. A missing label in that reply does not
        // establish its absence from the page.
        guard !text.hasPrefix("Page:") else { return false }
        return !text.split(separator: "\n").contains { line in
            let content = line.drop(while: \.isWhitespace)
            return content.hasPrefix("[Accessibility tree truncated:")
                || content.hasPrefix("[Compact batch:")
                || content.hasPrefix("…(")
                || content == SnapshotObservationOptions.accessibilityOmittedNote
        }
    }

    /// Whether `text` is a state line or page text that mentions `label`, case-insensitively.
    static func linesMention(_ text: String, label: String) -> Bool {
        let needle = label.lowercased()
        return text.lowercased().split(separator: "\n").contains { $0.contains(needle) }
    }

    /// True when a state line for `label` ends in `= value`. A "(w:str)"-style type note after the value is ignored.
    static func fieldEquals(_ text: String, label: String, value: String) -> Bool {
        let needle = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        let paddedNeedle = " " + needle + " "
        let expected = value.trimmingCharacters(in: .whitespaces).lowercased()
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: " = ") else { continue }
            let field = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            guard !field.hasSuffix(clippedFieldNote) else { continue }
            let paddedField = " " + field + " "
            guard paddedField.contains(paddedNeedle) else { continue }
            var actual = line[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            if actual.hasSuffix(")"),
               let paren = actual.range(of: #" \(w:[a-z]+\)$"#, options: .regularExpression) {
                actual = String(actual[..<paren.lowerBound])
            }
            if actual == expected { return true }
        }
        return false
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }
}

/// Stuck rules that decide without the model. Pure: the caller supplies the counts it already tracks.
enum StuckRules {
    /// A same step failing in this many batches in a row is stuck.
    static let repeatedFailureLimit = 2

    /// The one line to add when a rule decides "stuck", or nil.
    static func line(repeatedFailures: Int, failedStep: String?, appLookedIdentical: Bool) -> String? {
        if repeatedFailures >= repeatedFailureLimit, let failedStep {
            return "Stuck: \(failedStep) has failed \(repeatedFailures) batches in a row. Change approach instead of retrying it."
        }
        if appLookedIdentical {
            return "Stuck: the app looks exactly as it did after your previous batch. If these steps should have changed the screen, do not repeat them: pick a different element, use a label, or query for it. If they change nothing you can see (copy, a shortcut), carry on."
        }
        return nil
    }
}

/// The short summary the referee reads instead of raw screen text.
enum RefereeSummary {
    // The helper clips Python strings by Unicode code point.
    static func clip(_ text: String, to limit: Int) -> String {
        String(text.unicodeScalars.prefix(max(0, limit)))
    }
    static let changeLimit = 600

    /// Whether the state has a sheet or dialog open (its role is the second word of a state line).
    static func dialogOpen(in stateText: String) -> Bool {
        stateText.split(separator: "\n").contains { line in
            var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let first = words.first, first.allSatisfy(\.isNumber) { words.removeFirst() }
            guard let role = words.first else { return false }
            return role == "sheet" || role == "dialog" || role == "alert"
        }
    }

    /// Goal, each step with its result, repeated-failure count, screen change, dialog and changed lines.
    static func build(
        goal: String,
        steps: [(step: String, result: String)],
        repeatedFailures: Int,
        screenChanged: Bool,
        dialogOpen: Bool,
        changes: String?,
        screen: String? = nil,
        maxCharacters: Int = 1_200
    ) -> String {
        guard maxCharacters > 0 else { return "" }
        let header = "Goal: \(clip(goal, to: maxCharacters / 4))\nSteps:"
        let status = "\nRepeated failures: \(repeatedFailures)\nScreen changed: \(screenChanged ? "yes" : "no")\nDialog or sheet open: \(dialogOpen ? "yes" : "no")"
        let screenBlock = screen.flatMap { $0.isEmpty ? nil : "\nScreen:\n" + clip($0, to: maxCharacters / 2) } ?? ""
        let changeHeader = "\nChanges:\n"
        let room = maxCharacters - (header + status + screenBlock + changeHeader).unicodeScalars.count
        guard room > 0 else { return clip(screenBlock.isEmpty ? header + status : screenBlock, to: maxCharacters) }

        let changeText = changes.flatMap { $0.isEmpty ? nil : $0 } ?? "(none)"
        let fullChanges = clip(changeText, to: changeLimit)
        let fullHistory = steps.enumerated().map { "\n\($0.offset + 1). \($0.element.step): \($0.element.result)" }.joined()
        if fullHistory.unicodeScalars.count + fullChanges.unicodeScalars.count <= room {
            return header + fullHistory + status + changeHeader + fullChanges + screenBlock
        }
        let excerpt = clip(changeText, to: min(changeLimit, max(0, room / 3)))
        var history: [String] = []
        var remaining = room - excerpt.unicodeScalars.count
        for (index, step) in steps.enumerated().reversed() {
            guard remaining > 1 else { break }
            let line = "\n\(index + 1). \(step.step): \(step.result)"
            let length = line.unicodeScalars.count
            if length > remaining {
                if history.isEmpty { history.append(clip(line, to: remaining)) }
                break
            }
            history.append(line)
            remaining -= length
        }
        return header + history.reversed().joined() + status + changeHeader + excerpt + screenBlock
    }

    static let screenLineLimit = 12
    static let screenCharacterLimit = 480

    /// The window line and up to `screenLineLimit` element lines of a state, without indentation, write
    /// markers, secondary actions or scroll furniture.
    static func screen(from stateText: String) -> String {
        if stateText.hasPrefix("Page:") { return browserScreen(from: stateText) }
        var window: String?
        var kept: [String] = []
        var used = 0
        for raw in stateText.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("App=") || line.hasPrefix("[w=") { continue }
            if line.hasPrefix("Window:") {
                if window == nil { window = line }
                continue
            }
            if line.contains("ruler marker") || line.contains("scroll bar") || line.hasSuffix(" ruler") { continue }
            if let range = line.range(of: ", Secondary Actions:") { line = String(line[..<range.lowerBound]) }
            line = line.replacingOccurrences(of: #", w:[a-z]+\)"#, with: ")", options: .regularExpression)
            line = line.replacingOccurrences(of: #" \(w:[a-z]+\)"#, with: "", options: .regularExpression)
            guard line.contains(where: \.isLetter) else { continue }
            if kept.count >= screenLineLimit || used + line.count > screenCharacterLimit { break }
            kept.append(line)
            used += line.count + 1
        }
        return ([window].compactMap { $0 } + kept).joined(separator: "\n")
    }

    private static func browserScreen(from stateText: String) -> String {
        let lines = stateText.split(separator: "\n")
        // Headings are often where the website displays final confirmation. Keep
        // them even when the page lists many controls ahead of its visible text.
        let body = lines.dropFirst().filter {
            $0 != "Controls:" && $0 != "Text:" && !$0.hasPrefix("(")
        }
        let important = body.filter {
            $0.hasPrefix("# ") || $0.contains(" [focused") || $0.contains("disabled]")
                || $0.contains("[disabled") || $0.contains("selected]")
        }
        var output = [String(lines[0].prefix(120))]
        var seen = Set<Substring>()
        var remaining = screenCharacterLimit - output[0].count
        for line in important + body {
            guard output.count < screenLineLimit, remaining > 1 else { break }
            guard seen.insert(line).inserted else { continue }
            let excerpt = String(line.prefix(min(120, remaining - 1)))
            output.append(excerpt)
            remaining -= excerpt.count + 1
        }
        return output.joined(separator: "\n")
    }

}
