import Foundation

/// Did a click, press or secondary action visibly do anything? Pure: it classifies the reads a batch step
/// already made (state texts, window verdict, effect lines, events, optional pixels). It takes no screenshot,
/// reads nothing new and never retries; the batch loop has no retry path that this feeds.
///
/// False-positive averse: `effectSeen` needs a concrete observed change, `noEffectSeen` needs complete,
/// unclipped reads of the same window, and everything else is `unknown`.
enum ClickVerifier {
    enum Verdict: String, Equatable {
        /// A concrete change followed the step: changed, new or removed lines in complete reads, a sheet or
        /// window change, or a changed pixel region.
        case effectSeen = "effect_seen"
        /// Both reads were complete and of the same window, and nothing in them differs.
        case noEffectSeen = "no_effect_seen"
        /// Neither of the above: a read was clipped, the window identity is unclear, or the evidence is thin.
        case unknown
    }

    /// Steps whose success should visibly change the window. Text entry and scrolling are not checked here.
    static let tools: Set<String> = ["click", "press_key", "press_menu", "perform_secondary_action"]

    static func applies(tool: String) -> Bool { tools.contains(tool) }

    /// `effectLines` as `BatchEffects.effectLines` returns them; `events` as `SemanticChanges.events` returns them.
    /// `windowChanged` is true when the window verdict is a sheet/dialog change or a move.
    /// `pixelsChanged` is nil unless a before and after screenshot of the same window size were both available.
    static func verdict(before: String, after: String, beforeWindowID: UInt32?, afterWindowID: UInt32?,
                        windowChanged: Bool, effectLines: [String], events: [String],
                        pixelsChanged: Bool? = nil) -> Verdict {
        // A window or sheet change and a changed pixel region are concrete on their own.
        if windowChanged || pixelsChanged == true { return .effectSeen }

        // Text evidence counts only when both reads are complete, so a cut-off read cannot fake a change or a silence.
        let complete = DoneCheck.supportsAbsenceCheck(before) && DoneCheck.supportsAbsenceCheck(after)
        guard complete, let was = beforeWindowID, was == afterWindowID else { return .unknown }

        let textChanged = effectLines.contains { $0 != "no visible change" } || !events.isEmpty
        return textChanged ? .effectSeen : .noEffectSeen
    }

    /// Pixels of one window region compared through `RegionFingerprint`. Nil when either side is missing or the
    /// sizes or grids differ, because a size change says nothing about the content.
    static func pixelsChanged(before: RegionFingerprint?, after: RegionFingerprint?) -> Bool? {
        guard let before, let after, before.pixelWidth == after.pixelWidth, before.pixelHeight == after.pixelHeight,
              before.columns == after.columns, before.rows == after.rows else { return nil }
        return !before.changedCells(comparedTo: after).isEmpty
    }

    /// Short name of what the step pressed: a quoted label, a key, an element number, or a fallback.
    static func target(arguments: [String: Any]) -> String {
        if let label = arguments["label"] as? String, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\"" + String(label.prefix(60)) + "\""
        }
        if let key = arguments["key"] as? String, !key.isEmpty { return key }
        if let index = arguments["element_index"] { return "#\(index)" }
        return "that item"
    }

    /// The reply line for a `noEffectSeen` step. It says what happened and suggests a different target; it never
    /// suggests repeating the step, because a click on send or delete must not be repeated on a guess.
    static func noEffectLine(tool: String, target: String) -> String {
        let action: String
        switch tool {
        case "press_key", "press_menu": action = "Press \(target)"
        case "perform_secondary_action": action = "Action on \(target)"
        default: action = "Click on \(target)"
        }
        return "\(action) changed nothing visible. It may need a different target."
    }
}
