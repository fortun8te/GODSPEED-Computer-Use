import Foundation

/// Window-scoped workflows stored on this Mac. Only verified champions can replay.
final class BatchRecipes: @unchecked Sendable {
    static let shared = BatchRecipes()

    static var isEnabled: Bool {
        let value = RequestConfiguration.environment["OPEN_COMPUTER_USE_RECIPES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }

    static let maxRecipes = 300
    struct Window: Equatable, Codable {
        let process: String
        let titleLine: String
        let id: UInt32

        init?(state: String?) {
            guard let state, let id = HandoffTool.observedWindowID(in: state) else { return nil }
            let header = Array(state.split(separator: "\n").prefix(3))
            guard header[0].contains(" (pid "), header[1].hasPrefix("Window: \""),
                  let title = BatchEffects.windowTitle(in: state), !title.isEmpty else { return nil }
            self.process = String(header[0])
            self.titleLine = String(header[1])
            self.id = id
        }
    }

    struct Recipe {
        let app: String
        let goal: String
        let steps: [Any]
        var uses: Int
        var failures: Int
        var params: [String: String] = [:]
        var slotKinds: [String: SlotKind] = [:]
        var doneWhen: [DoneCheck.Condition] = []
        var window: Window?
        var verified = false
        var version: String?
        var champion = true
    }

    enum Lookup {
        case match(Recipe)
        case blocked(String)
        case missing
    }

    private let lock = NSLock()
    private var recipes: [Recipe] = []
    private let fileURL: URL

    init(fileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".godspeed/recipes.json")) {
        self.fileURL = fileURL
    }

    func lookup(app: String?, goal: String, values: [String: String] = [:], state: String?) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        reload()
        let candidates = recipes.filter { recipe in
            recipe.champion && app.map { Self.sameApp(recipe.app, $0) } != false
        }
        let exact = candidates.filter { $0.goal.utf8.elementsEqual(goal.utf8) }
        if exact.isEmpty {
            // Templates can detect a changed goal, but can never select a recipe to execute.
            let template = Self.templateKey(goal, values: Array(values.values))
            if candidates.contains(where: { Self.templateKey($0.goal, values: Array($0.params.values)) == template }) {
                return .blocked("The saved recipe's goal changed. Confirm the goal and provide fresh steps.")
            }
            return .missing
        }
        guard exact.contains(where: \.verified) else {
            return .blocked("The saved recipe is unverified. Provide fresh steps with a deterministic done_when.")
        }
        let window = Window(state: state)
        let matches = exact.filter { $0.window != nil && $0.window == window }
        guard matches.count == 1, let match = matches.first else {
            return .blocked("The saved recipe needs its original window. Read the current window and provide fresh steps.")
        }
        if let reason = Self.slotProblem(match, values: values) { return .blocked(reason) }
        guard match.verified, match.version != nil, !match.doneWhen.isEmpty else {
            return .blocked("The saved recipe is unverified. Provide fresh steps with a deterministic done_when.")
        }
        return .match(match)
    }

    static func sameApp(_ first: String, _ second: String) -> Bool {
        first.caseInsensitiveCompare(second) == .orderedSame
    }

