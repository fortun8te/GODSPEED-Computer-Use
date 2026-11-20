import ApplicationServices
import Foundation

/// Pure helpers for batch replies: what one step changed on screen, whether the batch is still in the
/// window it started in, and the `wait` step's conditions. They read the state texts only (no accessibility
/// calls), so they are cheap to test. Element numbers are stable across reads, so lines are matched by number.
enum BatchEffects {
    static var isEnabled: Bool {
        let value = GodspeedSettings.environment["OPEN_COMPUTER_USE_BATCH_EFFECTS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }

    /// Most effect lines one step adds.
    static let maxEffectLines = 3

    /// Optional reads stop once they consume the budget. Failed reads count
    /// at full cost because there is no evidence that they settled a window.
    struct ReadBudget {
        private(set) var elapsed: TimeInterval = 0
        private(set) var exhausted = false

        mutating func record(seconds: TimeInterval, settleMs: Int, observed: Bool) {
            elapsed += seconds
            let settleCredit = observed ? Double(settleMs) / 1000 : 0
            exhausted = exhausted || elapsed >= 8 || seconds - settleCredit > 2.5
        }
    }

    // MARK: - Step receipts

    /// How a step line ends when it was not plainly ok.
    enum Receipt: String, Equatable {
        /// Refused before any input reached the app.
        case notSent = "not sent"
        /// Input went out, the effect check saw no change where one was expected.
        case noEffectSeen = "no effect seen"
        /// Input may have gone out and the result could not be verified (a read timed out).
        case outcomeUnknown = "outcome unknown"
    }

    static func failureReceipt(_ delivery: DeliveryState) -> Receipt? {
        switch delivery {
        case .notSent: return .notSent
        case .outcomeUnknown: return .outcomeUnknown
        case .acknowledged, .verified: return nil
        }
    }

    /// Tools whose success normally changes something the tree shows (scroll, drag and text selection may not).
    static let changeExpectedTools: Set<String> = [
        "click", "type_text", "set_value", "press_menu", "press_key", "perform_secondary_action",
    ]

    static func expectsVisibleChange(tool: String) -> Bool { changeExpectedTools.contains(tool) }

    /// Whether `effectLines` output means nothing changed.
    static func sawNoChange(_ lines: [String]) -> Bool { lines == ["no visible change"] }

    /// The step line with its receipt on the end (first line only; a step's own multi-line result stays intact).
    static func line(_ line: String, receipt: Receipt?) -> String {
        guard let receipt else { return line }
        var parts = line.components(separatedBy: "\n")
        parts[0] += " - " + receipt.rawValue
        return parts.joined(separator: "\n")
    }

    /// The closing advice after a failed step.
    static func advice(for delivery: DeliveryState, stepNumber: Int) -> String {
        switch delivery {
        case .notSent:
            return "Step \(stepNumber) was not sent. Fix it using the state below and continue from that step."
        case .outcomeUnknown:
            return "Check whether step \(stepNumber) took effect before retrying. Resume at the first unfinished step."
        case .acknowledged, .verified:
            return "Step \(stepNumber) was sent. Inspect its result before continuing."
        }
    }

    // MARK: - Effect lines

    /// Numbered tree lines of a state text, as number to the line without indentation, number, frame or action list.
    static func entries(_ state: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for raw in state.split(separator: "\n") {
            let line = String(raw)
            guard let number = LeanOutput.leadingIndex(line), let index = Int(number) else { continue }
            let stripped = AXStateDiff.strippedContent(of: line)
            result[index] = normalizedBody(stripped)
        }
        return result
    }

    private static func normalizedBody(_ body: String) -> String {
        var text = body
        if let range = text.range(of: " Secondary Actions:") { text = String(text[..<range.lowerBound]) }
        if let range = text.range(of: ", Secondary Actions:") { text = String(text[..<range.lowerBound]) }
        if let range = text.range(of: " Frame: x=") { text = String(text[..<range.lowerBound]) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Lines saying what `after` shows that `before` did not. `reportedGone` keeps numbers already listed
    /// as gone in this batch, so an element is named once. Returns `["no visible change"]` when nothing differs.
    static func effectLines(before: String, after: String, reportedGone: inout Set<Int>) -> [String] {
        let old = entries(before)
        let new = entries(after)
        reportedGone.subtract(new.keys)

        var changed: [String] = []
        for index in new.keys.sorted() {
            guard let was = old[index], let now = new[index], was != now else { continue }
            changed.append(describeChange(index: index, old: was, new: now))
        }
        let added = new.keys.filter { old[$0] == nil }.sorted()
        let gone = old.keys.filter { new[$0] == nil && !reportedGone.contains($0) }.sorted()
        reportedGone.formUnion(gone)

        guard !changed.isEmpty || !added.isEmpty || !gone.isEmpty else { return ["no visible change"] }

        var lines: [String] = []
        // A big redraw (a page load, a list refresh) is one line, not a wall of numbers.
        if changed.count + added.count + gone.count > 14 {
            lines.append("screen changed a lot: \(changed.count) changed, \(added.count) new, \(gone.count) gone")
            return lines
        }
        for line in changed.prefix(maxEffectLines) { lines.append("effect: " + line) }
        if changed.count > maxEffectLines { lines.append("effect: (+\(changed.count - maxEffectLines) more changed)") }
        if !added.isEmpty { lines.append("new: " + listed(added, in: new)) }
        if !gone.isEmpty { lines.append("gone: " + listed(gone, in: old)) }
        return lines
    }

    private static func listed(_ numbers: [Int], in table: [Int: String], shown: Int = 4) -> String {
        var parts = numbers.prefix(shown).map { "\($0) \(shortened(table[$0] ?? "", words: 5))" }
        if numbers.count > shown { parts.append("(+\(numbers.count - shown) more)") }
        return parts.joined(separator: ", ")
    }

    /// `12 checkbox Interface off→on`: the words both lines share, then what differs.
    static func describeChange(index: Int, old: String, new: String) -> String {
        let oldWords = old.split(separator: " ").map(String.init)
        let newWords = new.split(separator: " ").map(String.init)
        var prefix = 0
        while prefix < oldWords.count, prefix < newWords.count, oldWords[prefix] == newWords[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldWords.count - prefix, suffix < newWords.count - prefix,
              oldWords[oldWords.count - 1 - suffix] == newWords[newWords.count - 1 - suffix] { suffix += 1 }
        var head = Array(newWords[0..<prefix])
        if head.count > 6 { head = Array(head.prefix(2)) + ["…"] + Array(head.suffix(3)) }
        let was = oldWords[prefix..<(oldWords.count - suffix)].joined(separator: " ")
        let now = newWords[prefix..<(newWords.count - suffix)].joined(separator: " ")
        let lead = ([String(index)] + head).joined(separator: " ")
        switch (was.isEmpty, now.isEmpty) {
        case (true, false): return "\(lead) +\(clip(now))"
        case (false, true): return "\(lead) -\(clip(was))"
        default: return "\(lead) \(clip(was))→\(clip(now))"
        }
    }

    private static func clip(_ text: String, limit: Int = 40) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func shortened(_ text: String, words: Int) -> String {
        let parts = text.split(separator: " ")
        return parts.count > words ? parts.prefix(words).joined(separator: " ") + "…" : text
    }

    // MARK: - Window continuity

    struct WindowSig: Equatable {
        var id: UInt32?
        var title: String?
        /// Title of the sheet, dialog or alert the state shows, if any.
        var dialog: String?
    }

    static func windowSig(state: String, id: UInt32?) -> WindowSig {
        WindowSig(id: id, title: windowTitle(in: state), dialog: dialog(in: state))
    }

    /// A window's number and frame, read from the window list (no accessibility tree).
    struct WindowIdentity: Equatable {
        let id: UInt32
        let bounds: CGRect
    }

    /// Whether an element-number or ref step must stop because its window is no longer the one the batch started
    /// in. Only checked once the effect budget is spent: the optional reads that track the window have stopped by then.
    static func elementStepMovedWindow(effectsOn: Bool, budgetExhausted: Bool, start: WindowIdentity?,
                                       now: () -> WindowIdentity?) -> Bool {
        guard effectsOn, budgetExhausted, let start else { return false }
        guard let current = now() else { return true }
        // Element numbers belong to the window, not its position: a window the user moved or resized is
        // still the same window. A different window id means the numbers no longer apply.
        return current.id != start.id
    }

    /// The step line when cancellation arrives during a step. A step whose input went out says so.
    static func cancelledStepLine(number: Int, description: String, delivery: DeliveryState) -> String {
        let head = "\(number). \(description): "
        switch delivery {
        case .notSent:
            return head + "cancelled during step"
        case .acknowledged, .verified:
            return head + "sent, cancelled after delivery (\(delivery.rawValue))"
        case .outcomeUnknown:
            return head + "sent, outcome unknown after cancellation. Inspect before retrying."
        }
    }

    struct Watch {
        let text: String
        let sig: WindowSig
        let result: ToolCallResult

        /// Reuse only a complete read of the same app and exact window. An
        /// unchanged read or dialog transition still needs the original check.
        static func afterAction(
            snapshot: AppSnapshot?, before: String, tool: String, fallback: () -> Watch?
        ) -> Watch? {
            guard ["click", "type_text", "set_value", "scroll"].contains(tool),
                  let snapshot, let id = snapshot.observedWindowID else { return fallback() }
            let result = LeanOutput.condensed(.text(snapshot.renderedText))
            guard let text = LeanOutput.stateText(of: result),
                  let sig = reusableSignature(before: before, after: text, id: id) else { return fallback() }
            return Watch(text: text, sig: sig, result: result)
        }

        /// A read the monitor may treat as the app's full state: nothing hidden, absence checks supported.
        static func isComplete(_ state: String) -> Bool {
            DoneCheck.supportsAbsenceCheck(state) && !state.contains("the app hides its web content")
        }

        static func reusableSignature(before: String, after: String, id: UInt32) -> WindowSig? {
            let head = before.split(separator: "\n", maxSplits: 3).prefix(3)
            guard head.count == 3, head.last == "Window ID: \(id)",
                  head.first == after.split(separator: "\n", maxSplits: 1).first,
                  after != before, DoneCheck.supportsAbsenceCheck(before), DoneCheck.supportsAbsenceCheck(after),
                  !before.contains("the app hides its web content"), !after.contains("the app hides its web content")
            else { return nil }
            let sig = BatchEffects.windowSig(state: after, id: id)
            return sig.dialog == BatchEffects.dialog(in: before) ? sig : nil
        }
    }

    /// The title from `Window: "Untitled", App: Notes.`
    static func windowTitle(in state: String) -> String? {
        guard let line = state.split(separator: "\n", maxSplits: 4).first(where: { $0.hasPrefix("Window: ") }),
              let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close
        else { return nil }
        // The header ends `", App: X.`; take up to the quote before it.
        if let marker = line.range(of: "\", App: ") { return String(line[line.index(after: open)..<marker.lowerBound]) }
        return String(line[line.index(after: open)..<close])
    }

    /// The title of the first sheet, dialog or alert line, e.g. `\t5 sheet Save` gives "Save".
    static func dialog(in state: String) -> String? {
        for raw in state.split(separator: "\n") {
            var words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let first = words.first, first.allSatisfy(\.isNumber) { words.removeFirst() }
            guard let role = words.first, ["sheet", "dialog", "alert"].contains(role) else { continue }
            words.removeFirst()
            if let first = words.first, first.hasPrefix("(") {
                while let word = words.first {
                    words.removeFirst()
                    if word.hasSuffix(")") { break }
                }
            }
            let stop = words.firstIndex { $0 == "Secondary" || $0 == "ID:" || $0 == "Help:" } ?? words.count
            let title = words[0..<stop].joined(separator: " ")
            return title.isEmpty ? role : "\(role) " + clip(title)
        }
        return nil
    }

    enum WindowVerdict: Equatable {
        case same
        /// A sheet or dialog opened or closed (the step itself did that): report it, then follow the new window.
        case dialog(String)
        /// The batch is no longer in the window it started in.
        case moved(String)
    }

    static func compare(bound: WindowSig, now: WindowSig) -> WindowVerdict {
        if bound.dialog != now.dialog {
            switch (bound.dialog, now.dialog) {
            case (nil, let opened?): return .dialog("windows: opened \(quotedDialog(opened))")
            case (let closed?, nil): return .dialog("windows: closed \(quotedDialog(closed))")
            case (let from?, let to?): return .dialog("windows: \(quotedDialog(from)) replaced by \(quotedDialog(to))")
            default: break
            }
        }
        // Only window ids tell windows apart. A title alone is not proof of another window: saving renames
        // "Untitled" to "notes.txt" in the same window, so without ids the batch stays where it is.
        guard let a = bound.id, let b = now.id, a != b else { return .same }
        return .moved(now.title ?? "another window")
    }

    /// `sheet Save` as `"Save" (sheet)`.
    private static func quotedDialog(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "(\(text))" }
        return "\"\(parts[1])\" (\(parts[0]))"
    }

    // MARK: - wait step

    /// The cheap check only decides when to take a full verification read.
    /// Periodic full reads cover labels and dialogs a shallow AX probe can miss.
    struct WaitReadGate {
        var nextFullRead: TimeInterval
        static let fallbackInterval: TimeInterval = 0.75

        mutating func shouldRead(at now: TimeInterval, probe: () -> Bool?) -> Bool {
            guard now >= nextFullRead || probe() != false else { return false }
            nextFullRead = now + Self.fallbackInterval
            return true
        }
    }

    static func waitMayBeReady(_ kind: Wait.Kind, app: String, windowID: UInt32?) -> Bool? {
        guard (try? requireUsableComputerUseSession()) != nil,
              let app = try? AppDiscovery.resolveRunning(app),
              let context = try? SnapshotBuilder.resolveTargetWindow(for: app, windowID: windowID) else { return nil }
        switch kind {
        case .window(let title):
            if SmartSteps.axText(kAXTitleAttribute, of: context.windowElement)?.localizedCaseInsensitiveContains(title) == true {
                return true
            }
            return SmartSteps.sheetCandidates(pid: app.pid).contains {
                SmartSteps.axText(kAXTitleAttribute, of: $0)?.localizedCaseInsensitiveContains(title) == true
            }
        case .text(let text), .gone(let text):
            let criteria = TargetedAX.Criteria(text: text, exact: false, role: nil, limit: 1, maxNodes: 32)
            guard let scan = try? SnapshotBuilder.targetedSearch(criteria, in: context, timeout: 0.06) else { return nil }
            switch kind {
            case .text: return !scan.records.isEmpty
            case .gone: return scan.records.isEmpty
            default: return nil
            }
        case .settle:
            return !WindowSettle.busy(from: context.windowElement, requireComplete: true, read: WindowSettle.readAll)
        }
    }

    /// `{"tool": "wait", "window": "Save"}` (or text, gone, settle: true, timeout_ms).
    struct Wait {
        enum Kind: Equatable {
            case window(String)
            case text(String)
            case gone(String)
            case settle
        }
        static let defaultTimeoutMs = 5_000
        static let maxTimeoutMs = 30_000
        /// How long the state must stay the same for `settle`.
        static let settleQuietMs = 450

        let kind: Kind
        let timeoutMs: Int

        /// Whole milliseconds for a number a model sent. Clamped to 0...maxTimeoutMs before the Int conversion,
        /// which traps on huge values; non-finite input is rejected.
        static func milliseconds(_ value: Double, perUnit: Double = 1) throws -> Int {
            guard value.isFinite else { throw ComputerUseError.invalidArguments("wait time must be a finite number") }
            return Int(min(max(value * perUnit, 0), Double(maxTimeoutMs)))
        }

        /// Seconds this wait may poll, limited by its own timeout and the batch's remaining time.
        func pollSeconds(elapsedInBatch: TimeInterval, budget: TimeInterval) -> TimeInterval {
            min(Double(timeoutMs) / 1000, max(budget - elapsedInBatch, 0))
        }

        private var lastHash: Int?
        private var stableSince: Date?

        init(kind: Kind, timeoutMs: Int) {
            self.kind = kind
            self.timeoutMs = timeoutMs
        }

        /// Spellings models use for the wait keys, mapped to the real key.
        static let keyAliases: [String: String] = [
            "for_window": "window", "dialog": "window", "sheet": "window",
            "until": "text", "for_text": "text", "appears": "text", "contains": "text", "visible": "text",
            "disappears": "gone", "until_gone": "gone", "absent": "gone", "not_visible": "gone",
            "ms": "timeout_ms", "duration_ms": "timeout_ms", "milliseconds": "timeout_ms", "max_ms": "timeout_ms",
        ]

        init(arguments rawArguments: [String: Any]) throws {
            var arguments = rawArguments
            for (alias, key) in Self.keyAliases where arguments[key] == nil {
                if let value = arguments[alias] { arguments[key] = value }
            }
            // Seconds given as timeout_s / timeout_seconds / timeout (a small number is seconds).
            if arguments["timeout_ms"] == nil {
                let seconds = ["timeout_s", "timeout_seconds", "timeout"].lazy.compactMap { key -> Double? in
                    (arguments[key] as? NSNumber)?.doubleValue ?? Double((arguments[key] as? String) ?? "")
                }.first
                if let seconds { arguments["timeout_ms"] = try Self.milliseconds(seconds, perUnit: seconds <= 60 ? 1000 : 1) }
            }
            func text(_ key: String) -> String? {
                (arguments[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            let settleRaw = arguments["settle"]
            let settle = (settleRaw as? Bool)
                ?? (settleRaw as? NSNumber).map { $0.intValue != 0 }
                ?? ["true", "yes", "1", "on"].contains(((settleRaw as? String) ?? "").lowercased())
            if let window = text("window") {
                kind = .window(window)
            } else if let wanted = text("text") {
                kind = .text(wanted)
            } else if let gone = text("gone") {
                kind = .gone(gone)
            } else if settle {
                kind = .settle
            } else {
                throw ComputerUseError.invalidArguments(
                    "wait needs one of window, text, gone or settle: true, e.g. {\"tool\": \"wait\", \"window\": \"Export\", \"timeout_ms\": 8000}"
                )
            }
            let given = (arguments["timeout_ms"] as? NSNumber)?.intValue ?? Int((arguments["timeout_ms"] as? String) ?? "")
            timeoutMs = min(max(given ?? Self.defaultTimeoutMs, 100), Self.maxTimeoutMs)
        }

        /// Words for the step line: `window "Save"`, `settle`.
        var summary: String {
            switch kind {
            case .window(let value): return "window \"\(BatchEffects.clip(value))\""
            case .text(let value): return "text \"\(BatchEffects.clip(value))\""
            case .gone(let value): return "gone \"\(BatchEffects.clip(value))\""
            case .settle: return "settle"
            }
        }

        var timeoutReason: String {
            switch kind {
            case .window(let value): return "window \"\(BatchEffects.clip(value))\" did not appear"
            case .text(let value): return "text \"\(BatchEffects.clip(value))\" did not appear"
            case .gone(let value): return "\"\(BatchEffects.clip(value))\" is still there"
            case .settle: return "the screen kept changing"
            }
        }

        /// Whether this read meets the condition. `settle` needs the same state on reads at least
        /// `settleQuietMs` apart, so call it with each new read.
        mutating func isMet(state: String, id: UInt32? = nil, now: Date = Date()) -> Bool {
            switch kind {
            case .window(let wanted):
                let sig = BatchEffects.windowSig(state: state, id: id)
                return [sig.title, sig.dialog].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(wanted) }
            case .text(let wanted):
                return state.localizedCaseInsensitiveContains(wanted)
            case .gone(let wanted):
                return DoneCheck.supportsAbsenceCheck(state) && !state.localizedCaseInsensitiveContains(wanted)
            case .settle:
                guard DoneCheck.supportsAbsenceCheck(state) else {
                    lastHash = nil
                    stableSince = nil
                    return false
                }
                let hash = BatchTool.stateText(ofText: state).hashValue
                if hash != lastHash {
                    lastHash = hash
                    stableSince = now
                    return false
                }
                return now.timeIntervalSince(stableSince ?? now) * 1000 >= Double(Self.settleQuietMs)
            }
        }
    }
}
