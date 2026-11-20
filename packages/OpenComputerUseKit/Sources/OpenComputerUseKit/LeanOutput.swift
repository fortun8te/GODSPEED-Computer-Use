import Foundation

/// Shrinks what GODSPEED sends back to the model:
/// - every accessibility state text (items starting with "App=") goes through `AXTreeCondenser`
///   (structural noise dropped, long runs of similar rows collapsed, long text cut), keeping every
///   element index the model can act on. `OPEN_COMPUTER_USE_CONDENSE=0` turns it off.
/// - a batch's final read can be replaced by `AXStateDiff` (only what changed since the previous read
///   of that app) when the change is small. `OPEN_COMPUTER_USE_BATCH_DIFF=0` turns it off.
enum LeanOutput {
    enum ObservationMode {
        case standard
        case compact
        case compactBatch
    }

    static var condenses: Bool { flag("OPEN_COMPUTER_USE_CONDENSE") }
    static var diffsBatchReads: Bool { flag("OPEN_COMPUTER_USE_BATCH_DIFF") }
    /// `OPEN_COMPUTER_USE_SEMANTIC_REPLIES=0` sends change-only replies exactly as before (no `Changes:` line).
    static var semanticReplies: Bool { flag("OPEN_COMPUTER_USE_SEMANTIC_REPLIES") }
    /// Change-only replies shorter than this keep every line; longer ones may drop unnumbered lines.
    static let semanticTrimMinLength = 600

    private static func flag(_ key: String) -> Bool {
        let value = GodspeedSettings.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }

    static func isStateText(_ text: String) -> Bool {
        text.hasPrefix("App=")
    }

    /// The result with each state text condensed; other items (notes, images) unchanged.
    static func condensed(
        _ result: ToolCallResult, mode: ObservationMode = .standard, preserving indexes: Set<String> = []
    ) -> ToolCallResult {
        guard condenses || mode != .standard else { return result }
        var changed = false
        let content = result.content.map { item -> ToolResultContentItem in
            guard item.dictionary["type"] as? String == "text",
                  let text = item.dictionary["text"] as? String, isStateText(text)
            else { return item }
            changed = true
            switch mode {
            case .standard: return .text(AXTreeCondenser.condense(text))
            case .compact: return .text(AXTreeCondenser.compactObservation(text, preserving: indexes))
            case .compactBatch: return .text(AXTreeCondenser.batchReply(text))
            }
        }
        return changed ? result.replacingContent(content) : result
    }

    /// `observation` with its state text replaced by the change summary against `previous`, when the
    /// change is small enough; otherwise unchanged.
    static func diffed(_ observation: ToolCallResult, previous: String?) -> ToolCallResult {
        guard diffsBatchReads, let previous, !previous.isEmpty else { return observation }
        // Element numbers are stable across reads (ElementNumbering), so an unchanged line keeps its number
        // and a change summary is always safe to apply. Numbers are part of a line's identity in the diff.
        var replaced = false
        let content = observation.content.map { item -> ToolResultContentItem in
            guard !replaced, item.dictionary["type"] as? String == "text",
                  let text = item.dictionary["text"] as? String, isStateText(text),
                  previous.split(separator: "\n").prefix(2).elementsEqual(text.split(separator: "\n").prefix(2)),
                  windowIDLine(in: previous) == windowIDLine(in: text),
                  let summary = AXStateDiff.diff(previous: previous, current: text, matchIndexes: ElementNumbering.isEnabled)
            else { return item }
            // Keep the header line so the model still sees which app and window this is.
            // App, window and the legend line ([w=settable]).
            let header = text.split(separator: "\n", maxSplits: 3).prefix(3).joined(separator: "\n")
            let compact = semanticReplies
                ? semanticDiffReply(header: header, diff: summary, before: previous, after: text)
                : header + "\n" + summary
            guard compact.utf8.count < text.utf8.count else { return item }
            replaced = true
            return .text(compact)
        }
        return replaced ? observation.replacingContent(content) : observation
    }

