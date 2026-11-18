import Foundation

/// Level 3, "handoff": the main model gives GODSPEED a bounded subtask and it runs alone, coming back only
/// when the goal is done, it is stuck, or it is unsure. Same background paths as `batch` (every action is an
/// ordinary tool call; focus is borrowed only for an open dialog, exactly as a batch does).
///
/// Loop: replay a saved recipe for the goal when there is one; else read the state, build up to 12 candidate
/// actions (labelled controls the goal mentions, each given value typed into a matching field, Return, a
/// scroll), have the helper's d1 score them as options (POST /choose), and act on the top one only when it
/// is at least 60% sure and 20 points ahead of the next. After each action `done_when` is checked in code.
/// It stops on done, on stuck (two steps that changed nothing, two failed steps, or the checker's stuck
/// verdict), on a risky control (Delete, Send, Buy, Pay ...: escalated, never pressed), and on budget.
enum HandoffTool {
    static let name = "handoff"
    static let defaultMaxSteps = 15
    static let maxStepsCap = 30
    static let defaultTimeBudget: TimeInterval = 60
    static let timeBudgetCap: TimeInterval = 300
    static let maxCandidates = 12
    /// The best option must reach this probability and lead the runner-up (another option, or "none") by the margin.
    static let minProbability = 0.6
    static let minMargin = 0.2
    static let maxScrolls = 3
    static let changeLimit = 600

    // MARK: Request

    struct Request {
        let app: String
        let goal: String
        let doneWhen: [DoneCheck.Condition]
        /// Text to type, in the order given. The key hints which field it belongs in ("Name", "To").
        let values: [(key: String, value: String)]
        let maxSteps: Int
        let timeBudget: TimeInterval
    }

