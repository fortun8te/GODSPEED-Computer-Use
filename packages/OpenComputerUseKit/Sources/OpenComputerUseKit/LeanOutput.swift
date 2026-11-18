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
    }

    static let condenses: Bool = flag("OPEN_COMPUTER_USE_CONDENSE")
    static let diffsBatchReads: Bool = flag("OPEN_COMPUTER_USE_BATCH_DIFF")

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
        guard condenses || mode == .compact else { return result }
        var changed = false
        let content = result.content.map { item -> ToolResultContentItem in
            guard item.dictionary["type"] as? String == "text",
                  let text = item.dictionary["text"] as? String, isStateText(text)
            else { return item }
            changed = true
            switch mode {
            case .standard: return .text(AXTreeCondenser.condense(text))
            case .compact: return .text(AXTreeCondenser.compactObservation(text, preserving: indexes))
            }
        }
        return changed ? ToolCallResult(content: content, isError: result.isError) : result
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
                  let summary = AXStateDiff.diff(previous: previous, current: text, matchIndexes: ElementNumbering.isEnabled)
            else { return item }
            replaced = true
            // Keep the header line so the model still sees which app and window this is.
            // App, window and the legend line ([w=settable]).
            let header = text.split(separator: "\n", maxSplits: 3).prefix(3).joined(separator: "\n")
            return .text(header + "\n" + summary)
        }
        return replaced ? ToolCallResult(content: content, isError: observation.isError) : observation
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