    /// A new version only becomes champion if there is no verified champion. Keep one challenger.
    @discardableResult
    func save(app: String, goal: String, steps: [Any], params: [String: String] = [:],
              slotKinds: [String: SlotKind] = [:], doneWhen: [DoneCheck.Condition] = [],
              window: Window? = nil, verified: Bool = false) -> Recipe? {
        guard let encoded = Self.encodedSteps(steps) else { return nil }
        var saved: Recipe?
        let persisted = mutate {
            var candidate = Recipe(app: app, goal: goal, steps: steps, uses: 0, failures: 0, params: params,
                                   slotKinds: slotKinds, doneWhen: doneWhen, window: window,
                                   version: UUID().uuidString)
            candidate.verified = verified && window != nil && !doneWhen.isEmpty
                && (try? Self.boundSteps(candidate, values: params)) != nil
            if let champion = recipes.first(where: { Self.sameGroup($0, candidate) && $0.champion }) {
                if champion.verified == candidate.verified, champion.params == params, champion.slotKinds == slotKinds,
                   champion.doneWhen == doneWhen, Self.encodedSteps(champion.steps) == encoded {
                    saved = champion
                    return
                }
                candidate.champion = candidate.verified && !champion.verified
                recipes.removeAll { Self.sameGroup($0, candidate) && !$0.champion }
                if candidate.champion, let index = recipes.firstIndex(where: { Self.sameGroup($0, candidate) }) {
                    recipes[index].champion = false
                }
            }
            recipes.append(candidate)
            if recipes.count > Self.maxRecipes {
                // Discard a challenger before displacing a working champion.
                recipes.remove(at: recipes.firstIndex(where: { !$0.champion }) ?? 0)
            }
            saved = candidate
        }
        return persisted ? saved : nil
    }

    /// A late receipt is only allowed to update the version that actually ran.
    func recordReplay(_ recipe: Recipe, succeeded: Bool) {
        guard let version = recipe.version else { return }
        mutate {
            guard let index = recipes.firstIndex(where: { $0.version == version }) else { return }
            if succeeded {
                recipes[index].uses += 1
                recipes[index].failures = 0
            } else {
                recipes[index].failures += 1
                guard recipes[index].failures >= 2 else { return }
                let removed = recipes.remove(at: index)
                if removed.champion, let fallback = recipes.firstIndex(where: {
                    Self.sameGroup($0, removed) && $0.verified && $0.doneWhen == removed.doneWhen
                        && $0.params == removed.params && $0.slotKinds == removed.slotKinds
                }) {
                    recipes[fallback].champion = true
                }
            }
        }
    }

    private static func sameGroup(_ lhs: Recipe, _ rhs: Recipe) -> Bool {
        sameApp(lhs.app, rhs.app)
            && lhs.goal.utf8.elementsEqual(rhs.goal.utf8) && lhs.window == rhs.window
    }

    private static func encodedSteps(_ steps: [Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: steps, options: [.sortedKeys])
    }

    /// Every recipe change runs under the in-process lock and a file lock, on the current file contents, so
    /// two agents (threads or processes) never overwrite each other's recipes.
    @discardableResult
    private func mutate(_ change: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(fileURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        reload(preserveCorrupt: true)
        change()
        return persist()
    }

    /// One-line hint for get_app_state: a recipe exists for this app (the most used one).
    func hint(app: String, state: String?) -> String? {
        guard Self.isEnabled, let window = Window(state: state) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        reload()
        let mine = recipes.filter { $0.verified && $0.champion && $0.window == window && Self.sameApp($0.app, app) }
        guard let top = mine.max(by: { $0.uses < $1.uses }) else { return nil }
        let goal = top.goal.count > 60 ? String(top.goal.prefix(60)) + "…" : top.goal
        return "saved recipe: \(goal)" + (mine.count > 1 ? " (+\(mine.count - 1) more)" : "")
    }

    // MARK: Storage

    /// Reads the file again (another agent may have changed it). A file that cannot be read is set aside as
    /// `recipes.json.corrupt` instead of being overwritten by the next save.
    private func reload(preserveCorrupt: Bool = false) {
        guard let data = try? Data(contentsOf: fileURL) else { recipes = []; return }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if preserveCorrupt {
                try? FileManager.default.removeItem(atPath: fileURL.path + ".corrupt")
                try? FileManager.default.moveItem(atPath: fileURL.path, toPath: fileURL.path + ".corrupt")
            }
            recipes = []
            return
        }
        recipes = array.compactMap { item in
            guard let app = item["app"] as? String, let goal = item["goal"] as? String, let steps = item["steps"] as? [Any],
                  let doneWhen = try? DoneCheck.parse(item["done_when"])
            else { return nil }
            let window = (item["window"] as? [String: Any]).flatMap { object in
                (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(Window.self, from: $0) }
            }
            let kinds = (item["slot_kinds"] as? [String: String] ?? [:]).compactMapValues(SlotKind.init(rawValue:))
            return Recipe(app: app, goal: goal, steps: steps,
                          uses: (item["uses"] as? Int) ?? 0, failures: (item["failures"] as? Int) ?? 0,
                          params: (item["params"] as? [String: String]) ?? [:], slotKinds: kinds, doneWhen: doneWhen,
                          window: window, verified: (item["verified"] as? Bool) == true,
                          version: item["version"] as? String, champion: (item["champion"] as? Bool) ?? true)
        }
    }