    static func parse(_ arguments: [String: Any]) throws -> Request {
        guard let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else {
            throw ComputerUseError.invalidArguments("handoff needs \"app\"")
        }
        guard let goal = (arguments["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
            throw ComputerUseError.invalidArguments("handoff needs \"goal\" (one bounded subtask)")
        }
        let doneWhen = try DoneCheck.parse(arguments["done_when"])
        guard !doneWhen.isEmpty else {
            throw ComputerUseError.invalidArguments(
                "handoff needs \"done_when\", how GODSPEED knows it is finished, e.g. {\"text\": \"Saved\"} or {\"field\": \"Name\", \"equals\": \"Ann\"}"
            )
        }
        var values: [(key: String, value: String)] = []
        if let map = arguments["values"] as? [String: Any] {
            for key in map.keys.sorted() {
                let value = map[key].map { "\($0)" } ?? ""
                if !value.isEmpty { values.append((key, value)) }
            }
        } else if let list = arguments["values"] as? [Any] {
            for case let entry as [String: Any] in list {
                if let key = (entry["label"] ?? entry["field"] ?? entry["key"]) as? String, let value = entry["value"] {
                    values.append((key, "\(value)"))
                }
            }
        } else if arguments["values"] != nil, !(arguments["values"] is NSNull) {
            throw ComputerUseError.invalidArguments("values is a map like {\"Name\": \"Ann\"}")
        }
        func number(_ key: String) -> Double? {
            let parsed = (arguments[key] as? NSNumber).map(\.doubleValue) ?? (arguments[key] as? String).flatMap(Double.init)
            guard let parsed, parsed.isFinite else { return nil }
            return parsed
        }
        let steps = Int(min(Double(maxStepsCap), max(1, number("max_steps") ?? Double(defaultMaxSteps))))
        let budget = min(timeBudgetCap, max(5, number("time_budget_s") ?? defaultTimeBudget))
        return Request(app: app, goal: goal, doneWhen: doneWhen, values: values, maxSteps: steps, timeBudget: budget)
    }

    // MARK: Controls read from a state

    struct Control: Equatable {
        let index: Int
        let role: String
        let label: String
        let value: String?
        let disabled: Bool
    }

    /// Longest first, so "text entry area" wins over "text".
    static let roles: [String] = [
        "text entry area", "secure text field", "search text field", "text field", "text area", "combo box",
        "pop up button", "menu button", "menu item", "radio button", "disclosure triangle",
        "button", "checkbox", "link", "tab", "switch", "toggle", "scroll area",
    ].sorted { $0.count > $1.count }

    static let fieldRoles: Set<String> = ["text entry area", "search text field", "text field", "text area", "combo box"]
    static let clickRoles: Set<String> = [
        "button", "pop up button", "menu button", "menu item", "radio button", "disclosure triangle", "checkbox", "link", "tab", "switch", "toggle",
    ]

    /// Controls named in a state text: lines like `\t3 button (disabled, w:float) Save` or `\t2 text field To = a (w:str)`.
    static func parseControls(_ state: String) -> [Control] {
        var controls: [Control] = []
        for raw in state.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let index = Int(line[..<space]) else { continue }
            line = String(line[line.index(after: space)...])
            if let cut = line.range(of: ", Secondary Actions:") { line = String(line[..<cut.lowerBound]) }
            guard let role = roles.first(where: { line == $0 || line.hasPrefix($0 + " ") }) else { continue }
            var rest = String(line.dropFirst(role.count)).trimmingCharacters(in: .whitespaces)
            var disabled = false
            if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                disabled = rest[..<close].contains("disabled")
                rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            rest = rest.replacingOccurrences(of: #"\s*\(w:[a-z]+\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            var label = rest
            var value: String?
            if rest.hasSuffix(" =") {
                label = String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces)
                value = ""
            } else if let equals = rest.range(of: " = ") {
                label = String(rest[..<equals.lowerBound]).trimmingCharacters(in: .whitespaces)
                value = String(rest[equals.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            controls.append(Control(index: index, role: role, label: label, value: value, disabled: disabled))
        }
        return controls
    }

    // MARK: Risk

    /// Whole words that make a control one the model must decide on, never GODSPEED on its own.
    static let riskyWords: Set<String> = [
        "delete", "remove", "send", "buy", "pay", "purchase", "order", "submit", "erase", "trash", "discard",
        "publish", "post", "transfer", "unsubscribe", "format", "reset", "wipe", "checkout",
        "empty", "overwrite", "replace", "install", "uninstall", "quit", "shutdown", "restart", "logout", "signout",
        "subscribe", "donate", "authorize", "allow", "grant", "revoke", "clear", "destroy", "terminate", "disable",
        "share", "invite", "confirm", "agree", "accept",
    ]

    /// Buttons that are often the default action of a form: Return would press them.
    static let submitWords: Set<String> = [
        "send", "buy", "pay", "purchase", "order", "submit", "post", "publish", "transfer", "checkout", "subscribe", "donate",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func isRisky(label: String) -> Bool {
        !riskyWords.isDisjoint(with: words(label))
    }

    // MARK: Candidates

    struct Candidate {
        enum Kind { case click, setValue, pressReturn, scroll }
        let id: String
        let kind: Kind
        /// What d1 and the reply call it: `click "Save"`, `type "Ann" into "Name"`.
        let text: String
        let tool: String
        let arguments: [String: Any]
        let risky: Bool
        /// Identity for "already tried": the same action is not offered twice in one handoff.
        let key: String
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "into", "then", "this", "that", "from", "click", "button", "press", "field", "your", "are", "has",
    ]
    static let progressWords: Set<String> = [
        "ok", "okay", "done", "save", "next", "continue", "add", "create", "apply", "open", "new", "accept", "confirm",
        "search", "go", "yes", "finish", "start",
    ]

    /// How well a control's label fits what the goal talks about: shared words count 1, a prefix stem 0.5, a generic
    /// forward button 0.5. Zero means the control is not offered.
    static func relevance(label: String, goalWords: Set<String>, countingProgressWords: Bool = true) -> Double {
        var score = 0.0
        for word in words(label) where !stopWords.contains(word) {
            if goalWords.contains(word) {
                score += 1
            } else if word.count >= 4, goalWords.contains(where: { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }) {
                score += 0.5
            } else if countingProgressWords, progressWords.contains(word) {
                score += 0.5
            }
        }
        return score
    }

    /// Up to `maxCandidates` actions worth scoring, most promising first: typing of each given value, clicks on
    /// labelled controls the goal mentions, Return after typing, a scroll. Nothing already tried; no disabled
    /// control; a risky control only when the goal names it (so the model sees it and decides).
    static func candidates(
        goal: String,
        doneSummary: String,
        values: [(key: String, value: String)],
        controls: [Control],
        tried: Set<String>,
        typedAny: Bool,
        scrollsDone: Int
    ) -> [Candidate] {
        var found: [Candidate] = []
        func add(_ kind: Candidate.Kind, text: String, tool: String, arguments: [String: Any], risky: Bool = false, key: String) {
            guard !tried.contains(key), !found.contains(where: { $0.key == key }) else { return }
            found.append(Candidate(id: "", kind: kind, text: text, tool: tool, arguments: arguments, risky: risky, key: key))
        }

        // 1. Typing: each value into the fields that fit its key, else into up to two empty fields.
        // Never into a password or other secret field: that is the model's call (and the secret stays out of d1).
        let fields = controls.filter { fieldRoles.contains($0.role) && !$0.disabled && !RecipeLocator.looksSecret($0.label) }
        for (key, value) in values {
            let keyWords = Set(words(key))
            var matches = fields.filter { field in
                let name = field.label.lowercased()
                let loose = key.count >= 3 && name.contains(key.lowercased())
                return loose || !keyWords.isDisjoint(with: words(field.label))
            }
            if matches.isEmpty { matches = Array(fields.filter { ($0.value ?? "").isEmpty && ($0.role != "text entry area" || $0.label.isEmpty) }.prefix(2)) }
            for field in matches.prefix(3) {
                if field.value == value || field.label == value { continue } // already there
                let name = field.label.isEmpty || field.role == "text entry area" ? field.role : field.label
                let shown = RecipeLocator.looksSecret(key) ? "(hidden)" : (value.count > 40 ? String(value.prefix(40)) + "..." : value)
                add(.setValue, text: "type \"\(shown)\" into \"\(name)\"", tool: "set_value",
                    arguments: ["element_index": String(field.index), "value": value], key: "set|\(value)|\(field.index)")
            }
        }

        // 2. Clicks on labelled controls, ranked by how well they fit the goal.
        var goalWords = Set(words(goal + " " + doneSummary + " " + values.map(\.key).joined(separator: " ")))
        goalWords.subtract(stopWords)
        let labelCounts = Dictionary(controls.map { ($0.label, 1) }, uniquingKeysWith: +)
        let ranked = controls.enumerated().compactMap { offset, control -> (Double, Int, Control)? in
            guard clickRoles.contains(control.role), !control.disabled, !control.label.isEmpty else { return nil }
            // A risky control is offered only when the goal names it; a generic "Next" or "Save" needs no mention.
            let risky = isRisky(label: control.label)
            // The risky word itself (Delete, Send ...) must be in the goal, not just the control's other words.
            if risky, Set(words(control.label)).intersection(riskyWords).isDisjoint(with: goalWords) { return nil }
            let score = relevance(label: control.label, goalWords: goalWords, countingProgressWords: !risky)
            guard score > 0 else { return nil }
            return (score, offset, control)
        }.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        for (_, _, control) in ranked {
            let unique = labelCounts[control.label] == 1
            let args: [String: Any] = unique ? ["label": control.label] : ["element_index": String(control.index)]
            // Same-named controls are different actions: the position is part of what was tried.
            add(.click, text: "click \"\(control.label)\"" + (unique ? "" : " (#\(control.index))"), tool: "click", arguments: args,
                risky: isRisky(label: control.label), key: "click|\(control.role)|\(control.label)" + (unique ? "" : "|\(control.index)"))
        }

        // 3. Return, once something was typed.
        if typedAny {
            // Return presses the default button, which may be Send or Delete: risky while such a button is on screen.
            let defaultMayBeRisky = controls.contains {
                clickRoles.contains($0.role) && !$0.disabled && !submitWords.isDisjoint(with: words($0.label))
            }
            add(.pressReturn, text: "press Return", tool: "press_key", arguments: ["key": "Return"], risky: defaultMayBeRisky, key: "return")
        }

        // 4. Scroll down, a few times.
        if scrollsDone < maxScrolls, let area = controls.first(where: { $0.role == "scroll area" }) {
            add(.scroll, text: "scroll down", tool: "scroll",
                arguments: ["direction": "down", "element_index": String(area.index)], key: "scroll|\(scrollsDone)")
        }

        // Typing first, then the best clicks, Return, scroll; the cut falls on the weakest clicks.
        let limited = Array(found.prefix(maxCandidates))
        return limited.enumerated().map { offset, item in
            Candidate(id: String(Character(UnicodeScalar(UInt8(97 + offset)))), kind: item.kind, text: item.text, tool: item.tool,
                      arguments: item.arguments, risky: item.risky, key: item.key)
        }
    }

    // MARK: Decision

    enum Decision {
        case act(Candidate, probability: Double)
        case escalate(String)
    }

    /// Acts only on a clear winner: probability at least `minProbability`, a lead of at least `minMargin` over
    /// the runner-up (any other option or "none"), and not a risky control. Anything else is the model's call.
    static func decide(candidates: [Candidate], probabilities: [String: Double]?) -> Decision {
        guard !candidates.isEmpty else { return .escalate("no action on screen fits the goal") }
        guard let probabilities else { return .escalate("the checker model is not available, so GODSPEED cannot rank the options") }
        let scored = candidates.map { ($0, probabilities[$0.id] ?? 0) }.sorted { $0.1 > $1.1 }
        let (best, p) = scored[0]
        let runnerUp = max(scored.dropFirst().first?.1 ?? 0, probabilities["none"] ?? 0)
        if (probabilities["none"] ?? 0) >= p {
            return .escalate("the checker says none of the options fits")
        }
        if p < minProbability {
            return .escalate("not sure which action is right (best is \(best.text) at \(percent(p)))")
        }
        if p - runnerUp < minMargin {
            let next = scored.dropFirst().first.map { " \($0.0.text)" } ?? " none of them"
            return .escalate("two options are close (\(best.text) at \(percent(p)), next:\(next) at \(percent(runnerUp)))")
        }
        if best.risky {
            return .escalate("the best action is risky (\(best.text)); the model should decide")
        }
        return .act(best, probability: p)
    }

    /// A saved recipe that presses a risky control is never replayed unattended: the model decides those.
    static func recipeIsRisky(_ steps: [Any]) -> Bool {
        steps.contains { item in
            guard let dict = item as? [String: Any] else { return false }
            return (dict["label"] as? String).map { isRisky(label: $0) } ?? false
        }
    }

    /// Verify from the driver's receipt. Display text can include app-controlled content.
    static func batchReportsVerifiedDone(_ result: ToolCallResult) -> Bool {
        !result.isError && result.batchReceipt?.doneCheck == .verified
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: Runner

    struct ActResult {
        let ok: Bool
        let message: String
        var delivery: BatchEffects.Receipt? = nil
        var observedState: String? = nil
    }

    struct Outcome {
        enum Kind { case done, stuck, escalate, budget, failed }
        let kind: Kind
        let reason: String
        let steps: [String]
        let changes: String?
        /// On an escalation: the top options and their scores, so the model can decide.
        let options: [(text: String, probability: Double)]
        /// The window and first key lines of the screen where it stopped, so the model can pick without another read.
        var screen: String = ""
        /// What done_when still lacks.
        var unmet: [String] = []

        /// One outcome line, the steps taken, the net change and, when it needs the model, the top options.
        func reply() -> String {
            var lines: [String] = []
            switch kind {
            case .done: lines.append("Done: \(reason)")
            case .stuck: lines.append("Stuck: \(reason)")
            case .escalate: lines.append("Needs you: \(reason)")
            case .budget: lines.append("Stopped: \(reason)")
            case .failed: lines.append("Failed: \(reason)")
            }
            if steps.isEmpty {
                lines.append("Steps: none")
            } else {
                let shown = steps.count > 10 ? ["..."] + steps.suffix(10) : steps
                lines.append("Steps (\(steps.count)): " + shown.joined(separator: "; "))
            }
            if let changes, !changes.isEmpty { lines.append("Changes: " + changes) }
            if kind != .done {
                if !unmet.isEmpty { lines.append("Still missing: " + unmet.joined(separator: "; ")) }
                if !screen.isEmpty { lines.append("Screen now:\n" + screen) }
            }
            if !options.isEmpty {
                lines.append("Top options (pick one with click/set_value, or do something else): " + options.prefix(4).enumerated().map {
                    "\($0.offset + 1). \($0.element.text) (\(percent($0.element.probability)))"
                }.joined(separator: "; "))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Everything the loop touches outside itself, so tests can run it with fakes.
    struct Dependencies {
        var readState: () -> String?
        /// Runs one candidate. The state text it was chosen from lets the caller borrow focus for a dialog.
        var act: (Candidate, _ state: String) -> ActResult
        var choose: (_ goal: String, _ doneWhen: String, _ history: String, _ screen: String, _ options: [(id: String, text: String)]) -> [String: Double]?
        /// The checker model's stuck verdict for a short summary.
        var looksStuck: (_ goal: String, _ lastStep: String, _ summary: String) -> Bool
        var check: (_ state: String) -> DoneCheck.Result
        /// A saved recipe's replay: nil when there is none, else whether it reached the goal.
        var replay: () -> Bool?
        var now: () -> TimeInterval
    }

    static func run(_ request: Request, _ deps: Dependencies, deadline: TimeInterval? = nil) -> Outcome {
        let deadline = deadline ?? deps.now() + request.timeBudget
        func hasTime() -> Bool { deps.now() < deadline }
        var steps: [String] = []
        var tried = Set<String>()
        var typedAny = false
        var scrolls = 0
        var noChange = 0
        var failures = 0
        let doneSummary = request.doneWhen.map(\.summary).joined(separator: "; ")
        var lastUnmet: [String] = []
        func verdict(_ state: String) -> DoneCheck.Result {
            let result = deps.check(state)
            if case .missing(let unmet) = result { lastUnmet = unmet } else { lastUnmet = [] }
            return result
        }

        func finish(_ kind: Outcome.Kind, _ reason: String, initial: String?, latest: String?,
                    options: [(text: String, probability: Double)] = []) -> Outcome {
            var changes: String?
            if let initial, let latest, !steps.isEmpty {
                changes = AXStateDiff.diff(previous: initial, current: latest).map { String($0.prefix(changeLimit)) }
                    ?? "the screen changed a lot"
                if changes == AXStateDiff.noChangesMessage { changes = "the screen did not change" }
            }
            return Outcome(kind: kind, reason: reason, steps: steps, changes: changes, options: options,
                           screen: kind == .done ? "" : (latest.map { RefereeSummary.screen(from: $0) } ?? ""), unmet: lastUnmet)
        }

        guard hasTime() else {
            return finish(.budget, "the time budget elapsed before any action was sent", initial: nil, latest: nil)
        }
        guard var state = deps.readState() else {
            return finish(.failed, "could not read \(request.app)", initial: nil, latest: nil)
        }
        var initial = state
        // Already true: nothing to do, and no saved recipe may run (it could undo or repeat the work).
        if case .verified(let met) = verdict(state) {
            return Outcome(kind: .done, reason: "already true (\(met.joined(separator: "; ")))", steps: [], changes: nil, options: [])
        }

        guard hasTime() else {
            return finish(.budget, "the time budget elapsed before any action was sent", initial: initial, latest: state)
        }
        if let replayed = deps.replay() {
            steps.append("replayed the saved recipe")
            if replayed { return Outcome(kind: .done, reason: doneSummary.isEmpty ? "the saved recipe reached the goal" : "\(doneSummary) (saved recipe)", steps: steps, changes: nil, options: []) }
            guard hasTime() else {
                return finish(.budget, "the recipe may have partially run. Inspect its result before continuing.", initial: initial, latest: nil)
            }
            steps[steps.count - 1] = "the saved recipe did not finish; continued by hand"
            // The replay moved the screen; plan from what is there now.
            guard let fresh = deps.readState() else {
                return finish(.failed, "the saved recipe may have partially run; the app could not be read afterward", initial: initial, latest: nil)
            }
            state = fresh
            initial = fresh
            if case .verified(let met) = verdict(state) {
                return finish(.done, met.joined(separator: "; "), initial: initial, latest: state)
            }
        }

        for number in 1...request.maxSteps {
            if !hasTime() {
                return finish(.budget, "\(Int(request.timeBudget)) seconds used", initial: initial, latest: state)
            }
            let options = candidates(
                goal: request.goal, doneSummary: doneSummary, values: request.values,
                controls: parseControls(state), tried: tried, typedAny: typedAny, scrollsDone: scrolls
            )
            let history = steps.suffix(4).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let screen = RefereeSummary.screen(from: state)
            let probabilities = options.isEmpty ? nil : deps.choose(
                request.goal, doneSummary, history, screen, options.map { ($0.id, $0.text) }
            )
            switch decide(candidates: options, probabilities: probabilities) {
            case .escalate(let reason):
                let ranked = options.map { ($0.text, probabilities?[$0.id] ?? 0) }.sorted { $0.1 > $1.1 }
                return finish(.escalate, reason, initial: initial, latest: state, options: ranked)
            case .act(let choice, _):
                guard hasTime() else {
                    return finish(.budget, "the time budget elapsed before the next action was sent", initial: initial, latest: state)
                }
                tried.insert(choice.key)
                let result = deps.act(choice, state)
                if choice.kind == .setValue { typedAny = true }
                if choice.kind == .scroll { scrolls += 1 }
                if !hasTime(), result.observedState == nil {
                    steps.append(result.ok ? choice.text : "\(choice.text) failed")
                    return finish(.budget, "the last action may have run. Inspect its result before continuing.", initial: initial, latest: nil)
                }
                guard result.ok else {
                    steps.append("\(choice.text) failed")
                    if result.delivery == .outcomeUnknown {
                        let fresh = deps.readState()
                        if let fresh, case .verified(let met) = verdict(fresh) {
                            return finish(.done, met.joined(separator: "; "), initial: initial, latest: fresh)
                        }
                        return finish(.escalate, "the last action may have run. Inspect its result before continuing.", initial: initial, latest: fresh)
                    }
                    failures += 1
                    if failures >= 2 {
                        return finish(.stuck, "two actions failed in a row (last: \(choice.text): \(result.message))", initial: initial, latest: state)
                    }
                    guard let fresh = deps.readState() else {
                        return finish(.failed, "could not refresh the app after the failed action", initial: initial, latest: nil)
                    }
                    state = fresh
                    continue
                }
                failures = 0
                steps.append(choice.text)
                guard let next = result.observedState ?? deps.readState() else {
                    return finish(.failed, "lost sight of \(request.app) after \(choice.text)", initial: initial, latest: state)
                }
                let unchanged = AXStateDiff.diff(previous: state, current: next) == AXStateDiff.noChangesMessage
                noChange = unchanged ? noChange + 1 : 0
                state = next
                if case .verified(let met) = verdict(state) {
                    return finish(.done, met.joined(separator: "; "), initial: initial, latest: state)
                }
                if noChange >= 2 {
                    return finish(.stuck, "the last two actions changed nothing on screen", initial: initial, latest: state)
                }
                // A changed screen already gives the next step new evidence. Ask the checker
                // only on a stall that the two-action rule has not yet handled.
                if unchanged, number >= 2, number < request.maxSteps,
                   hasTime() {
                    let summary = RefereeSummary.build(
                        goal: request.goal, steps: steps.map { ($0, "ok") }, repeatedFailures: failures,
                        screenChanged: false, dialogOpen: RefereeSummary.dialogOpen(in: state),
                        changes: nil, screen: RefereeSummary.screen(from: state), maxCharacters: Referee.maxViewCharacters
                    )
                    if deps.looksStuck(request.goal, choice.text, summary) {
                        return finish(.stuck, "the checker model says no progress is being made", initial: initial, latest: state)
                    }
                }
            }
        }
        return finish(.budget, "\(request.maxSteps) steps used", initial: initial, latest: state)
    }
}

// MARK: - Dispatcher glue

extension ComputerUseToolDispatcher {
    /// The `handoff` tool. Runs on the same background paths as `batch`: ordinary tool calls, focus borrowed
    /// only while a dialog is open, then given back.
    func runHandoff(arguments: [String: Any]) throws -> ToolCallResult {
        let request = try HandoffTool.parse(arguments)
        guard request.app.lowercased() != "browser" else {
            throw ComputerUseError.invalidArguments("Handoff ranks native Mac actions. For websites, use browser read and a batch with an observable done_when.")
        }
        let focus = FocusBorrowSession()
        defer { focus.close() }
        let app = request.app
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + request.timeBudget

        let deps = HandoffTool.Dependencies(
            readState: { [self] in
                let read = callToolAsResult(name: "get_app_state", arguments: [
                    "app": app, "include_screenshot": NSNumber(value: false), "settle_ms": LeanDefaults.batchSettleMs,
                ])
                guard !read.isError else { return nil }
                return LeanOutput.stateText(of: read).map { BatchTool.stateText(ofText: $0) }
            },
            act: { [self] candidate, state in
                if FocusBorrow.isEnabled, RefereeSummary.dialogOpen(in: state),
                   let pid = (try? AppDiscovery.resolveRunning(app))?.pid {
                    focus.ensure(pid: pid)
                }
                var args = candidate.arguments
                args["app"] = app
                let result = BrowserCallBudget.withDeadline(deadline) {
                    callStepAsResult(name: candidate.tool, arguments: args, log: SmartLog(), notesInResult: false)
                }
                let state = !result.isError && candidate.kind != .pressReturn ? LeanOutput.stateText(of: result) : nil
                return HandoffTool.ActResult(
                    ok: !result.isError, message: BatchTool.firstLine(result.textContent),
                    delivery: result.isError ? BatchEffects.failureReceipt(result.textContent) : nil,
                    observedState: state.flatMap { text in
                        text.contains(SnapshotObservationOptions.accessibilityOmittedNote) ? nil : text
                    }
                )
            },
            choose: { goal, doneWhen, history, screen, options in
                Referee.choose(goal: goal, doneWhen: doneWhen, history: history, screen: screen,
                               options: options, remaining: deadline - clock.systemUptime)
            },
            looksStuck: { goal, lastStep, summary in
                guard let verdict = Referee.decide(goal: goal, lastStep: lastStep, result: "ok", summary: summary,
                                                   remaining: deadline - clock.systemUptime) else { return false }
                return verdict.label == "stuck" && verdict.confidence >= Referee.minimumConfidence
            },
            check: { [self] state in
                let isBrowser = app.lowercased() == "browser"
                return DoneCheck.check(request.doneWhen, evidence: DoneCheck.Evidence(
                    screenText: state,
                    pageURL: {
                        guard isBrowser, clock.systemUptime < deadline else { return nil }
                        return BrowserCallBudget.withDeadline(deadline) {
                            try? self.runBrowser(arguments: ["action": "location"]).browserObservationURL
                        }
                    }
                ))
            },
            replay: { [self] in
                // Recipe variables are named after field labels ("Name" -> "name"); the handoff's value keys map to them.
                var recipeValues: [String: String] = [:]
                for (key, value) in request.values { recipeValues[BatchRecipes.variableName(label: key)] = value }
                guard BatchRecipes.isEnabled,
                      let recipe = BatchRecipes.shared.find(app: app, goal: request.goal, values: recipeValues),
                      !HandoffTool.recipeIsRisky(recipe.steps)
                else { return nil }
                var batchArguments: [String: Any] = ["app": app, "goal": request.goal]
                if !recipeValues.isEmpty { batchArguments["values"] = recipeValues }
                if let doneWhen = arguments["done_when"] { batchArguments["done_when"] = doneWhen }
                guard let result = try? runBatch(arguments: batchArguments, inheritedDeadline: deadline), !result.isError else { return false }
                return HandoffTool.batchReportsVerifiedDone(result)
            },
            now: { clock.systemUptime }
        )
        let outcome = HandoffTool.run(request, deps, deadline: deadline)
        focus.close()
        return .text(outcome.reply(), isError: outcome.kind == .failed)
    }
}
