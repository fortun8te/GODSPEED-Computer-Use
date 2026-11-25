import Foundation

/// Level 3, "handoff": the main model gives GODSPEED a bounded subtask and it runs alone, coming back only
/// when the goal is done, it is stuck, or it is unsure. Every action uses a background call
/// bound to the window it was selected from.
///
/// Loop: resolve exact actions first, then try a verified recipe or ask the local helper to rank
/// up to 12 relevant actions. Check `done_when` after every action.
/// It stops on done, on locally observed stalls or navigation cycles, on two failed steps,
/// on a risky control (Delete, Send, Buy, Pay ...: escalated, never pressed), and on budget.
enum HandoffTool {
    static let name = "handoff"
    static let defaultMaxSteps = 15
    static let maxStepsCap = 30
    static let defaultTimeBudget: TimeInterval = 60
    static let timeBudgetCap: TimeInterval = 300
    static let maxCandidates = 12
    /// The best option must reach this probability and lead the runner-up (another option, or "none") by the margin.
    // Selected on the development fixtures for the stock D1 chooser. Exact
    // rules bypass these thresholds, while ambiguous actions require more evidence.
    static let minProbability = 0.70
    static let minMargin = 0.35
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
        var expectedValues: [String: String] = [:]
        var documentPath: String? = nil
    }

    static func parse(_ arguments: [String: Any]) throws -> Request {
        guard let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else {
            throw ComputerUseError.invalidArguments("handoff needs \"app\"")
        }
        guard let goal = (arguments["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
            throw ComputerUseError.invalidArguments("handoff needs \"goal\" (one bounded subtask)")
        }
        var doneWhen = try DoneCheck.parse(arguments["done_when"])
        guard !doneWhen.contains(where: \.requiresBaseline) else {
            throw ComputerUseError.invalidArguments("Use batch for a change-aware done_when check.")
        }
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
        var expectedValues: [String: String] = [:]
        if let raw = arguments["expected_values"] {
            guard let map = raw as? [String: String],
                  map.keys.allSatisfy({ key in values.filter { sameLabel($0.key, key) }.count == 1 }) else {
                throw ComputerUseError.invalidArguments("expected_values must map fields in values to their current text.")
            }
            expectedValues = map
        }
        var documentPath: String? = nil
        if let raw = arguments["document_path"] {
            guard let path = raw as? String, path.hasPrefix("/"), !expectedValues.isEmpty else {
                throw ComputerUseError.invalidArguments("document_path requires an absolute path and guarded field values.")
            }
            documentPath = path
        }
        if let raw = arguments["line_ending"] {
            guard let ending = raw as? String, ["lf", "crlf"].contains(ending), !expectedValues.isEmpty else {
                throw ComputerUseError.invalidArguments("line_ending must be lf or crlf and requires expected_values.")
            }
            let suffix = ending == "lf" ? "\n" : "\r\n"
            func withEnding(_ text: String) -> String {
                text.utf8.last == 10 || text.utf8.last == 13 ? text : text + suffix
            }
            let guarded = Array(expectedValues.keys)
            expectedValues = expectedValues.mapValues(withEnding)
            values = values.map { field in
                (field.key, guarded.contains { sameLabel($0, field.key) } ? withEnding(field.value) : field.value)
            }
            doneWhen = doneWhen.map { check in
                if case .field(let label, let expected) = check,
                   guarded.contains(where: { sameLabel($0, label) }) {
                    return .field(label: label, equals: withEnding(expected))
                }
                return check
            }
        }
        func number(_ key: String) -> Double? {
            let parsed = (arguments[key] as? NSNumber).map(\.doubleValue) ?? (arguments[key] as? String).flatMap(Double.init)
            guard let parsed, parsed.isFinite else { return nil }
            return parsed
        }
        let steps = Int(min(Double(maxStepsCap), max(1, number("max_steps") ?? Double(defaultMaxSteps))))
        let budget = min(timeBudgetCap, max(5, number("time_budget_s") ?? defaultTimeBudget))
        return Request(app: app, goal: goal, doneWhen: doneWhen, values: values, maxSteps: steps, timeBudget: budget,
                       windowID: try validatedQueryWindowID(arguments["window_id"]), expectedValues: expectedValues, documentPath: documentPath)
    }

    /// Pinned handoffs need positive evidence of the requested window on every observation.
    static func matchesWindow(_ state: String, windowID: UInt32?, process: String? = nil) -> Bool {
        if let process, observedProcess(in: state) != process { return false }
        guard let windowID else { return true }
        return observedWindowID(in: state) == windowID
    }

    /// The bundle identifier and PID are stable across navigation and window-title changes.
    static func observedProcess(in state: String) -> String? {
        guard let header = state.split(separator: "\n").first, header.hasPrefix("App=") else { return nil }
        return String(header)
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
        var writableText = false
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
            var writableText = false
            if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                disabled = rest[..<close].contains("disabled")
                writableText = rest[..<close].contains("w:str")
                rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            writableText = writableText || rest.hasSuffix(" (w:str)")
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
            controls.append(Control(index: index, role: role, label: label, value: value, disabled: disabled, writableText: writableText))
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
        var targetLabel: String? = nil
        var targetRole: String? = nil
        var expectedValue: String? = nil
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
                var proposal = fill(field, value: value)
                // The ranker may suggest a field, but it cannot grant permission to overwrite text or
                // choose between ambiguous/approximate input destinations. Those require the caller.
                let exact = writableField(named: key, controls: controls)
                if exact?.index == field.index, field.value == "",
                   values.filter({ sameLabel($0.key, key) }).count == 1 {
                    proposal.expectedValue = ""
                } else {
                    proposal = Candidate(id: proposal.id, kind: proposal.kind, text: proposal.text,
                                         tool: proposal.tool, arguments: proposal.arguments, risky: true,
                                         key: proposal.key, targetLabel: proposal.targetLabel, targetRole: proposal.targetRole)
                }
                add(proposal, score: score)
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
                      arguments: item.arguments, risky: item.risky, key: item.key,
                      targetLabel: item.targetLabel, targetRole: item.targetRole, expectedValue: item.expectedValue)
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
                         key: "click|\(control.role)|\(control.label)" + (unique ? "" : "|\(control.index)"),
                         targetLabel: unique ? control.label : nil, targetRole: control.role)
    }

    private static func fill(_ field: Control, value: String) -> Candidate {
        let name = field.label.isEmpty || field.role == "text entry area" ? field.role : field.label
        return Candidate(id: "", kind: .setValue, text: "fill \"\(name)\"", tool: "set_value",
                         arguments: ["element_index": String(field.index), "value": value],
                         risky: isRisky(label: field.label) || isRisky(label: field.role), key: "set|\(value)|\(field.index)",
                         targetLabel: field.label.isEmpty ? nil : field.label, targetRole: field.role)
    }

    private static func writableField(named label: String, controls: [Control]) -> Control? {
        guard !RecipeLocator.looksSecret(label), !isRisky(label: label) else { return nil }
        let matches = controls.filter {
            (fieldRoles.contains($0.role) || $0.role == "secure text field") && sameLabel($0.label, label)
        }
        guard matches.count == 1, let field = matches.first, !field.disabled else { return nil }
        let supportedRole = field.role == "text field"
            || (field.writableText && ["search text field", "text area", "text entry area"].contains(field.role))
        return supportedRole ? field : nil
    }

    /// A deterministic write requires a unique field and an exact completion check.
    static func exactFieldFill(request: Request, controls: [Control], tried: Set<String>) -> Candidate? {
        for (label, value) in request.values where !value.isEmpty && !RecipeLocator.looksSecret(label) && !isRisky(label: label) {
            let checks = request.doneWhen.compactMap { condition -> String? in
                guard case .field(let field, let expected) = condition, sameLabel(field, label) else { return nil }
                return expected
            }
            guard checks == [value], request.values.filter({ sameLabel($0.key, label) }).count == 1 else { continue }
            guard let field = writableField(named: label, controls: controls) else { continue }
            let expected = request.expectedValues.filter { sameLabel($0.key, label) }
            guard expected.count <= 1, field.value == (expected.first?.value ?? ""),
                  field.value != value else { continue }
            var candidate = fill(field, value: value)
            // Even an initially empty field must still be empty at dispatch.
            candidate.expectedValue = expected.first?.value ?? ""
            if !tried.contains(candidate.key) { return candidate }
        }
        return nil
    }

    private static func explicitClickLabel(_ goal: String) -> String? {
        guard goal.lowercased().hasPrefix("click ") else { return nil }
        let label = String(goal.dropFirst("click ".count)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    static func isTypedForm(_ request: Request) -> Bool {
        !request.values.isEmpty && explicitClickLabel(request.goal) != nil
    }

    static func exactAction(request: Request, controls: [Control], tried: Set<String>) -> Candidate? {
        if !isTypedForm(request), let fill = exactFieldFill(request: request, controls: controls, tried: tried) { return fill }
        // A whole "click <label>" instruction plus explicit values is a typed form workflow.
        // Preflight every field on the same observation, fill only uniquely named empty/guarded
        // fields, then click only after every value has been read back as requested.
        guard !request.doneWhen.isEmpty, let label = explicitClickLabel(request.goal) else { return nil }
        let matches = controls.filter { clickRoles.contains($0.role) && sameLabel($0.label, label) }
        guard matches.count == 1, let control = matches.first, !control.disabled,
              !RecipeLocator.looksSecret(control.label) else { return nil }
        let candidate = click(control, unique: true)
        guard !candidate.risky, !tried.contains(candidate.key) else { return nil }
        var pending: [Candidate] = []
        for (key, desired) in request.values {
            guard !desired.isEmpty, request.values.filter({ sameLabel($0.key, key) }).count == 1,
                  let field = writableField(named: key, controls: controls), let actual = field.value else { return nil }
            if actual == desired { continue }
            let expected = request.expectedValues.filter { sameLabel($0.key, key) }
            guard expected.count <= 1, actual == (expected.first?.value ?? "") else { return nil }
            var write = fill(field, value: desired)
            write.expectedValue = actual
            guard !tried.contains(write.key) else { return nil }
            pending.append(write)
        }
        return pending.first ?? candidate
    }

    /// All checks must hold after the action, and at least one must have become true.
    /// A field that was already correct must not invalidate a verified multi-field fill.
    static func becameTrue(_ conditions: [DoneCheck.Condition], before: String, after: String) -> Bool {
        guard !conditions.isEmpty,
              case .missing = check(conditions, screen: before),
              case .weak = check(conditions, screen: after) else { return false }
        return true
    }

    static func check(_ conditions: [DoneCheck.Condition], screen: String,
                      parsedControls: [Control]? = nil, observedFields: [DoneCheck.Field]? = nil) -> DoneCheck.Result {
        let evidence = DoneCheck.Evidence(screenText: screen, pageURL: { nil })
        var controls = parsedControls
        var unmet: [String] = []
        for condition in conditions {
            if case .field(let label, let expected) = condition {
                if sameLabel(label, "Edit field"), let display = BatchTool.calculatorDisplay(screen) {
                    if display.input != expected { unmet.append(condition.summary) }
                    continue
                }
                if observedFields == nil, controls == nil { controls = parseControls(screen) }
                let fields = observedFields ?? (controls ?? []).compactMap(DoneCheck.nativeField)
                if !DoneCheck.supportsAbsenceCheck(screen) || DoneCheck.uniqueFieldValue(fields, label: label) != expected {
                    unmet.append(condition.summary)
                }
            } else if case .missing(let reasons) = DoneCheck.check([condition], evidence: evidence) {
                unmet.append(contentsOf: reasons)
            }
        }
        return unmet.isEmpty ? .weak(met: conditions.map(\.summary)) : .missing(unmet: unmet)
    }

    /// Acts only on a clear winner: probability at least `minProbability`, a lead of at least `minMargin` over
    /// the runner-up (any other option or "none"), and not a risky control. Anything else is the model's call.
    static func needsVisualTieBreak(_ scores: [String: Double], optionIDs: [String]) -> Bool {
        guard scores.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        let ranked = optionIDs.compactMap { scores[$0] }.sorted(by: >)
        guard let best = ranked.first else { return false }
        let none = scores["none"] ?? 0
        // A clear abstention is already a usable answer. Another image/model call must not
        // turn an explicit rejection into pressure to choose one of the same targets.
        if none >= minProbability, none - best >= minMargin { return false }
        let runnerUp = max(ranked.dropFirst().first ?? 0, none)
        return best < minProbability || best - runnerUp < minMargin
    }

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
        guard let receipt = result.batchReceipt else { return .uncertain }
        if receipt.totalSteps == 0, receipt.doneCheck == .weakEvidence, let note = result.primaryText {
            return .alreadySatisfied(note)
        }
        if receipt.stop == .windowChanged || receipt.stop == .recipeVerification
            || receipt.failureCode == .windowChanged || receipt.failureCode == .staleRef {
            return .blocked("The saved target could not be confirmed. Read the intended window before continuing.")
        }
        return receipt.steps.allSatisfy { $0.deliveryState == .notSent } ? .incomplete : .uncertain
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: Runner

    struct ActResult {
        let ok: Bool
        let message: String
        var delivery: DeliveryState? = nil
        var observedState: String? = nil
        var refused = false
    }

    struct Outcome {
        /// `notVerified`: the goal was already on screen as weak evidence. Nothing ran; the caller decides.
        enum Kind { case done, notVerified, stuck, escalate, budget, failed, cancelled }
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
        var deliveryState: DeliveryState = .notSent
        /// The window the handoff started in (see LearningWindow). Learning rows only; nothing replies with it.
        var window: LearningWindow?
        var ruleActions = 0
        var modelActions = 0
        var chooserCalls = 0
        var verifiedRecipe = false

        /// One outcome line, the steps taken, the net change and, when it needs the model, the top options.
        func reply(compact: Bool = false) -> String {
            if compact, kind == .done, deliveryState == .verified {
                return "Done: \(reason)\nVerified after \(steps.count) local step(s)."
            }
            var lines: [String] = []
            switch kind {
            case .done:
                lines.append(deliveryState == .verified ? "Done: \(reason)" : "Weak evidence: \(reason)")
            case .notVerified: lines.append("Not verified: \(reason)")
            case .stuck: lines.append("Stuck: \(reason)")
            case .escalate: lines.append("Needs you: \(reason)")
            case .budget: lines.append("Stopped: \(reason)")
            case .failed: lines.append("Failed: \(reason)")
            case .cancelled: lines.append("Stopped: \(reason)")
            }
            if steps.isEmpty {
                lines.append("Steps: none")
            } else {
                let shown = steps.count > 10 && kind != .cancelled ? ["..."] + steps.suffix(10) : steps
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

    struct DecisionView {
        let state: String
        let text: String
        var thin: Bool? = nil
    }

    /// Everything the loop touches outside itself, so tests can run it with fakes.
    struct Dependencies {
        var readState: () -> String?
        /// Runs one candidate in the window it was selected from.
        var act: (Candidate, _ state: String) -> ActResult
        var choose: (_ goal: String, _ doneWhen: String, _ history: String, _ screen: DecisionView, _ options: [(id: String, text: String)]) -> [String: Double]?
        var check: (_ state: String) -> DoneCheck.Result
        /// Replay is based on this handoff's original window.
        var replay: (String) -> Replay?
        var now: () -> TimeInterval
        var allowsModelChoices = true
        var controls: (String) -> [Control] = HandoffTool.parseControls
        /// After an acknowledged action with unchanged readback, observe briefly before
        /// offering another action. This hook is read-only and never asks a model.
        var settleState: ((_ previous: String) -> String?)? = nil
    }

    /// A delayed UI response must not lead straight to another click. Poll only while
    /// unchanged, at most three times, with bounded backoff inside the request deadline.
    /// No action is retried, including when delivery was uncertain.
    static func settledState(after previous: String, deadline: TimeInterval,
                             now: () -> TimeInterval, pause: (TimeInterval) -> Void,
                             read: () -> String?) -> String? {
        var latest = previous
        for delay in [TimeInterval(0.1), 0.2, 0.4] {
            guard !RequestCancellation.requested else { return nil }
            let remaining = deadline - now()
            guard remaining > delay else { return latest }
            pause(delay)
            guard !RequestCancellation.requested else { return nil }
            guard now() < deadline else { return latest }
            guard let fresh = read() else { return nil }
            latest = fresh
            if !AXStateDiff.sameContent(previous: previous, current: fresh) { break }
        }
        return latest
    }

    enum Replay: Equatable { case verified, incomplete, uncertain, blocked(String), alreadySatisfied(String), cancelled(String, DeliveryState) }

    /// Runs the handoff and writes one `episode` row with its final outcome (see LearningLog). The row is written
    /// after the outcome is known and cannot change it.
    static func run(_ request: Request, _ deps: Dependencies, deadline: TimeInterval? = nil,
                    learning: LearningLog = .shared) -> Outcome {
        return LearningLog.$episodeID.withValue(learning.isEnabled ? UUID().uuidString : nil) {
            let supplied = (request.values.map { $0.value } + Array(request.expectedValues.values)).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            return LearningLog.$suppliedValues.withValue(supplied) {
                let outcome = runLoop(request, deps, deadline: deadline, learning: learning)
                learnEpisode(request: request, outcome: outcome, log: learning)
                return outcome
            }
        }
    }

    /// One row per handoff: goal, app and the outcome kind. "done" is split by the check that passed.
    static func learnEpisode(request: Request, outcome: Outcome, log: LearningLog) {
        guard log.isEnabled else { return }
        let kind: String
        switch outcome.kind {
        case .done: kind = outcome.deliveryState == .verified ? "verified" : "weak"
        case .notVerified: kind = "not_verified"  // weak evidence only; never a training "done"
        case .stuck: kind = "stuck"
        case .escalate: kind = "escalate"
        case .budget: kind = "budget"
        case .failed: kind = "failed"
        case .cancelled: kind = "cancelled"
        }
        // The done result uses the same labels as a batch: verified, weak or unmet. Only "done" is ever verified.
        let done: String
        switch outcome.kind {
        case .done: done = outcome.deliveryState == .verified ? "verified" : "weak"
        case .notVerified: done = "weak"
        default: done = "unmet"
        }
        let suppliedValues = request.values.map { $0.value }.filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        let safeGoal = suppliedValues.reduce(request.goal) { goal, value in
            goal.replacingOccurrences(of: value, with: LearningScrubber.redacted)
        }
        let checks = LearningDoneWhen.rows(request.doneWhen)?.map { condition in
            condition.mapValues { value in
                suppliedValues.contains(where: { value.contains($0) })
                    ? LearningScrubber.redacted : value
            }
        }
        log.append(LearningEpisodeRow(app: request.app, goal: safeGoal, outcome: kind,
                                      done_when: checks, done: done, window: outcome.window))
    }

    /// One `step` row per action the handoff ran, from the action's own result. Typed values are never written.
    static func learnStep(app: String, choice: Candidate, result: ActResult, log: LearningLog, window: LearningWindow? = nil) {
        guard log.isEnabled else { return }
        let failure = result.ok ? nil : (result.refused ? "refused" : "failed")
        log.append(LearningStepRow(
            app: app, tool: choice.tool, target_role: choice.targetRole, target_label: choice.targetLabel,
            delivery_state: result.delivery?.rawValue, failure_code: failure, window: window
        ))
    }

    private static func runLoop(_ request: Request, _ deps: Dependencies, deadline: TimeInterval?,
                                learning: LearningLog) -> Outcome {
        let deadline = deadline ?? deps.now() + request.timeBudget
        func hasTime() -> Bool { deps.now() < deadline }
        let typedForm = isTypedForm(request)
        let explicitClick = explicitClickLabel(request.goal) != nil
        var targetWindow = request.windowID
        var targetProcess: String?
        func readState() -> String? {
            guard !RequestCancellation.requested, hasTime(),
                  let state = deps.readState(), matchesWindow(state, windowID: targetWindow, process: targetProcess) else { return nil }
            // Pin every workflow, not just forms. The user may select another window while
            // a local chooser runs; its contents must never become this handoff's next target.
            if targetWindow == nil { targetWindow = observedWindowID(in: state) }
            if targetProcess == nil { targetProcess = observedProcess(in: state) }
            return state
        }
        var steps: [String] = []
        var ruleActions = 0
        var modelActions = 0
        var chooserCalls = 0
        var verifiedRecipe = false
        var tried = Set<String>()
        var typedAny = false
        var scrolls = 0
        var noChange = 0
        var failures = 0
        let doneSummary = request.doneWhen.map(\.summary).joined(separator: "; ")
        let needsFreshFields = typedForm || request.doneWhen.contains { condition in
            if case .field = condition { return true }
            return false
        }
        var lastUnmet: [String] = []
        var deliveryState: DeliveryState = .notSent
        // A weak match (present in the state, no proof it changed) never completes the handoff by itself.
        var weakMatch: [String]?
        var initialHadMissing = false
        /// `start` is the state the handoff began from: a weak match that was false there and is true now is verified.
        func matched(_ state: String, since start: String? = nil) -> [String]? {
            weakMatch = nil
            switch deps.check(state) {
            case .verified(let met):
                lastUnmet = []
                return met
            case .weak(let met):
                lastUnmet = []
                if let start {
                    let changed = request.expectedValues.isEmpty
                        ? HandoffTool.becameTrue(request.doneWhen, before: start, after: state)
                        : initialHadMissing
                    if changed { return met }
                }
                weakMatch = met
                return nil
            case .missing(let unmet):
                lastUnmet = unmet
                return nil
            }
        }

        func finish(_ kind: Outcome.Kind, _ reason: String, initial: String?, latest: String?,
                    options: [(text: String, probability: Double)] = []) -> Outcome {
            var changes: String?
            let compact = LeanOutput.usesCompactReads
            if !(compact && kind == .done && deliveryState == .verified),
               let initial, let latest, !steps.isEmpty {
                changes = AXStateDiff.diff(previous: initial, current: latest).map { String($0.prefix(changeLimit)) }
                    ?? "the screen changed a lot"
                if changes == AXStateDiff.noChangesMessage { changes = "the screen did not change" }
            }
            let recoveryScreen: String
            if kind == .done || latest == nil {
                recoveryScreen = ""
            } else if let latest, compact {
                recoveryScreen = RefereeView.build(
                    state: latest, goal: request.goal, doneWhen: lastUnmet.isEmpty ? doneSummary : lastUnmet.joined(separator: "; "),
                    limit: 1_200
                )
            } else {
                recoveryScreen = latest.map { RefereeSummary.screen(from: $0) } ?? ""
            }
            return Outcome(kind: kind, reason: reason, steps: steps, changes: changes, options: options,
                           screen: recoveryScreen, unmet: lastUnmet, deliveryState: deliveryState,
                           window: LearningWindow(state: initial), ruleActions: ruleActions,
                           modelActions: modelActions, chooserCalls: chooserCalls, verifiedRecipe: verifiedRecipe)
        }

        func cancelled() -> Outcome {
            finish(.cancelled, "request cancelled. Inspect any in-flight action before retrying.", initial: nil, latest: nil)
        }
        guard !RequestCancellation.requested else { return cancelled() }
        guard hasTime() else {
            return finish(.budget, "the time budget elapsed before any action was sent", initial: nil, latest: nil)
        }
        guard var state = readState() else {
            if RequestCancellation.requested { return cancelled() }
            let target = request.windowID.map { "\(request.app) window \($0)" } ?? request.app
            return finish(.failed, "could not read \(target)", initial: nil, latest: nil)
        }
        var initial = state
        var recentStates = [state]
        var cycleReturns = 0
        // Already true: nothing to do, and no saved recipe may run (it could undo or repeat the work).
        if let met = matched(state) {
            return Outcome(kind: .done, reason: "already true (\(met.joined(separator: "; ")))", steps: [], changes: nil, options: [])
        }
        if let weak = weakMatch {
            return finish(.notVerified, "already satisfied (weak evidence: \(weak.joined(separator: "; ")))", initial: initial, latest: state)
        }

        guard hasTime() else {
            return finish(.budget, "the time budget elapsed before any action was sent", initial: initial, latest: state)
        }
        if RequestCancellation.requested { return cancelled() }
        initialHadMissing = true
        var initialControls = deps.controls(state)
        for (label, expected) in request.expectedValues {
            let desired = request.values.filter { sameLabel($0.key, label) }
            guard request.expectedValues.keys.filter({ sameLabel($0, label) }).count == 1,
                  desired.count == 1, let value = desired.first?.value,
                  let field = writableField(named: label, controls: initialControls),
                  let actual = field.value else {
                return finish(.escalate, "a guarded field could not be located or read before editing", initial: initial, latest: state)
            }
            if actual != expected && actual != value {
                let reason: String
                if actual == expected + "\n" {
                    reason = "the guarded field has a trailing newline missing from expected_values. Include a newline in the exact current value, and preserve it in values and done_when if the task requires it"
                } else if expected == actual + "\n" {
                    reason = "expected_values includes a trailing newline that the guarded field does not contain"
                } else {
                    reason = "a guarded field changed before editing"
                }
                return finish(.escalate, reason, initial: initial, latest: state)
            }
        }
        var initialExact = exactAction(request: request, controls: initialControls, tried: tried)
        if initialExact == nil, explicitClick {
            return finish(.escalate, "the exact click target or supplied fields could not be confirmed; no action was sent",
                          initial: initial, latest: state)
        }
        if initialExact == nil, request.expectedValues.isEmpty, request.windowID == nil, let replayed = deps.replay(state) {
            if case .cancelled(let receipt, let delivery) = replayed {
                steps.append(receipt)
                deliveryState = delivery
                return cancelled()
            }
            if case .blocked(let reason) = replayed { return finish(.escalate, reason, initial: initial, latest: state) }
            if case .alreadySatisfied(let evidence) = replayed {
                return finish(.notVerified, evidence, initial: initial, latest: state)
            }
            steps.append("replayed the saved recipe")
            if replayed == .verified {
                verifiedRecipe = true
                deliveryState = .verified
                return finish(.done, "\(doneSummary) (saved recipe)", initial: initial, latest: state)
            }
            if replayed == .uncertain { deliveryState = .outcomeUnknown }
            guard hasTime() else {
                return finish(.budget, "the recipe may have partially run. Inspect its result before continuing.", initial: initial, latest: nil)
            }
            // The replay moved the screen; plan from what is there now.
            guard let fresh = readState() else {
                return finish(.failed, "the saved recipe may have partially run; the app could not be read afterward", initial: initial, latest: nil)
            }
            state = fresh
            if replayed == .uncertain {
                return finish(.escalate, "the saved recipe may have partially run. Inspect its result before continuing.", initial: initial, latest: state)
            }
            if let met = matched(state, since: initial) {
                return finish(.done, met.joined(separator: ", "), initial: initial, latest: state)
            }
            steps[steps.count - 1] = "the saved recipe did not finish; continued by hand"
            initial = fresh
            recentStates = [fresh]
            cycleReturns = 0
            if case .missing = deps.check(fresh) { initialHadMissing = true } else { initialHadMissing = false }
            initialControls = deps.controls(fresh)
            initialExact = exactAction(request: request, controls: initialControls, tried: tried)
        }

        for number in 1...request.maxSteps {
            if RequestCancellation.requested { return cancelled() }
            if !hasTime() {
                return finish(.budget, "\(Int(request.timeBudget)) seconds used", initial: initial, latest: state)
            }
            let controls = number == 1 ? initialControls : deps.controls(state)
            let exact = number == 1 ? initialExact : exactAction(request: request, controls: controls, tried: tried)
            if exact == nil, explicitClick {
                return finish(.escalate, "the requested click was already attempted or its target changed; inspect before continuing",
                              initial: initial, latest: state)
            }
            if exact == nil, !request.expectedValues.isEmpty {
                return finish(.escalate, "a field did not match its expected current value or could not be verified", initial: initial, latest: state)
            }
            let options = exact == nil ? candidates(
                goal: request.goal, doneSummary: doneSummary, values: request.values,
                controls: controls, tried: tried, typedAny: typedAny, scrollsDone: scrolls
            ) : []
            var probabilities: [String: Double]?
            var decisionID: String?
            var outcome = LearningChoiceOutcomeRow(disposition: "not_dispatched")
            defer {
                if let decisionID {
                    LearningLog.$decisionID.withValue(decisionID) { _ = learning.append(outcome) }
                }
            }
            let decision: Decision
            if let exact {
                decision = .act(exact, probability: 1)
            } else if !options.isEmpty, options.allSatisfy(\.risky) {
                decision = .escalate("the only available actions are risky")
            } else {
                if !options.isEmpty, deps.allowsModelChoices {
                    let history = steps.suffix(4).joined(separator: "\n")
                    let targets = options.compactMap { Int($0.arguments["element_index"] as? String ?? "") }
                    let view = RefereeView.prepare(state: state, goal: request.goal, doneWhen: doneSummary,
                                                 optionIndexes: targets, limit: Referee.maxViewCharacters)
                    chooserCalls += 1
                    decisionID = learning.isEnabled ? UUID().uuidString.lowercased() : nil
                    probabilities = LearningLog.$decisionID.withValue(decisionID) {
                        deps.choose(request.goal, doneSummary, history, DecisionView(state: state, text: view.text, thin: view.thin),
                                    options.map { ($0.id, $0.text) })
                    }
                }
                decision = decide(candidates: options, probabilities: probabilities)
            }
            if RequestCancellation.requested { return cancelled() }
            switch decision {
            case .escalate(let reason):
                outcome = LearningChoiceOutcomeRow(disposition: "escalated")
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
                if exact == nil { modelActions += 1 } else { ruleActions += 1 }
                let result = deps.act(choice, state)
                let stepDelivery = result.delivery ?? (result.ok ? .acknowledged : .outcomeUnknown)
                outcome = LearningChoiceOutcomeRow(disposition: result.refused ? "refused" : "attempted",
                                                   selected_option_id: choice.id, delivery_state: stepDelivery.rawValue,
                                                   readback: "unobserved")
                LearningLog.$decisionID.withValue(decisionID) {
                    learnStep(app: request.app, choice: choice, result: result, log: learning, window: LearningWindow(state: initial))
                }
                if result.refused {
                    return finish(.failed, result.message, initial: initial, latest: state)
                }
                if stepDelivery != .notSent {
                    deliveryState = stepDelivery == .outcomeUnknown ? .outcomeUnknown : .acknowledged
                }
                if RequestCancellation.requested {
                    steps.append("\(choice.text) (\(stepDelivery.rawValue))")
                    return cancelled()
                }
                if choice.kind == .setValue { typedAny = true }
                if choice.kind == .scroll { scrolls += 1 }
                // A piggyback text snapshot cannot bind typed field observations. Require
                // scoped readback before comparing fields, even when its text is identical.
                let actionState = needsFreshFields ? nil : result.observedState.flatMap {
                    matchesWindow($0, windowID: targetWindow, process: targetProcess) ? $0 : nil
                }
                if !hasTime(), needsFreshFields || result.observedState == nil {
                    steps.append(result.ok ? choice.text : "\(choice.text) failed")
                    return finish(.budget, "the last action may have run. Inspect its result before continuing.", initial: initial, latest: nil)
                }
                guard result.ok, stepDelivery != .outcomeUnknown else {
                    steps.append("\(choice.text) failed")
                    if stepDelivery != .notSent {
                        let observed = readState()
                        if let observed {
                            outcome.readback = AXStateDiff.sameContent(previous: state, current: observed)
                                ? "unchanged" : "changed"
                        }
                        return finish(.escalate, DeliveryState.reconcileHint, initial: initial, latest: observed)
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
                guard var next = actionState ?? readState() else {
                    if RequestCancellation.requested { return cancelled() }
                    return finish(.failed, "lost sight of \(request.app) after \(choice.text)", initial: initial, latest: state)
                }
                if let met = matched(next, since: initial) {
                    outcome.readback = "goal_verified"
                    deliveryState = .verified
                    return finish(.done, met.joined(separator: "; "), initial: initial, latest: next)
                }
                if AXStateDiff.sameContent(previous: state, current: next), hasTime(), let settle = deps.settleState {
                    guard let settled = settle(next), matchesWindow(settled, windowID: targetWindow, process: targetProcess) else {
                        if RequestCancellation.requested { return cancelled() }
                        return finish(.failed, "lost sight of the original window while waiting for the last action",
                                      initial: initial, latest: nil)
                    }
                    if RequestCancellation.requested { return cancelled() }
                    next = settled
                    if let met = matched(next, since: initial) {
                        outcome.readback = "goal_verified"
                        deliveryState = .verified
                        return finish(.done, met.joined(separator: "; "), initial: initial, latest: next)
                    }
                }
                let unchanged = AXStateDiff.sameContent(previous: state, current: next)
                outcome.readback = unchanged ? "unchanged" : "changed"
                noChange = unchanged ? noChange + 1 : 0
                state = next
                // Repeated navigation cycles can keep changing the tree without progressing.
                // Require two non-consecutive returns so a single legitimate round trip is allowed.
                if !unchanged {
                    let revisited = recentStates.contains { AXStateDiff.sameContent(previous: $0, current: next) }
                    cycleReturns = revisited ? cycleReturns + 1 : 0
                    recentStates.append(next)
                    if recentStates.count > 8 { recentStates.removeFirst() }
                    if cycleReturns >= 2 {
                        ToolTelemetry.current?.add("handoff_cycle_stops")
                        return finish(.stuck, "the workflow returned to previously observed states without satisfying the goal",
                                      initial: initial, latest: state)
                    }
                }
                if noChange >= 2 {
                    return finish(.stuck, "the last two actions changed nothing on screen", initial: initial, latest: state)
                }
            }
        }
        if RequestCancellation.requested { return cancelled() }
        return finish(.budget, "\(request.maxSteps) steps used", initial: initial, latest: state)
    }
}

// MARK: - Dispatcher glue

extension ComputerUseToolDispatcher {
    /// The `handoff` tool uses a window-bound background call for every mutation.
    func runHandoff(arguments: [String: Any], readFixtureState: (() -> String?)? = nil) throws -> ToolCallResult {
        let request = try HandoffTool.parse(arguments)
        guard request.app.lowercased() != "browser" else {
            throw ComputerUseError.invalidArguments("Handoff ranks native Mac actions. For websites, use browser read and a batch with an observable done_when.")
        }
        let app = request.app
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + min(request.timeBudget, BrowserCallBudget.activeRemaining ?? .infinity)
        var refusal: ToolCallResult?
        func captureRefusal(_ result: ToolCallResult) -> Bool {
            guard (result.batchReceipt?.failureCode ?? result.failureCode)?.isActionRefusal == true else { return false }
            refusal = result
            return true
        }

        func matchesDocument(_ windowID: UInt32) -> Bool {
            guard let path = request.documentPath else { return true }
            return service.handoffMatchesDocument(app: app, windowID: windowID, path: path)
        }

        func controlsFor(_ state: String) -> [HandoffTool.Control] {
            let parsed = HandoffTool.parseControls(state)
            guard readFixtureState == nil, !request.values.isEmpty,
                  let windowID = HandoffTool.observedWindowID(in: state) else { return parsed }
            // Bind typed field candidates to the real AX value, not the display line's formatting.
            return service.handoffTextControls(app: app, windowID: windowID,
                                               labels: request.values.map(\.key), parsed: parsed)
        }

        var fieldObservation: (state: String, fields: [DoneCheck.Field])?
        var targetWindow = request.windowID
        var targetProcess: String?
        func captureState(settleMs: Int) -> String? {
            if let readFixtureState {
                guard let state = readFixtureState(), HandoffTool.matchesWindow(state, windowID: targetWindow, process: targetProcess) else { return nil }
                if targetWindow == nil { targetWindow = HandoffTool.observedWindowID(in: state) }
                if targetProcess == nil { targetProcess = HandoffTool.observedProcess(in: state) }
                return state
            }
            let remaining = max(0, deadline - clock.systemUptime)
            guard remaining > 0, !RequestCancellation.requested else { return nil }
            var args: [String: Any] = ["app": app, "include_screenshot": false, "compact": false,
                                       "settle_ms": min(settleMs, Int(remaining * 1_000))]
            args["window_id"] = targetWindow
            let read = BrowserCallBudget.withDeadline(deadline) {
                callToolAsResult(name: "get_app_state", arguments: args)
            }
            guard !captureRefusal(read), !read.isError else { return nil }
            guard let state = LeanOutput.stateText(of: read),
                  let id = HandoffTool.observedWindowID(in: state), matchesDocument(id),
                  HandoffTool.matchesWindow(state, windowID: targetWindow, process: targetProcess) else { return nil }
            if targetWindow == nil { targetWindow = id }
            if targetProcess == nil { targetProcess = HandoffTool.observedProcess(in: state) }
            let text = BatchTool.stateText(ofText: state)
            fieldObservation = (text, read.observedFields ?? [])
            return text
        }
        let deps = HandoffTool.Dependencies(
            readState: { captureState(settleMs: LeanDefaults.batchSettleMs) },
            act: { [self] candidate, state in
                guard let window = request.windowID ?? HandoffTool.observedWindowID(in: state) else {
                    return HandoffTool.ActResult(ok: false, message: "the target window could not be confirmed", delivery: .notSent)
                }
                guard matchesDocument(window) else {
                    return HandoffTool.ActResult(ok: false, message: "the observed window does not show the requested document path",
                                                delivery: .notSent, refused: true)
                }
                var args = candidate.arguments
                args["app"] = app
                args["window_id"] = window
                if candidate.kind == .click { args["click_method"] = "accessibility" }
                let result = BrowserCallBudget.withDeadline(deadline) {
                    ComputerUseService.$expectedSetValue.withValue(candidate.expectedValue) {
                        callStepAsResult(name: candidate.tool, arguments: args, log: SmartLog(), notesInResult: false)
                    }
                }
                if captureRefusal(result) {
                    return HandoffTool.ActResult(ok: false, message: BatchTool.firstLine(result.textContent),
                                                delivery: .notSent, refused: true)
                }
                let state = !result.isError && candidate.kind != .pressReturn ? LeanOutput.stateText(of: result) : nil
                return HandoffTool.ActResult(
                    ok: !result.isError, message: BatchTool.firstLine(result.textContent),
                    delivery: result.deliveryState,
                    observedState: state.flatMap { text in
                        text.contains(SnapshotObservationOptions.accessibilityOmittedNote) ? nil : text
                    }
                )
            },
            choose: { [self] goal, doneWhen, history, screen, options in
                guard let helper = Referee.handoffURL else { return nil }
                let picture = Referee.picture(url: helper, state: screen.state, remaining: deadline - clock.systemUptime, thin: screen.thin) {
                    localDecisionImage(app: app, state: screen.state)
                }
                let scores = Referee.choose(goal: goal, doneWhen: doneWhen, history: history, screen: screen.text,
                                            options: options, imageBase64: picture, remaining: deadline - clock.systemUptime)
                // A reasonably populated tree can still omit the visual cue that distinguishes two controls.
                // Retry once with the same grounded candidates and a fresh, bound window image.
                guard picture == nil, !(screen.thin ?? RefereeView.isThin(screen.state)), let scores,
                      HandoffTool.needsVisualTieBreak(scores, optionIDs: options.map(\.id)),
                      deadline - clock.systemUptime >= 2, !RequestCancellation.requested,
                      let retryPicture = Referee.picture(url: helper, state: screen.state,
                                                         remaining: deadline - clock.systemUptime, allowRichTree: true,
                                                         capture: { localDecisionImage(app: app, state: screen.state) })
                else { return scores }
                return Referee.choose(goal: goal, doneWhen: doneWhen, history: history, screen: screen.text,
                                      options: options, imageBase64: retryPicture, remaining: deadline - clock.systemUptime)
                    ?? scores
            },
            check: { state in
                let fields = fieldObservation.flatMap { $0.state == state ? $0.fields : nil }
                return HandoffTool.check(request.doneWhen, screen: state,
                                         parsedControls: fields == nil ? controlsFor(state) : nil,
                                         observedFields: fields)
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
                switch recipeStore.lookup(app: app, goal: request.goal, values: recipeValues, state: state) {
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
                if captureRefusal(result) { return .uncertain }
                if result.batchReceipt?.stop == .cancelled { return .cancelled(result.textContent, result.deliveryState) }
                return HandoffTool.replayResult(result)
            },
            now: { clock.systemUptime },
            allowsModelChoices: Referee.handoffURL != nil,
            controls: controlsFor,
            settleState: { previous in
                HandoffTool.settledState(after: previous, deadline: deadline, now: { clock.systemUptime },
                                        pause: { Thread.sleep(forTimeInterval: $0) },
                                        read: { captureState(settleMs: 0) })
            }
        )
        let outcome = HandoffTool.run(request, deps, deadline: deadline)
        if let refusal { return refusal }
        return ToolCallResult(
            content: [.text(outcome.reply(compact: LeanOutput.usesCompactReads))],
            isError: outcome.kind == .failed || outcome.kind == .cancelled,
            deliveryState: outcome.deliveryState,
            handoffMetrics: [
                "rules": outcome.ruleActions, "model": outcome.modelActions,
                "chooser": outcome.chooserCalls, "recipe": outcome.verifiedRecipe ? 1 : 0,
                "verified": outcome.kind == .done && outcome.deliveryState == .verified ? 1 : 0,
            ]
        )
    }
}