    private func persist() -> Bool {
        let array: [[String: Any]] = recipes.map { recipe in
            var item: [String: Any] = [
                "app": recipe.app, "goal": recipe.goal, "steps": recipe.steps, "uses": recipe.uses, "failures": recipe.failures,
                "params": recipe.params, "slot_kinds": recipe.slotKinds.mapValues(\.rawValue),
                "done_when": recipe.doneWhen.map(\.arguments), "verified": recipe.verified, "champion": recipe.champion
            ]
            item["version"] = recipe.version
            if let window = recipe.window, let data = try? JSONEncoder().encode(window) {
                item["window"] = try? JSONSerialization.jsonObject(with: data)
            }
            return item
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: fileURL, options: [.atomic])) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return true
    }

    static func goalKey(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

}

// MARK: - Pure helpers (parameters, keys, per-step effects)

extension BatchRecipes {
    /// A coarse key for detecting possible changes so we can ask for fresh steps.
    static func templateKey(_ goal: String, values: [String] = []) -> String {
        var text = goal
        for value in values.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: value, with: " xxvar ", options: .caseInsensitive)
        }
        for pattern in ["[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "\"[^\"]*\"|\u{201C}[^\u{201D}]*\u{201D}", "\\b\\d+(?:[.,:/]\\d+)*\\b"] {
            text = text.replacingOccurrences(of: pattern, with: " xxvar ", options: .regularExpression)
        }
        return goalKey(text)
    }

    enum SlotKind: String {
        case recipient, email, number, path, text

        static func infer(name: String, label: String?, value: String) -> Self {
            let words = Set(RecipeLocator.tokens(name + " " + (label ?? "")))
            if !words.isDisjoint(with: ["recipient", "to", "cc", "bcc"]) { return .recipient }
            if words.contains("email") || words.contains("mail") || Self.email.accepts(value) { return .email }
            if !words.isDisjoint(with: ["path", "folder", "directory"]) || Self.path.accepts(value) { return .path }
            if !words.isDisjoint(with: ["number", "quantity", "amount"]) || Self.number.accepts(value) { return .number }
            return .text
        }

        func accepts(_ value: String) -> Bool {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.contains("\0") else { return false }
            switch self {
            case .recipient: return !value.contains(where: \.isNewline)
            case .email: return value.range(of: #"\A[^@\s]+@[^@\s]+\.[^@\s]+\z"#, options: .regularExpression) != nil
            case .number: return DoneCheck.isPlainNumber(value)
            case .path: return (value.hasPrefix("/") || value.hasPrefix("~/")) && !value.contains(where: \.isNewline)
            case .text: return true
            }
        }
    }

    static func slotProblem(_ recipe: Recipe, values: [String: String]) -> String? {
        let expected = Set(recipe.params.keys)
        let missing = expected.subtracting(values.keys).sorted()
        if !missing.isEmpty { return "Confirm and provide the recipe slots: \(missing.joined(separator: ", "))." }
        guard Set(values.keys) == expected, Set(recipe.slotKinds.keys) == expected else {
            return "The recipe slots differ from the recorded inputs. Confirm the inputs and provide fresh steps."
        }
        for name in expected.sorted() {
            guard let value = values[name], let type = recipe.slotKinds[name], type.accepts(value),
                  recipe.params[name]?.utf8.elementsEqual(value.utf8) == true else {
                return "Recipe slot '\(name)' changed or has the wrong type. Confirm it and provide fresh steps."
            }
        }
        return nil
    }

    static func parseValues(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dict where !(value is NSNull) { result[key] = "\(value)" }
        return result
    }

    /// Variable name from a field label: "To" -> "to", "Email address" -> "email_address".
    static func variableName(label: String?) -> String {
        let words = RecipeLocator.tokens(label ?? "").prefix(3)
        return words.isEmpty ? "text" : words.joined(separator: "_")
    }

    /// The argument that holds typed text for a step, if it is a typing step.
    static func textKey(tool: String, arguments: [String: Any]) -> String? {
        switch tool {
        case "type_text": return "text"
        case "set_value": return "value"
        case "browser": return ((arguments["action"] as? String) ?? "").lowercased() == "type" ? "text" : nil
        default: return nil
        }
    }

    /// Turns typed text into `{{name}}` variables. `values` (name to value) names a variable when its value
    /// is what was typed; otherwise the field label does.
    static func parameterize(_ steps: [[String: Any]], values: [String: String]) -> (steps: [[String: Any]], params: [String: String], kinds: [String: SlotKind]) {
        var params: [String: String] = [:]
        var kinds: [String: SlotKind] = [:]
        var result = steps
        for (i, step) in steps.enumerated() {
            let tool = (step["tool"] as? String) ?? ""
            guard let key = textKey(tool: tool, arguments: step), let text = step[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("{{")
            else { continue }
            var name = values.keys.sorted().first { values[$0] == text && params[$0] == nil }
                ?? variableName(label: step["label"] as? String)
            if params[name] != nil, params[name] != text || name == "text" {
                var n = 2
                while params["\(name)_\(n)"] != nil { n += 1 }
                name = "\(name)_\(n)"
            }
            params[name] = text
            kinds[name] = SlotKind.infer(name: name, label: step["label"] as? String, value: text)
            result[i][key] = "{{\(name)}}"
        }
        return (result, params, kinds)
    }

    /// Bind only complete placeholders in typing arguments. Values are never interpolated into targets.
    static func boundSteps(_ recipe: Recipe, values: [String: String]) throws -> [Any] {
        if let problem = slotProblem(recipe, values: values) { throw ComputerUseError.invalidArguments(problem) }
        var used = Set<String>()
        let steps = try recipe.steps.map { item -> [String: Any] in
            guard var step = item as? [String: Any], let tool = step["tool"] as? String else {
                throw ComputerUseError.invalidArguments("The saved recipe has an invalid step.")
            }
            step = step.filter { !$0.key.hasPrefix("_") }
            if let key = textKey(tool: tool, arguments: step) {
                guard let text = step[key] as? String else {
                    throw ComputerUseError.invalidArguments("The saved typing step needs a text slot. Provide fresh steps.")
                }
                if text.isEmpty { return step }
                guard let name = values.keys.first(where: { text == "{{\($0)}}" }), let value = values[name] else {
                    throw ComputerUseError.invalidArguments("The saved typing step needs a confirmed slot. Provide fresh steps.")
                }
                used.insert(name)
                step[key] = value
            }
            return step
        }
        guard used == Set(values.keys) else {
            throw ComputerUseError.invalidArguments("The recipe has unused slots. Confirm the inputs and provide fresh steps.")
        }
        return steps
    }

    // MARK: Per-step effects

    /// The lines belonging to step `number` in a batch reply: after "N. ..." until the next step line.
    static func block(for number: Int, in lines: [String]) -> [String] {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("\(number). ") }) else { return [] }
        var block = [lines[start]]
        for line in lines[(start + 1)...] {
            if line.range(of: "^\\d+\\. ", options: .regularExpression) != nil { break }
            if line.hasPrefix("Steps ") || line.hasPrefix("Stopped") { break }
            block.append(line)
        }
        return block
    }

    /// "changed" when the block shows an effect, "none" for "no visible change", nil when unknown.
    static func effectKind(of block: [String]) -> String? {
        let trimmed = block.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.contains("no visible change") { return "none" }
        if trimmed.contains(where: { $0.hasPrefix("effect:") || $0.hasPrefix("new:") || $0.hasPrefix("gone:") || $0.hasPrefix("screen changed") }) {
            return "changed"
        }
        return nil
    }

    /// The hand-back line when a replayed step did nothing although it changed the screen when saved.
    static func replayStop(number: Int, total: Int, recorded: String?, block: [String]) -> String? {
        guard recorded == "changed", effectKind(of: block) == "none", let head = block.first else { return nil }
        let rest = number < total ? " Steps \(number + 1)-\(total) were not run;" : ""
        return "Replay stopped: step \(head.trimmingCharacters(in: .whitespaces)) had no visible effect, but it did when the recipe was saved.\(rest) continue yourself from the state below."
    }
}