    /// The change-only reply with a one-line `Changes:` summary from `SemanticChanges` under the header.
    /// When the summary names every change (one to three events) and the reply is long, unnumbered
    /// changed lines are dropped: the summary and the numbered lines are what the model acts on.
    /// Kept: the diff's first line (it says indexes are current), numbered `+`/`-` lines, the
    /// "more lines removed" count and the "Unchanged" footer. Secret values are redacted by SemanticChanges.
    static func semanticDiffReply(header: String, diff: String, before: String, after: String) -> String {
        guard let summary = SemanticChanges.summary(before: before, after: after) else {
            return header + "\n" + diff
        }
        let eventCount = SemanticChanges.events(before: before, after: after, limit: 4).count
        let full = header + "\nChanges: " + summary + "\n" + diff
        guard (1...3).contains(eventCount), full.utf8.count > semanticTrimMinLength else { return full }

        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.enumerated().filter { offset, line in
            if offset == 0 || line.hasPrefix("Unchanged:") || line.hasPrefix("- (") { return true }
            guard line.hasPrefix("+ ") || line.hasPrefix("- ") else { return false }
            return leadingIndex(String(line.dropFirst(2))) != nil
        }.map(\.element)
        return header + "\nChanges: " + summary + "\n" + kept.joined(separator: "\n")
    }

    /// Only the state's header (app, window, window ID), with a pointer to the full read.
    static func headerOnly(_ observation: ToolCallResult) -> ToolCallResult {
        var replaced = false
        let content = observation.content.map { item -> ToolResultContentItem in
            guard !replaced, item.dictionary["type"] as? String == "text",
                  let text = item.dictionary["text"] as? String, isStateText(text) else { return item }
            let header = text.split(separator: "\n", maxSplits: 3).prefix(3)
                .filter { !$0.hasPrefix("[") }.joined(separator: "\n")
            let compact = header + "\nWindow list omitted (goal verified); get_app_state reads it."
            guard compact.utf8.count < text.utf8.count else { return item }
            replaced = true
            return .text(compact)
        }
        return replaced ? observation.replacingContent(content) : observation
    }

    /// A verified browser batch: the page snapshot's first lines (tab, URL) only.
    static func browserHeaderOnly(_ observation: ToolCallResult) -> ToolCallResult {
        var replaced = false
        let content = observation.content.map { item -> ToolResultContentItem in
            guard !replaced, item.dictionary["type"] as? String == "text",
                  let text = item.dictionary["text"] as? String, text.split(separator: "\n").count > 6 else { return item }
            replaced = true
            let head = text.split(separator: "\n", maxSplits: 3).prefix(3).joined(separator: "\n")
            return .text(head + "\nPage snapshot omitted (goal verified); browser read shows it.")
        }
        return replaced ? observation.replacingContent(content) : observation
    }

    static func batchNativeObservation(
        _ observation: ToolCallResult, memory: BatchObservationMemory, app: String,
        allowsDiff: Bool, compactVerified: Bool
    ) -> ToolCallResult {
        guard !observation.isError, let current = stateText(of: observation) else { return observation }
        if allowsDiff {
            let delta = diffed(observation, previous: memory.shownText(app: app))
            if stateText(of: delta) != current {
                // The client has the old baseline and received the changes.
                memory.recordShown(app: app, text: current)
                return delta
            }
        }
        let shown = compactVerified ? headerOnly(observation) : observation
        if stateText(of: shown) == current {
            memory.recordShown(app: app, text: current)
        } else {
            // An omitted tree cannot be the baseline for a later “no changes” or diff reply.
            memory.clearShown(app: app)
        }
        return shown
    }

    private static func windowIDLine(in state: String) -> Substring? {
        state.split(separator: "\n", maxSplits: 3).dropFirst(2).first
            .flatMap { $0.hasPrefix("Window ID: ") ? $0 : nil }
    }

    /// The element number at the start of a tree line ("\t\t12 button Send" gives "12"), or nil.
    static func leadingIndex(_ line: String) -> String? {
        let trimmed = line.drop { $0 == "\t" || $0 == " " }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, trimmed.dropFirst(digits.count).first == " " else { return nil }
        return String(digits)
    }

    /// The state text of a result (first "App=" item), or nil.
    static func stateText(of result: ToolCallResult) -> String? {
        result.content.lazy
            .compactMap { $0.dictionary["type"] as? String == "text" ? $0.dictionary["text"] as? String : nil }
            .first(where: isStateText)
    }
}
