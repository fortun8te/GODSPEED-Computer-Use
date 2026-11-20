import Foundation

/// Level 3, "handoff": the main model gives GODSPEED a bounded subtask and it runs alone, coming back only
/// when the goal is done, it is stuck, or it is unsure. Every action uses a background call
/// bound to the window it was selected from.
///
/// Loop: resolve exact actions first, then try a verified recipe or ask the local helper to rank
/// up to 12 relevant actions. Check `done_when` after every action.
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
        var windowID: UInt32? = nil
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
        return Request(app: app, goal: goal, doneWhen: doneWhen, values: values, maxSteps: steps, timeBudget: budget,
                       windowID: try validatedQueryWindowID(arguments["window_id"]))
    }

    /// Pinned handoffs need positive evidence of the requested window on every observation.
    static func matchesWindow(_ state: String, windowID: UInt32?) -> Bool {
        guard let windowID else { return true }
        return observedWindowID(in: state) == windowID
    }

    static func observedWindowID(in state: String) -> UInt32? {
        let header = state.split(separator: "\n").prefix(3)
        guard header.count == 3, header.first?.hasPrefix("App=") == true,
              let line = header.last, line.hasPrefix("Window ID: ") else { return nil }
        return UInt32(line.dropFirst("Window ID: ".count)).flatMap { $0 > 0 ? $0 : nil }
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
        var found: [(candidate: Candidate, score: Double)] = []
        var seen = tried
        func add(_ candidate: Candidate, score: Double) {
            guard seen.insert(candidate.key).inserted else { return }
            found.append((candidate, score))
        }

        // Rank all actions together before applying the shared cap. A fuzzy typing suggestion should
        // not crowd out a click the goal names, or a field named explicitly by the supplied key.
        let fields = controls.filter { fieldRoles.contains($0.role) && !$0.disabled && !RecipeLocator.looksSecret($0.label) }
        for (key, value) in values where !RecipeLocator.looksSecret(key) {
            let keyWords = Set(words(key))
            let named = fields.filter { !keyWords.isDisjoint(with: words($0.label)) }
            let fallback = fields.filter { ($0.value ?? "").isEmpty && ($0.role != "text entry area" || $0.label.isEmpty) }
            for field in named.isEmpty ? Array(fallback.prefix(2)) : named {
                if field.value == value || field.label == value { continue }
                let score: Double = sameLabel(field.label, key) ? 12 : (named.isEmpty ? 0.25 : 1)
                add(fill(field, value: value), score: score)
            }
        }

        let explicitWords = Set(words(goal)).subtracting(stopWords)
        let clickLabel = explicitClickLabel(goal)
        let goalWords = explicitWords.union(words(doneSummary + " " + values.map(\.key).joined(separator: " "))).subtracting(stopWords)
        let labelCounts = Dictionary(grouping: controls) { $0.label.lowercased() }.mapValues(\.count)
        for control in controls where clickRoles.contains(control.role) && !control.disabled && !control.label.isEmpty {
            let risky = isRisky(label: control.label)
            let labelWords = Set(words(control.label)).subtracting(stopWords)
            if risky, labelWords.intersection(riskyWords).isDisjoint(with: explicitWords) { continue }
            let score = relevance(label: control.label, goalWords: goalWords, countingProgressWords: !risky)
            guard score > 0 else { continue }
            let named = !labelWords.isEmpty && labelWords.isSubset(of: explicitWords)
            let priority = clickLabel.map { sameLabel(control.label, $0) } == true ? 16 : (named ? 8 : 0)
            add(click(control, unique: labelCounts[control.label.lowercased()] == 1), score: Double(priority) + min(3, score))
        }

        if typedAny {
            add(Candidate(id: "", kind: .pressReturn, text: "press Return", tool: "press_key",
                          arguments: ["key": "Return"], risky: true, key: "return"), score: 0)
        }
        if scrollsDone < maxScrolls, let area = controls.first(where: { $0.role == "scroll area" && !$0.disabled }) {
            add(Candidate(id: "", kind: .scroll, text: "scroll down", tool: "scroll",
                          arguments: ["direction": "down", "element_index": String(area.index)],
                          risky: false, key: "scroll|\(scrollsDone)"), score: 0)
        }

        let limited = found.enumerated().sorted {
            $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score
        }.prefix(maxCandidates).map { $0.element.candidate }
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

    static func sameLabel(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    private static func click(_ control: Control, unique: Bool) -> Candidate {
        let suffix = unique ? "" : " (#\(control.index))"
        return Candidate(id: "", kind: .click, text: "click \"\(control.label)\"\(suffix)", tool: "click",
                         arguments: ["element_index": String(control.index)], risky: isRisky(label: control.label),
                         key: "click|\(control.role)|\(control.label)" + (unique ? "" : "|\(control.index)"))
    }

    private static func fill(_ field: Control, value: String) -> Candidate {
        let name = field.label.isEmpty || field.role == "text entry area" ? field.role : field.label
        let shown = value.count > 40 ? String(value.prefix(40)) + "..." : value
        return Candidate(id: "", kind: .setValue, text: "type \"\(shown)\" into \"\(name)\"", tool: "set_value",
                         arguments: ["element_index": String(field.index), "value": value],
                         risky: isRisky(label: field.label) || isRisky(label: field.role), key: "set|\(value)|\(field.index)")
    }

    /// A deterministic write requires a unique empty field and an explicit equality check for the value.
    static func exactFieldFill(request: Request, controls: [Control], tried: Set<String>) -> Candidate? {
        for (label, value) in request.values where !value.isEmpty && !RecipeLocator.looksSecret(label) && !isRisky(label: label) {
            let checks = request.doneWhen.compactMap { condition -> String? in
                guard case .field(let field, let expected) = condition, sameLabel(field, label) else { return nil }
                return expected
            }
            guard checks == [value], request.values.filter({ sameLabel($0.key, label) }).count == 1 else { continue }
            let matches = controls.filter { (fieldRoles.contains($0.role) || $0.role == "secure text field") && sameLabel($0.label, label) }
            guard matches.count == 1, let field = matches.first,
                  field.role == "text field", !field.disabled, field.value == "" else { continue }
            let candidate = fill(field, value: value)
            if !tried.contains(candidate.key) { return candidate }
        }
        return nil
    }

    private static func explicitClickLabel(_ goal: String) -> String? {
        guard goal.lowercased().hasPrefix("click ") else { return nil }
        let label = String(goal.dropFirst("click ".count)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    static func exactAction(request: Request, controls: [Control], tried: Set<String>) -> Candidate? {
        if let fill = exactFieldFill(request: request, controls: controls, tried: tried) { return fill }
        // Only the whole "click <label>" instruction permits a deterministic click.
        guard !request.doneWhen.isEmpty, request.values.isEmpty, let label = explicitClickLabel(request.goal) else { return nil }
        let matches = controls.filter { clickRoles.contains($0.role) && sameLabel($0.label, label) }
        guard matches.count == 1, let control = matches.first, !control.disabled,
              !RecipeLocator.looksSecret(control.label) else { return nil }
        let candidate = click(control, unique: true)
        return !candidate.risky && !tried.contains(candidate.key) ? candidate : nil
    }

    static func check(_ conditions: [DoneCheck.Condition], screen: String) -> DoneCheck.Result {
        let evidence = DoneCheck.Evidence(screenText: screen, pageURL: { nil })
        var controls: [Control]?
        var unmet: [String] = []
        for condition in conditions {
            if case .field(let label, let expected) = condition {
                if controls == nil { controls = parseControls(screen) }
                let fields = (controls ?? []).filter { fieldRoles.contains($0.role) && sameLabel($0.label, label) }
                if fields.count != 1 || fields.first?.value != expected { unmet.append(condition.summary) }
            } else if case .missing(let reasons) = DoneCheck.check([condition], evidence: evidence) {
                unmet.append(contentsOf: reasons)
            }
        }
        return unmet.isEmpty ? .verified(met: conditions.map(\.summary)) : .missing(unmet: unmet)
    }

    /// Acts only on a clear winner: probability at least `minProbability`, a lead of at least `minMargin` over
    /// the runner-up (any other option or "none"), and not a risky control. Anything else is the model's call.
    static func decide(candidates: [Candidate], probabilities: [String: Double]?) -> Decision {
        guard !candidates.isEmpty else { return .escalate("no action on screen fits the goal") }
        guard let probabilities else { return .escalate("the checker model is not available, so GODSPEED cannot rank the options") }
        guard probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return .escalate("the checker returned invalid scores")
        }
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

    /// An unattended replay cannot type into an unknown focus, send shortcuts, or operate another app.
    static func isSafeRecipeStep(_ step: BatchTool.Step, app: String) -> Bool {
        if let stepApp = step.arguments["app"] as? String, !BatchRecipes.sameApp(app, stepApp) {
            return false
        }
        guard step.arguments["window_id"] == nil else { return false }
        switch step.tool {
        case "get_app_state", "query":
            return true
        case "wait":
            guard let wait = try? BatchEffects.Wait(arguments: step.arguments) else { return false }
            if case .window = wait.kind { return false }
            return true
        case "click", "set_value":
            let args = ArgumentNormalizer.normalize(tool: step.tool, arguments: step.arguments, lastApp: app)
            guard let label = args["label"] as? String, !label.isEmpty,
                  !isRisky(label: label), !RecipeLocator.looksSecret(label),
                  args["window_id"] == nil,
                  !BatchTool.usesPositionalTargets([.init(tool: step.tool, arguments: args)]) else { return false }
            // Do not send mouse or keyboard fallbacks for a stored label.
            let clickMethod = args["click_method"] as? String
            return step.tool == "set_value" || (
                (clickMethod == nil || clickMethod == "accessibility")
                    && (args["click_count"].map { "\($0)" } ?? "1") == "1"
                    && (args["mouse_button"] as? String ?? "left") == "left"
            )
        default:
            return false
        }
    }

    /// Bind the executable step to fresh evidence from the original window.
    static func bindRecipeStep(_ step: BatchTool.Step, app: String, state: String?) -> BatchTool.Step? {
        guard isSafeRecipeStep(step, app: app), let state, let window = observedWindowID(in: state) else { return nil }
        var args = ArgumentNormalizer.normalize(tool: step.tool, arguments: step.arguments, lastApp: app)
        args["app"] = app
        args["window_id"] = window
        if step.isReadOnly { return BatchTool.Step(tool: step.tool, arguments: args) }
        guard let label = args["label"] as? String else { return nil }
        let roles = step.tool == "set_value" ? fieldRoles : clickRoles
        let matches = parseControls(state).filter { roles.contains($0.role) && sameLabel($0.label, label) }
        guard matches.count == 1, let control = matches.first, !control.disabled else { return nil }
        args["label"] = nil
        args["element_index"] = String(control.index)
        if step.tool == "click" { args["click_method"] = "accessibility" }
        return BatchTool.Step(tool: step.tool, arguments: args)
    }

    /// Verify from the driver's receipt. Display text can include app-controlled content.
    static func batchReportsVerifiedDone(_ result: ToolCallResult) -> Bool {
        !result.isError && result.batchReceipt?.doneCheck == .verified
    }

    static func replayResult(_ result: ToolCallResult) -> Replay {
        if batchReportsVerifiedDone(result) { return .verified }
        guard let receipt = result.batchReceipt,
              receipt.steps.allSatisfy({ $0.observation == .notSent }) else { return .uncertain }
        return .incomplete
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
        /// Runs one candidate in the window it was selected from.
        var act: (Candidate, _ state: String) -> ActResult
        var choose: (_ goal: String, _ doneWhen: String, _ history: String, _ screen: String, _ options: [(id: String, text: String)]) -> [String: Double]?
        /// The checker model's stuck verdict for a short summary.
        var looksStuck: (_ goal: String, _ lastStep: String, _ summary: String) -> Bool
        var check: (_ state: String) -> DoneCheck.Result
        /// Replay is based on this handoff's original window.
        var replay: (String) -> Replay?
        var now: () -> TimeInterval
    }

    enum Replay { case verified, incomplete, uncertain, blocked(String) }

    static func run(_ request: Request, _ deps: Dependencies, deadline: TimeInterval? = nil) -> Outcome {
        let deadline = deadline ?? deps.now() + request.timeBudget
        func hasTime() -> Bool { deps.now() < deadline }
        func readState() -> String? {
            guard hasTime(), let state = deps.readState(), matchesWindow(state, windowID: request.windowID) else { return nil }
            return state
        }
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
        guard var state = readState() else {
            let target = request.windowID.map { "\(request.app) window \($0)" } ?? request.app
            return finish(.failed, "could not read \(target)", initial: nil, latest: nil)
        }
        var initial = state
        // Already true: nothing to do, and no saved recipe may run (it could undo or repeat the work).
        if case .verified(let met) = verdict(state) {
            return Outcome(kind: .done, reason: "already true (\(met.joined(separator: "; ")))", steps: [], changes: nil, options: [])
        }

        guard hasTime() else {
            return finish(.budget, "the time budget elapsed before any action was sent", initial: initial, latest: state)
        }
        var initialControls = parseControls(state)
        var initialExact = exactAction(request: request, controls: initialControls, tried: tried)
        if initialExact == nil, request.windowID == nil, let replayed = deps.replay(state) {
            if case .blocked(let reason) = replayed { return finish(.escalate, reason, initial: initial, latest: state) }
            steps.append("replayed the saved recipe")
            if case .verified = replayed { return Outcome(kind: .done, reason: "\(doneSummary) (saved recipe)", steps: steps, changes: nil, options: []) }
            guard hasTime() else {
                return finish(.budget, "the recipe may have partially run. Inspect its result before continuing.", initial: initial, latest: nil)
            }
            // The replay moved the screen; plan from what is there now.
            guard let fresh = readState() else {
                return finish(.failed, "the saved recipe may have partially run; the app could not be read afterward", initial: initial, latest: nil)
            }
            state = fresh
            if case .verified(let met) = verdict(state) {
                return finish(.done, met.joined(separator: "; "), initial: initial, latest: state)
            }
            if case .uncertain = replayed {
                return finish(.escalate, "the saved recipe may have partially run. Inspect its result before continuing.", initial: initial, latest: state)
            }
            steps[steps.count - 1] = "the saved recipe did not finish; continued by hand"
            initial = fresh
            initialControls = parseControls(fresh)
            initialExact = exactAction(request: request, controls: initialControls, tried: tried)
        }

        for number in 1...request.maxSteps {
            if !hasTime() {
                return finish(.budget, "\(Int(request.timeBudget)) seconds used", initial: initial, latest: state)
            }
            let controls = number == 1 ? initialControls : parseControls(state)
            let exact = number == 1 ? initialExact : exactAction(request: request, controls: controls, tried: tried)
            let options = exact == nil ? candidates(
                goal: request.goal, doneSummary: doneSummary, values: request.values,
                controls: controls, tried: tried, typedAny: typedAny, scrollsDone: scrolls
            ) : []
            var probabilities: [String: Double]?
            let decision: Decision
            if let exact {
                decision = .act(exact, probability: 1)
            } else if !options.isEmpty, options.allSatisfy(\.risky) {
                decision = .escalate("the only available actions are risky")
            } else {
                if !options.isEmpty {
                    let history = steps.suffix(4).joined(separator: "\n")
                    probabilities = deps.choose(request.goal, doneSummary, history, RefereeSummary.screen(from: state),
                                                options.map { ($0.id, $0.text) })
                }
                decision = decide(candidates: options, probabilities: probabilities)
            }
            switch decision {
            case .escalate(let reason):
                let ranked = options.map { option in
                    let score = probabilities?[option.id] ?? 0
                    return (option.text, (0...1).contains(score) ? score : 0)
                }.sorted { $0.1 > $1.1 }
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
                    if result.delivery != .notSent {
                        let fresh = readState()
                        if let fresh, case .verified(let met) = verdict(fresh) {
                            return finish(.done, met.joined(separator: "; "), initial: initial, latest: fresh)
                        }
                        return finish(.escalate, "the last action may have run. Inspect its result before continuing.", initial: initial, latest: fresh)
                    }
                    failures += 1
                    if failures >= 2 {
                        return finish(.stuck, "two actions failed in a row (last: \(choice.text): \(result.message))", initial: initial, latest: state)
                    }
                    guard let fresh = readState() else {
                        return finish(.failed, "could not refresh the app after the failed action", initial: initial, latest: nil)
                    }
                    state = fresh
                    continue
                }
                failures = 0
                steps.append(choice.text)
                let actionState = result.observedState.flatMap { matchesWindow($0, windowID: request.windowID) ? $0 : nil }
                guard let next = actionState ?? readState() else {
                    return finish(.failed, "lost sight of \(request.app) after \(choice.text)", initial: initial, latest: state)
                }
                if case .verified(let met) = verdict(next) {
                    return finish(.done, met.joined(separator: "; "), initial: initial, latest: next)
                }
                let unchanged = AXStateDiff.diff(previous: state, current: next) == AXStateDiff.noChangesMessage
                noChange = unchanged ? noChange + 1 : 0
                state = next
                if noChange >= 2 {
                    return finish(.stuck, "the last two actions changed nothing on screen", initial: initial, latest: state)
                }
                // A changed screen already gives the next step new evidence. Ask the checker
                // only on a stall that the two-action rule has not yet handled.
                if exact == nil, unchanged, number >= 2, number < request.maxSteps,
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
    /// The `handoff` tool uses a window-bound background call for every mutation.
    func runHandoff(arguments: [String: Any]) throws -> ToolCallResult {
        let request = try HandoffTool.parse(arguments)
        guard request.app.lowercased() != "browser" else {
            throw ComputerUseError.invalidArguments("Handoff ranks native Mac actions. For websites, use browser read and a batch with an observable done_when.")
        }
        let app = request.app
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + request.timeBudget

        let deps = HandoffTool.Dependencies(
            readState: { [self] in
                let remaining = max(0, deadline - clock.systemUptime)
                let settleMs = min(LeanDefaults.batchSettleMs, Int(remaining * 1_000))
                var args: [String: Any] = ["app": app, "include_screenshot": false, "settle_ms": settleMs]
                args["window_id"] = request.windowID
                let read = BrowserCallBudget.withDeadline(deadline) {
                    callToolAsResult(name: "get_app_state", arguments: args)
                }
                guard !read.isError else { return nil }
                guard let state = LeanOutput.stateText(of: read), HandoffTool.observedWindowID(in: state) != nil else { return nil }
                return BatchTool.stateText(ofText: state)
            },
            act: { [self] candidate, state in
                guard let window = request.windowID ?? HandoffTool.observedWindowID(in: state) else {
                    return HandoffTool.ActResult(ok: false, message: "the target window could not be confirmed", delivery: .notSent)
                }
                var args = candidate.arguments
                args["app"] = app
                args["window_id"] = window
                if candidate.kind == .click { args["click_method"] = "accessibility" }
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
            check: { state in
                HandoffTool.check(request.doneWhen, screen: state)
            },
            replay: { [self] state in
                // Recipe variables are named after field labels ("Name" -> "name"); the handoff's value keys map to them.
                guard BatchRecipes.isEnabled else { return nil }
                var recipeValues: [String: String] = [:]
                for (key, value) in request.values {
                    let name = BatchRecipes.variableName(label: key)
                    guard recipeValues.updateValue(value, forKey: name) == nil else {
                        return .blocked("More than one value names the same recipe slot. Confirm the inputs.")
                    }
                }
                let recipe: BatchRecipes.Recipe
                switch BatchRecipes.shared.lookup(app: app, goal: request.goal, values: recipeValues, state: state) {
                case .match(let match): recipe = match
                case .blocked(let reason): return .blocked(reason)
                case .missing: return nil
                }
                guard recipe.doneWhen == request.doneWhen else {
                    return .blocked("The recipe's done_when changed. Confirm the check and provide fresh steps.")
                }
                var batchArguments: [String: Any] = ["app": app, "goal": request.goal]
                if !recipeValues.isEmpty { batchArguments["values"] = recipeValues }
                if let doneWhen = arguments["done_when"] { batchArguments["done_when"] = doneWhen }
                guard let result = try? runBatch(arguments: batchArguments, inheritedDeadline: deadline,
                                                 validatedHandoffRecipe: recipe) else { return .uncertain }
                return HandoffTool.replayResult(result)
            },
            now: { clock.systemUptime }
        )
        let outcome = HandoffTool.run(request, deps, deadline: deadline)
        return .text(outcome.reply(), isError: outcome.kind == .failed)
    }
}