// MARK: - One batch's recipe bookkeeping

extension BatchRecipes {
    /// Carries the recipe, recorded targets and save decision for one batch.
    final class Run {
        struct Meta {
            var locator: RecipeLocator.Locator?
            var effect: String?
        }

        let goal: String
        let values: [String: String]
        let active: Bool
        /// Where recipes are kept (tests pass their own).
        var store: BatchRecipes = .shared
        private let app: String?
        private let read: (String) -> String?
        private(set) var recipe: Recipe?
        private(set) var startingState: String?
        private var initialRead = false
        private var replayMeta: [Int: Meta] = [:]
        private var recorded: [Int: RecipeLocator.Locator] = [:]
        /// The batch's `done_when`, set by the caller. Used to tell whether it was already true before the steps ran.
        var doneWhen: [DoneCheck.Condition] = []
        var canSave = true
        /// Step numbers that type into a secret field (password, code ...): such a batch is never saved.
        private var secretSteps: Set<Int> = []
        private var initialDone: Bool?

        /// `read` returns the state text of an app (one cheap accessibility read) or nil.
        init(goal: String, values: Any?, app: String?, read: @escaping (String) -> String?) {
            self.goal = goal
            self.values = BatchRecipes.parseValues(values)
            self.app = app
            self.read = read
            self.active = BatchRecipes.isEnabled && !goal.isEmpty
        }

