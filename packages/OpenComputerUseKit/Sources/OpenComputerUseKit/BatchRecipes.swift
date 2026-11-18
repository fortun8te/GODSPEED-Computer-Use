import Foundation

/// Saved step lists that reached a goal, so the same goal can be replayed in one call without the
/// model planning each step again (workflow memory; Hark's "composite actions" are the same idea).
///
/// Saving: a batch with a `goal` and no failed step is saved by itself when its `done_when` was verified
/// directly (DoneCheck), or when the model passed `remember: true` (`remember: false` opts out). The
/// referee alone only suggests saving. Steps that target elements by number or coordinates are never saved.
/// Typed text and set_value values become variables named after the field label (`{{to}}`), with the saved
/// values kept as defaults; a replay can pass `values` to change them. The cache key is app + goal with
/// values removed + window title shape, never the values. Each step keeps a self-healing locator
/// (RecipeLocator) and whether it changed the screen; a replayed step that no longer changes the screen
/// stops the replay and hands back to the model. A replay that fails twice is dropped. Stored only on this
/// Mac in `~/.godspeed/recipes.json`; `OPEN_COMPUTER_USE_RECIPES=0` turns recipes off.
final class BatchRecipes: @unchecked Sendable {
    static let shared = BatchRecipes()

    static let isEnabled: Bool = {
        let value = GodspeedSettings.environment["OPEN_COMPUTER_USE_RECIPES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }()

    static let maxRecipes = 300
    /// Same bar as the referee's "done" hint, so a save suggestion never appears without that hint.
    static var saveConfidence: Double { Referee.doneConfidence }

    struct Recipe {
        let app: String
        let goal: String
        var steps: [Any]
        var uses: Int
        var failures: Int
        /// Variable name to the value it had when saved (the default on replay).
        var params: [String: String] = [:]
        /// Window title shape the recipe was saved in ("" for older recipes: matches any).
        var shape: String = ""
    }

    private let lock = NSLock()
    private var recipes: [Recipe] = []
    private let fileURL: URL

    init(fileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".godspeed/recipes.json")) {
        self.fileURL = fileURL
    }

    /// The saved recipe for this goal (values removed) in `app` when given, otherwise in any app. `shape`
    /// is the current window title shape when known; a recipe saved under another shape does not match.
    func find(app: String?, goal: String, values: [String: String] = [:], shape: String? = nil) -> Recipe? {
        lock.lock()
        defer { lock.unlock() }
        reload()
        let wanted = Self.templateKey(goal, values: Array(values.values))
        guard !wanted.isEmpty else { return nil }
        let candidates = app.map { name in recipes.filter { Self.normalize($0.app) == Self.normalize(name) } } ?? recipes
        var matches = candidates.filter { Self.templateKey($0.goal, values: Array($0.params.values)) == wanted }
        if let shape, !shape.isEmpty {
            matches = matches.filter { $0.shape.isEmpty || $0.shape == shape }
            let exact = matches.filter { $0.shape == shape }
            if exact.count == 1 { return exact[0] }
        }
        // A goal without an app must not pick arbitrarily between apps.
        return matches.count == 1 ? matches[0] : nil
    }

    func save(app: String, goal: String, steps: [Any], params: [String: String] = [:], shape: String = "") {
        guard JSONSerialization.isValidJSONObject(steps) else { return }
        mutate {
            let appKey = Self.normalize(app)
        let wanted = Self.templateKey(goal, values: Array(params.values))
            recipes.removeAll { Self.same($0, appKey: appKey, key: wanted, shape: shape) }
            recipes.append(Recipe(app: app, goal: goal, steps: steps, uses: 0, failures: 0, params: params, shape: shape))
            if recipes.count > Self.maxRecipes { recipes.removeFirst(recipes.count - Self.maxRecipes) }
        }
    }

    /// Records how a replay went; a recipe that failed twice in a row is dropped. `healedSteps` (a replay
    /// that worked after healing locators) replaces the stored steps.
    func recordReplay(_ recipe: Recipe, succeeded: Bool, healedSteps: [Any]? = nil) {
        let appKey = Self.normalize(recipe.app)
        let key = Self.templateKey(recipe.goal, values: Array(recipe.params.values))
        mutate {
            guard let index = recipes.firstIndex(where: { Self.same($0, appKey: appKey, key: key, shape: recipe.shape) })
            else { return }
            if succeeded {
                recipes[index].uses += 1
                recipes[index].failures = 0
                if let healedSteps, JSONSerialization.isValidJSONObject(healedSteps) { recipes[index].steps = healedSteps }
            } else {
                recipes[index].failures += 1
                if recipes[index].failures >= 2 { recipes.remove(at: index) }
            }
        }
    }

    /// Every recipe change runs under the in-process lock and a file lock, on the current file contents, so
    /// two agents (threads or processes) never overwrite each other's recipes.
    private func mutate(_ change: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(fileURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        reload()
        change()
        persist()
    }

    private static func same(_ r: Recipe, appKey: String, key: String, shape: String) -> Bool {
        normalize(r.app) == appKey && templateKey(r.goal, values: Array(r.params.values)) == key && r.shape == shape
    }

    /// One-line hint for get_app_state: a recipe exists for this app (the most used one).
    func hint(app: String) -> String? {
        guard Self.isEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        reload()
        let key = Self.normalize(app)
        let mine = recipes.filter { Self.normalize($0.app) == key }
        guard let top = mine.max(by: { $0.uses < $1.uses }) else { return nil }
        let goal = top.goal.count > 60 ? String(top.goal.prefix(60)) + "…" : top.goal
        return "saved recipe: \(goal)" + (mine.count > 1 ? " (+\(mine.count - 1) more)" : "")
    }

    // MARK: Storage

    /// Reads the file again (another agent may have changed it). A file that cannot be read is set aside as
    /// `recipes.json.corrupt` instead of being overwritten by the next save.
    private func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { recipes = []; return }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            try? FileManager.default.removeItem(atPath: fileURL.path + ".corrupt")
            try? FileManager.default.moveItem(atPath: fileURL.path, toPath: fileURL.path + ".corrupt")
            recipes = []
            return
        }
        recipes = array.compactMap { item in
            guard let app = item["app"] as? String, let goal = item["goal"] as? String, let steps = item["steps"] as? [Any]
            else { return nil }
            return Recipe(app: app, goal: goal, steps: steps,
                          uses: (item["uses"] as? Int) ?? 0, failures: (item["failures"] as? Int) ?? 0,
                          params: (item["params"] as? [String: String]) ?? [:], shape: (item["shape"] as? String) ?? "")
        }
    }