        private func state(of stepApp: String?, observed: String? = nil) -> String? {
            guard let target = stepApp ?? app else { return nil }
            if let app, !BatchRecipes.sameApp(app, target) { return nil }
            if !initialRead {
                initialRead = true
                startingState = observed ?? read(target)
            }
            return startingState
        }

        func lookup(app lookupApp: String?) -> Lookup {
            store.lookup(app: lookupApp, goal: goal, values: values, state: state(of: lookupApp))
        }

        func replaySteps(_ recipe: Recipe) throws -> [Any] {
            let steps = try BatchRecipes.boundSteps(recipe, values: values)
            self.recipe = recipe
            for (i, item) in recipe.steps.enumerated() {
                guard let dict = item as? [String: Any] else { continue }
                replayMeta[i + 1] = Meta(locator: RecipeLocator.Locator(dictionary: dict["_loc"]), effect: dict["_fx"] as? String)
            }
            return steps
        }

        /// Always check the freshly selected window before binding a saved step to its ID.
        func prepareReplay(_ step: BatchTool.Step, number: Int) -> BatchTool.Step? {
            guard let recipe, let expected = recipe.window, let app,
                  let fresh = read(app), Window(state: fresh) == expected else { return nil }
            if !step.isReadOnly {
                guard let label = step.arguments["label"] as? String, let locator = replayMeta[number]?.locator,
                      RecipeLocator.confirms(locator, label: label, in: fresh) else { return nil }
            }
            return HandoffTool.bindRecipeStep(step, app: app, state: fresh)
        }

        /// Record the starting screen and locator during an explicit run.
        func prepared(_ step: BatchTool.Step, number: Int, before: String?) -> BatchTool.Step? {
            guard active, canSave else { return step }
            let stepApp = (step.arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let screenBeforeFirstStep = state(of: stepApp, observed: before)
            if initialDone == nil { initialDone = wasAlreadyDone() }
            let screen = before ?? (number == 1 ? screenBeforeFirstStep : nil) ?? (stepApp ?? app).flatMap(read)
            noteSecret(step, number: number, screen: screen)
            if let label = step.arguments["label"] as? String, !label.isEmpty, let screen,
               Window(state: screen) == Window(state: startingState),
               let locator = RecipeLocator.capture(label: label, in: screen) {
                recorded[number] = locator
            }
            return step
        }

        /// Marks a typing step that goes into a secret field, from its label or from the screen it typed on.
        private func noteSecret(_ step: BatchTool.Step, number: Int, screen: String?) {
            guard BatchRecipes.textKey(tool: step.tool, arguments: step.arguments) != nil else { return }
            var named = ""
            for key in ["label", "field", "selector", "name", "placeholder"] {
                if let text = step.arguments[key] as? String { named += " " + text }
            }
            if RecipeLocator.looksSecret(named) { secretSteps.insert(number); return }
            guard let screen else { return }
            let label = (step.arguments["label"] as? String) ?? ""
            if !label.isEmpty {
                if RecipeLocator.isSecretField(label: label, in: screen) { secretSteps.insert(number) }
            } else if step.arguments["element_index"] != nil || RecipeLocator.hasSecureField(screen) {
                // Typing into whatever is focused while a password field is on screen: assume it is that field.
                secretSteps.insert(number)
            }
        }

        func alreadySatisfied() -> ToolCallResult? {
            guard case .weak(let met) = initialCheck() else { return nil }
            return ToolCallResult(
                content: [.text("Already satisfied before replay (weak evidence): \(met.joined(separator: ", ")). No steps ran.")],
                isError: false, batchReceipt: .init(totalSteps: 0, doneCheck: .weakEvidence), deliveryState: .notSent
            )
        }

        private func initialCheck() -> DoneCheck.Result {
            // Before step 1, a change-aware condition cannot have a transition.
            DoneCheck.check(doneWhen, evidence: .init(screenText: startingState, pageURL: { nil }))
        }

        /// True when done_when already held before dispatch, or the starting window could not be read.
        private func wasAlreadyDone() -> Bool {
            if doneWhen.isEmpty { return false }
            if case .weak = initialCheck() { return true }
            return startingState == nil
        }

        func checkReplay(evidence: DoneCheck.Evidence, baseline: BatchCompletion?,
                         after: BatchCompletion.Observation?) -> DoneCheck.Result {
            guard let expected = recipe?.window, Window(state: evidence.screenText) == expected else {
                return .missing(unmet: doneWhen.map(\.summary))
            }
            return DoneCheck.check(doneWhen, evidence: evidence, baseline: baseline, after: after)
        }

        /// After each step: a line when a replayed step no longer has the effect it had when saved.
        func verify(number: Int, total: Int, lines: [String], observation: BatchEffects.Receipt?) -> String? {
            guard recipe != nil, number < total else { return nil }
            if observation == .outcomeUnknown {
                return "Replay stopped after step \(number). Inspect its result before continuing."
            }
            var block = BatchRecipes.block(for: number, in: lines)
            if observation == .noEffectSeen { block.append("no visible change") }
            return BatchRecipes.replayStop(number: number, total: total, recorded: replayMeta[number]?.effect, block: block)
        }

        /// End of the batch: records a replay, or saves a new recipe. Returns the lines to add to the reply.
        func finish(app lastApp: String, steps: [BatchTool.Step], lines: [String], failed: Bool, stopped: Bool,
                    remember: Bool?, verifiedDone: Bool, finalState: String? = nil) -> [String] {
            guard active else { return [] }
            var out: [String] = []
            if let recipe {
                if !stopped { store.recordReplay(recipe, succeeded: !failed && verifiedDone) }
                return []
            }
            guard !failed, !stopped else { return [] }
            if !doneWhen.isEmpty && !verifiedDone {
                return remember == true ? ["Recipe was not saved because its completion check did not pass."] : []
            }
            if steps.contains(where: { $0.arguments["window_id"] != nil }) {
                return remember == true ? ["Recipe was not saved because it targets a temporary window ID."] : []
            }
            let positional = BatchTool.usesPositionalTargets(steps)
            let mutating = steps.contains { !BatchTool.readOnlyTools.contains($0.tool) && $0.tool != BatchTool.waitName }
            if remember == true, mutating, doneWhen.isEmpty {
                return ["Recipe was not saved. Mutating steps need a deterministic done_when."]
            }
            let window = Window(state: startingState)
            let verified: Bool
            if canSave, verifiedDone, initialDone == false, let window, Window(state: finalState) == window {
                verified = true
            } else {
                verified = false
            }
            if verifiedDone, remember != false, !verified, mutating {
                out.append("The starting state did not prove these steps reached done_when. This run cannot verify a recipe.")
            }
            if (remember == true || verified), mutating {
                if !secretSteps.isEmpty || values.keys.contains(where: { RecipeLocator.looksSecret($0) }) {
                    out.append("Not saved as a recipe: it types into a password or secret field, and those are never stored.")
                    return out
                }
                if positional {
                    if remember == true {
                        out.append("Not saved as a recipe: some steps use element numbers or coordinates, which change between reads. Use labels to make a recipe.")
                    }
                    return out
                }
                let save = buildSave(app: lastApp, steps: steps, lines: lines)
                let eligible = steps.enumerated().allSatisfy { offset, step in
                    HandoffTool.isSafeRecipeStep(step, app: lastApp)
                        && (step.isReadOnly || recorded[offset + 1] != nil)
                }
                guard let saved = store.save(app: lastApp, goal: goal, steps: save.steps, params: save.params,
                                             slotKinds: save.kinds, doneWhen: doneWhen, window: window,
                                             verified: verified && eligible) else { return out }
                let status = !saved.verified ? "unverified" : saved.champion ? "verified" : "verified challenger"
                out.append("Saved a \(status) recipe for \"\(goal)\".")
                if saved.verified && saved.champion && !save.params.isEmpty {
                    out.append("Provide these slots again when replaying: \(save.params.keys.sorted().joined(separator: ", ")).")
                }
            }
            return out
        }

        private func buildSave(app lastApp: String, steps: [BatchTool.Step], lines: [String]) -> (steps: [Any], params: [String: String], kinds: [String: SlotKind]) {
            var dicts: [[String: Any]] = steps.map { step in
                var dict = step.arguments
                if let stepApp = dict["app"] as? String, BatchRecipes.sameApp(stepApp, lastApp) { dict["app"] = nil }
                dict["tool"] = step.tool
                return dict
            }
            let parameterized = BatchRecipes.parameterize(dicts, values: values)
            dicts = parameterized.steps
            for i in dicts.indices {
                if let locator = recorded[i + 1] { dicts[i]["_loc"] = locator.dictionary }
                if let kind = BatchRecipes.effectKind(of: BatchRecipes.block(for: i + 1, in: lines)) { dicts[i]["_fx"] = kind }
            }
            return (dicts, parameterized.params, parameterized.kinds)
        }
    }
}