    private func persist() {
        let array: [[String: Any]] = recipes.map {
            ["app": $0.app, "goal": $0.goal, "steps": $0.steps, "uses": $0.uses, "failures": $0.failures,
             "params": $0.params, "shape": $0.shape]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: Matching

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func goalKey(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

}

// MARK: - Pure helpers (parameters, keys, per-step effects)

extension BatchRecipes {
    /// The goal with values, e-mail addresses, numbers and quoted text taken out, so the same goal with
    /// different values has the same key.
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

    /// A window title without the document or page part: the text after the last separator, letters
    /// only, three words at most ("Q3 plan - Pages" and "Notes - Pages" both give "pages").
    static func windowShape(title: String?) -> String {
        guard var text = title?.lowercased(), !text.isEmpty else { return "" }
        for separator in [" \u{2014} ", " \u{2013} ", " - ", " | "] {
            if let range = text.range(of: separator, options: .backwards) {
                text = String(text[range.upperBound...])
                break
            }
        }
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.allSatisfy(\.isLetter) }
        return words.prefix(3).joined(separator: " ")
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
    static func parameterize(_ steps: [[String: Any]], values: [String: String]) -> (steps: [[String: Any]], params: [String: String]) {
        var params: [String: String] = [:]
        var result = steps
        for (i, step) in steps.enumerated() {
            let tool = (step["tool"] as? String) ?? ""
            guard let key = textKey(tool: tool, arguments: step), let text = step[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("{{")
            else { continue }
            var name = values.first { $0.value == text && params[$0.key] == nil }?.key
                ?? variableName(label: step["label"] as? String)
            if params[name] != nil, params[name] != text || name == "text" {
                var n = 2
                while params["\(name)_\(n)"] != nil { n += 1 }
                name = "\(name)_\(n)"
            }
            params[name] = text
            result[i][key] = "{{\(name)}}"
        }
        return (result, params)
    }

    /// Puts values into `{{name}}` placeholders (a given value wins over the saved default) and removes the
    /// bookkeeping keys. `ignored` lists given values the recipe has no variable for.
    static func substitute(_ steps: [Any], params: [String: String], values: [String: String]) -> (steps: [Any], ignored: [String]) {
        let result: [Any] = steps.map { item in
            guard var dict = item as? [String: Any] else { return item }
            for key in dict.keys where key.hasPrefix("_") { dict[key] = nil }
            for (key, value) in dict {
                guard var text = value as? String, text.contains("{{") else { continue }
                for name in params.keys.sorted() {
                    text = text.replacingOccurrences(of: "{{\(name)}}", with: values[name] ?? params[name] ?? "")
                }
                dict[key] = text
            }
            return dict
        }
        return (result, values.keys.filter { params[$0] == nil }.sorted())
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
    /// Carries a batch's recipe state: the replayed recipe and values, locators captured for saving or
    /// healed on replay, and the save decision at the end. One per batch call; used from one thread.
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
        private var initialState: String?
        private var initialRead = false
        private var replayMeta: [Int: Meta] = [:]
        private var recorded: [Int: RecipeLocator.Locator] = [:]
        private var healed: [Int: (label: String, locator: RecipeLocator.Locator)] = [:]
        private var notes: [String] = []
        private var ignored: [String] = []
        /// The batch's `done_when`, set by the caller. Used to tell whether it was already true before the steps ran.
        var doneWhen: [DoneCheck.Condition] = []
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

        private func state(of stepApp: String?) -> String? {
            guard let target = stepApp ?? app else { return nil }
            if let app, BatchRecipes.normalize(app) != BatchRecipes.normalize(target) { return nil }
            if !initialRead { initialRead = true; initialState = read(target) }
            return initialState
        }

        /// The saved recipe for the goal and values, matched also on the window title shape.
        func find(app lookupApp: String?) -> Recipe? {
            let shape = lookupApp.flatMap { state(of: $0) }.map { BatchRecipes.windowShape(title: BatchEffects.windowTitle(in: $0)) }
            recipe = store.find(app: lookupApp, goal: goal, values: values, shape: shape)
            return recipe
        }

        /// The recipe's steps with values put in; locators and effects are kept for the replay.
        func replaySteps(_ recipe: Recipe) -> [Any] {
            for (i, item) in recipe.steps.enumerated() {
                guard let dict = item as? [String: Any] else { continue }
                replayMeta[i + 1] = Meta(locator: RecipeLocator.Locator(dictionary: dict["_loc"]), effect: dict["_fx"] as? String)
            }
            let out = BatchRecipes.substitute(recipe.steps, params: recipe.params, values: values)
            ignored = out.ignored
            return out.steps
        }

        /// Called with each step before it runs: records its locator when saving, heals its label on replay.
        func prepared(_ step: BatchTool.Step, number: Int, before: String?) -> BatchTool.Step {
            guard active else { return step }
            let stepApp = (step.arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // The first read happens before the first step runs: it is the "before" picture for saving
            // (was done_when already true?) and for secret-field checks, even if no step has a label.
            let screenBeforeFirstStep = recipe == nil ? state(of: stepApp) : nil
            if recipe == nil { noteSecret(step, number: number, screen: before ?? screenBeforeFirstStep) }
            guard let label = step.arguments["label"] as? String, !label.isEmpty else { return step }
            // A replayed step heals against the screen as it is now, not the one read at the start.
            let fresh: String? = (recipe != nil && number > 1 && before == nil) ? ((stepApp ?? app).flatMap(read)) : nil
            guard let screen = before ?? fresh ?? state(of: stepApp) else { return step }
            if recipe != nil {
                guard let locator = replayMeta[number]?.locator else { return step }
                if case .healed(let newLabel, let newLocator) = RecipeLocator.resolve(locator, label: label, in: screen) {
                    var arguments = step.arguments
                    arguments["label"] = newLabel
                    healed[number] = (newLabel, newLocator)
                    notes.append("Step \(number): \"\(label)\" is now \"\(newLabel)\"; the recipe is updated if the replay works.")
                    return BatchTool.Step(tool: step.tool, arguments: arguments)
                }
            } else if let locator = RecipeLocator.capture(label: label, in: screen) {
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

        /// True when done_when held on the screen before any step ran, so it proves nothing about these steps.
        /// Unknown (screen unreadable) counts as true: such a batch is not saved by itself.
        private func wasAlreadyDone() -> Bool {
            if let initialDone { return initialDone }
            let result: Bool
            if doneWhen.isEmpty {
                result = false
            } else if let screen = initialState {
                if case .verified = DoneCheck.check(doneWhen, evidence: DoneCheck.Evidence(screenText: screen, pageURL: { nil })) {
                    result = true
                } else { result = false }
            } else {
                result = true
            }
            initialDone = result
            return result
        }

        /// After each step: a line when a replayed step no longer has the effect it had when saved.
        func verify(number: Int, total: Int, lines: [String]) -> String? {
            guard recipe != nil, number < total else { return nil }
            return BatchRecipes.replayStop(number: number, total: total, recorded: replayMeta[number]?.effect,
                                           block: BatchRecipes.block(for: number, in: lines))
        }

        /// End of the batch: records a replay, or saves a new recipe. Returns the lines to add to the reply.
        func finish(app lastApp: String, steps: [BatchTool.Step], lines: [String], failed: Bool, stopped: Bool,
                    remember: Bool?, verifiedDone: Bool, refereeSaysDone: Bool) -> [String] {
            guard active else { return [] }
            var out: [String] = []
            if let recipe {
                var stored = recipe.steps
                if !failed, verifiedDone || doneWhen.isEmpty, !healed.isEmpty {
                    for (number, fix) in healed where stored.indices.contains(number - 1) {
                        if var dict = stored[number - 1] as? [String: Any] {
                            dict["label"] = fix.label
                            dict["_loc"] = fix.locator.dictionary
                            stored[number - 1] = dict
                        }
                    }
                }
                // Cut short by time: neither a success nor a failure of the recipe.
                // A replay whose done_when did not verify did not reach the goal.
                let reached = !failed && (doneWhen.isEmpty || verifiedDone)
                if !stopped {
                    store.recordReplay(recipe, succeeded: reached, healedSteps: (healed.isEmpty || !reached) ? nil : stored)
                }
                out += notes
                if !ignored.isEmpty { out.append("Ignored values with no variable in this recipe: \(ignored.joined(separator: ", ")).") }
                return out
            }
            guard !failed, !stopped else { return [] }
            let positional = BatchTool.usesPositionalTargets(steps)
            let mutating = steps.contains { !BatchTool.readOnlyTools.contains($0.tool) && $0.tool != BatchTool.waitName }
            let auto = verifiedDone && remember != false && !wasAlreadyDone()
            if verifiedDone, remember != false, !auto, mutating {
                out.append("Not saved as a recipe: done_when was already true before these steps ran, so it does not show they worked. Send remember: true to save anyway.")
            }
            if (remember == true || auto), mutating {
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
                store.save(app: lastApp, goal: goal, steps: save.steps, params: save.params, shape: save.shape)
                let why = remember == true ? "" : " (done_when was verified)"
                let names = save.params.isEmpty ? "" : " Variables: \(save.params.keys.sorted().joined(separator: ", ")); pass values to change them."
                out.append("Saved these steps as the recipe for \"\(goal)\"\(why); next time send just the goal to replay them.\(names)")
            } else if refereeSaysDone, !positional, mutating {
                out.append("This looks like it reached the goal. Send the same batch with remember: true to save it as a recipe.")
            }
            return out
        }

        private func buildSave(app lastApp: String, steps: [BatchTool.Step], lines: [String]) -> (steps: [Any], params: [String: String], shape: String) {
            var dicts: [[String: Any]] = steps.map { step in
                var dict = step.arguments
                if let stepApp = dict["app"] as? String, BatchRecipes.normalize(stepApp) == BatchRecipes.normalize(lastApp) { dict["app"] = nil }
                dict["tool"] = step.tool
                return dict
            }
            let parameterized = BatchRecipes.parameterize(dicts, values: values)
            dicts = parameterized.steps
            for i in dicts.indices {
                if let locator = recorded[i + 1] { dicts[i]["_loc"] = locator.dictionary }
                if let kind = BatchRecipes.effectKind(of: BatchRecipes.block(for: i + 1, in: lines)) { dicts[i]["_fx"] = kind }
            }
            let shape = BatchRecipes.windowShape(title: initialState.flatMap { BatchEffects.windowTitle(in: $0) })
            return (dicts, parameterized.params, shape)
        }
    }
}
