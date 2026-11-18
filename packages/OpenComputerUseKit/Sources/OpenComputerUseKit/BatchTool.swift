import Foundation

/// One call, many steps. Runs tool calls in order, stops at the first failure, and answers with one
/// short line per step plus a single fresh observation of the app. Built so weak models need fewer
/// turns: forgiving step spelling, no per-step state dumps, and a plain note when a batch changed
/// nothing on screen (the runaway re-read loops seen in agent logs).
enum BatchTool {
    static let name = "batch"
    static let maxSteps = 40
    /// Seconds a batch may run before it stops between steps.
    static let timeBudget: TimeInterval = 75

    /// Spellings small models commonly use for our tools.
    static let toolAliases: [String: String] = [
        "type": "type_text", "write": "type_text", "input": "type_text", "enter_text": "type_text",
        "key": "press_key", "press": "press_key", "keypress": "press_key", "hotkey": "press_key", "shortcut": "press_key",
        "set": "set_value", "fill": "set_value",
        "state": "get_app_state", "look": "get_app_state", "observe": "get_app_state", "read": "get_app_state",
        "find": "query", "search": "query",
        "secondary_action": "perform_secondary_action",
        "tap": "click", "left_click": "click", "press_button": "click",
        "apps": "list_apps",
        "wait_until": "wait", "wait_for_window": "wait", "sleep": "wait", "pause": "wait",
        "double_click": "click", "doubleclick": "click", "right_click": "click", "rightclick": "click",
        "key_press": "press_key", "send_key": "press_key",
        "menu": "press_menu", "menu_item": "press_menu", "select_menu": "press_menu", "click_menu": "press_menu",
    ]

    /// Tools whose text result is the answer itself, so the batch reply keeps it.
    static let informationalTools: Set<String> = ["query", "list_apps", "browser"]

    /// Tools that only read; a batch made only of these never triggers the unchanged-screen note.
    static let readOnlyTools: Set<String> = ["query", "list_apps", "get_app_state"]

    struct Step {
        let tool: String
        let arguments: [String: Any]
    }

    /// Whether the state this agent last saw for `app` had a sheet or dialog open. Steps in a dialog need the
    /// app in front (keys and typing do not reach a background sheet), so the batch borrows focus for them.
    static func dialogWasShown(app: String) -> Bool {
        BatchObservationMemory.shared.shownText(app: app).map(RefereeSummary.dialogOpen(in:)) ?? false
    }

    static let waitName = "wait"

    static func canonicalToolName(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return toolAliases[key] ?? key
    }

    static func parseSteps(_ raw: Any?, defaultApp: String?) throws -> [Step] {
        guard let array = raw as? [Any], !array.isEmpty else {
            throw ComputerUseError.invalidArguments(
                "steps must be a non-empty array like [{\"tool\": \"click\", \"label\": \"Send\"}]"
            )
        }
        guard array.count <= maxSteps else {
            throw ComputerUseError.invalidArguments(
                "steps allows at most \(maxSteps) entries; split the work into several batch calls"
            )
        }

        let known = Set(ToolDefinitions.all.map(\.name)).subtracting([name]).union([waitName, "form", "fill_form"])

        let expanded: [Step] = try array.enumerated().flatMap { offset, item -> [Step] in
            let number = offset + 1
            guard let object = item as? [String: Any] else {
                throw ComputerUseError.invalidArguments("step \(number) must be an object with a tool")
            }

            var arguments: [String: Any] = [:]
            if let nested = (object["args"] ?? object["arguments"]) as? [String: Any] {
                arguments = nested
            }
            for (key, value) in object where !["tool", "name", "args", "arguments"].contains(key) {
                arguments[key] = value
            }

            var rawTool = (object["tool"] as? String) ?? (object["name"] as? String)
            if rawTool == nil, let action = object["action"] as? String {
                // url/urls mean web; a bare index means web only when no app is named for this step.
                let looksLikeWeb = object["url"] != nil || object["urls"] != nil
                    || (object["index"] != nil && object["app"] == nil && defaultApp == nil)
                if looksLikeWeb, known.contains("browser") {
                    // {"action": "go", "url": ...} or {"action": "click", "index": 3}: a browser step.
                    rawTool = "browser"
                } else if known.contains(canonicalToolName(action)) {
                    rawTool = action
                    arguments.removeValue(forKey: "action")
                }
            }
            // {"type": "click", ...}: models (GPT-6 Luna in the race) name the tool "type" too. Only a known
            // tool name counts, so a type_text step's own "text" or a "type" value meant as text is never taken.
            if rawTool == nil, let kind = object["type"] as? String, known.contains(canonicalToolName(kind)) {
                rawTool = kind
                arguments.removeValue(forKey: "type")
            }
            // Shorthand steps (seen from GPT-6 Luna): {"type_text": "69104"}, {"press_key": "cmd+s"}, {"click": "Save"}
            // name the tool as the key; {"key": "cmd+a"}, {"text": "hi"}, {"label": "Save"} name only the argument.
            if rawTool == nil {
                for (key, value) in object where known.contains(canonicalToolName(key)) {
                    let tool = canonicalToolName(key)
                    rawTool = tool
                    arguments.removeValue(forKey: key)
                    if let text = value as? String {
                        switch tool {
                        case "type_text": arguments["text"] = text
                        case "press_key": arguments["key"] = text
                        case "press_menu": arguments["path"] = text
                        case "open", "save_as": arguments["path"] = text
                        default: arguments["label"] = text
                        }
                    } else if let nested = value as? [String: Any] {
                        arguments.merge(nested) { _, new in new }
                    }
                    break
                }
            }
            if rawTool == nil {
                if object["key"] != nil { rawTool = "press_key" }
                else if object["text"] != nil, object["label"] == nil, object["element_index"] == nil { rawTool = "type_text" }
                else if object["path"] is String, (object["path"] as? String)?.contains(">") == true { rawTool = "press_menu" }
                else if object["value"] != nil, object["label"] != nil || object["element_index"] != nil { rawTool = "set_value" }
                else if object["label"] != nil || object["element_index"] != nil { rawTool = "click" }
            }
            guard let rawTool, !rawTool.isEmpty else {
                throw ComputerUseError.invalidArguments("step \(number) needs a tool, e.g. {\"tool\": \"click\", ...}")
            }

            // "form" / "fill_form", or "fill" with fields, is the whole-form macro; a plain "fill" stays an
            // alias of set_value for one field.
            let lowered = rawTool.lowercased()
            if ["form", "fill_form"].contains(lowered) || (lowered == "fill" && arguments["fields"] != nil) {
                return try expandFill(arguments, number: number, defaultApp: defaultApp, known: known)
            }

            // {"tool": "select", "web": true, ...}: a browser action named as the tool. Browser-only names
            // (select, check, hover, go, ...) always mean the browser; shared ones (click, type, read) only with web.
            let browserOnly: Set<String> = ["select", "check", "uncheck", "hover", "go", "goto", "navigate", "back",
                                            "forward", "reload", "wait_for", "tabs", "use_tab", "upload", "peek"]
            let browserShared: Set<String> = ["click", "type", "key", "read", "hover", "scroll", "wait", "open", "screenshot"]
            let isWeb = (arguments["web"] as? Bool) == true || (arguments["web"] as? String)?.lowercased() == "true"
            // With "web": true, the native names a model reaches for mean the browser action of the same job. Without
            // this, {"tool": "type_text", "web": true} would type into the app named, which may be the user's own Chrome.
            let webSpellings = ["type_text": "type", "press_key": "key", "get_app_state": "read"]
            let browserName = isWeb ? (webSpellings[lowered] ?? lowered) : lowered
            if known.contains("browser"), lowered != "browser",
               browserOnly.contains(lowered) || (isWeb && browserShared.contains(browserName)) {
                arguments["web"] = nil
                if arguments["action"] == nil {
                    arguments["action"] = ["goto": "go", "navigate": "go"][browserName] ?? browserName
                }
                arguments["app"] = nil
                return [Step(tool: "browser", arguments: arguments)]
            }

            let tool = canonicalToolName(rawTool)
            switch rawTool.lowercased() {
            case "double_click", "doubleclick": arguments["click_count"] = arguments["click_count"] ?? 2
            case "right_click", "rightclick": arguments["mouse_button"] = arguments["mouse_button"] ?? "right"
            default: break
            }
            // press_menu with {"menu": "Go", "item": "Go to Folder…"} names the path in two parts.
            if tool == "press_menu", arguments["path"] == nil {
                let parts = [arguments["menu"], arguments["item"], arguments["submenu"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                if !parts.isEmpty { arguments["path"] = parts.joined(separator: " > ") }
                if parts.isEmpty, let label = arguments["label"] as? String { arguments["path"] = label }
                for key in ["menu", "item", "submenu"] { arguments.removeValue(forKey: key) }
            }
            // {"tool": "wait", "seconds": 1}: a plain pause is a settle wait.
            if tool == waitName, arguments["window"] == nil, arguments["text"] == nil, arguments["gone"] == nil, arguments["settle"] == nil {
                if let seconds = (arguments["seconds"] as? Double) ?? (arguments["seconds"] as? Int).map(Double.init) {
                    arguments["timeout_ms"] = Int(seconds * 1000)
                }
                arguments["settle"] = true
                arguments.removeValue(forKey: "seconds")
            }
            guard tool != name else {
                throw ComputerUseError.invalidArguments("step \(number): a batch cannot contain another batch")
            }
            if tool == waitName {
                // Not an app tool: the batch itself polls the app's state (see BatchEffects.Wait).
                _ = try BatchEffects.Wait(arguments: arguments)
                if arguments["app"] == nil, let defaultApp { arguments["app"] = defaultApp }
                return [Step(tool: tool, arguments: arguments)]
            }
            guard known.contains(tool) else {
                throw ComputerUseError.invalidArguments(
                    "step \(number): unknown tool '\(rawTool)'. Use one of: \(known.sorted().joined(separator: ", "))"
                )
            }

            if arguments["app"] == nil, let defaultApp {
                arguments["app"] = defaultApp
            }
            return [Step(tool: tool, arguments: arguments)]
        }
        guard expanded.count <= maxSteps else {
            throw ComputerUseError.invalidArguments(
                "these steps expand to \(expanded.count) actions; at most \(maxSteps) per batch, so split the work"
            )
        }
        return expanded
    }

    /// `{"tool": "fill", "fields": {"To": "sam@x.com", "Subject": "Hi"}, "submit": "Send"}` becomes one
    /// set_value per field (by label) plus a click on `submit`. With `"web": true` it becomes browser
    /// type steps and a browser click instead. `fields` may also be an ordered list of
    /// {"label": ..., "value": ...}; an object's fields are filled in alphabetical order.
    static func expandFill(_ arguments: [String: Any], number: Int, defaultApp: String?, known: Set<String>) throws -> [Step] {
        var pairs: [(label: String, value: String)] = []
        if let list = arguments["fields"] as? [Any] {
            for entry in list {
                guard let field = entry as? [String: Any],
                      let label = (field["label"] ?? field["field"] ?? field["name"]) as? String, !label.isEmpty
                else {
                    throw ComputerUseError.invalidArguments("step \(number): each fill field needs a label and a value")
                }
                guard let value = field["value"], !(value is NSNull) else {
                    throw ComputerUseError.invalidArguments("step \(number): fill field '\(label)' needs a value (use \"\" to clear it)")
                }
                pairs.append((label, "\(value)"))
            }
        } else if let object = arguments["fields"] as? [String: Any] {
            for label in object.keys.sorted() {
                pairs.append((label, object[label].map { "\($0)" } ?? ""))
            }
        }
        guard !pairs.isEmpty else {
            throw ComputerUseError.invalidArguments(
                "step \(number): fill needs fields, e.g. {\"tool\": \"fill\", \"fields\": {\"To\": \"sam@x.com\"}, \"submit\": \"Send\"}"
            )
        }

        let web = (arguments["web"] as? Bool) == true || (arguments["browser"] as? Bool) == true
        if web, !known.contains("browser") {
            throw ComputerUseError.invalidArguments("step \(number): web fill needs the browser tool, which is not available")
        }
        let app = (arguments["app"] as? String) ?? defaultApp
        func appScoped(_ base: [String: Any]) -> [String: Any] {
            var scoped = base
            if let app { scoped["app"] = app }
            return scoped
        }

        var steps: [Step] = pairs.map { pair in
            web
                ? Step(tool: "browser", arguments: ["action": "type", "label": pair.label, "text": pair.value])
                : Step(tool: "set_value", arguments: appScoped(["label": pair.label, "value": pair.value]))
        }
        if let submit = arguments["submit"] as? String, !submit.isEmpty {
            steps.append(web
                ? Step(tool: "browser", arguments: ["action": "click", "label": submit])
                : Step(tool: "click", arguments: appScoped(["label": submit])))
        }
        return steps
    }

    /// `click "Send"`, `type_text "running late"`, `press_key Return`, `scroll #12 down`.
    static func describe(_ step: Step) -> String {
        if step.tool == waitName, let wait = try? BatchEffects.Wait(arguments: step.arguments) {
            return "wait " + wait.summary
        }
        var parts = [step.tool]
        let arguments = step.arguments
        if step.tool == "browser", let action = arguments["action"] as? String {
            parts.append(action)
            if let url = arguments["url"] as? String { parts.append(url) }
        }
        if let label = arguments["label"] as? String {
            parts.append(quoted(label))
        } else if let labels = arguments["labels"] as? [String], !labels.isEmpty {
            parts.append(quoted(labels.joined(separator: " / ")))
        } else if let index = normalizedElementIndexArgument(arguments["element_index"]) {
            parts.append("#\(index)")
        } else if let x = arguments["x"], let y = arguments["y"] {
            parts.append("at \(x),\(y)")
        }
        if let key = arguments["key"] as? String { parts.append(key) }
        if let text = arguments["text"] as? String { parts.append(quoted(text)) }
        if let value = arguments["value"] as? String { parts.append("= " + quoted(value)) }
        if let direction = arguments["direction"] as? String { parts.append(direction) }
        return parts.joined(separator: " ")
    }

    /// The observation's state text, without settle notes ("Settled: ... (waited N ms)") whose numbers
    /// change on every read and would make an unchanged screen look changed.
    static func stateText(of observation: ToolCallResult) -> String {
        stateText(ofText: observation.textContent)
    }

    static func stateText(ofText text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("Settled:") && !$0.hasPrefix("Not settled:") && !$0.hasPrefix("Settle skipped:") }
            .joined(separator: "\n")
    }

    /// Whether any step targets an element by number or by coordinates (these go stale between reads,
    /// so such steps are not saved as recipes).
    static func usesPositionalTargets(_ steps: [Step]) -> Bool {
        steps.contains { step in
            ["element_index", "index", "x", "y", "from_x", "from_y", "to_x", "to_y"].contains { step.arguments[$0] != nil }
        }
    }

    static func firstLine(_ text: String, limit: Int = 300) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "no details"
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    static func clipped(_ text: String, limit: Int = 2_000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (cut; use query for more)" : text
    }

    private static func quoted(_ text: String) -> String {
        let short = text.count > 40 ? String(text.prefix(40)) + "…" : text
        return "\"\(short)\""
    }
}

/// Defaults that keep each reply small enough for weak models. Each one can be switched back.
enum LeanDefaults {
    /// get_app_state returns a screenshot only when asked (`include_screenshot: true`): the numbered
    /// element list is usually enough and a screenshot costs far more tokens.
    /// `OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT=1` restores a screenshot on every read.
    static let includeScreenshot: Bool = {
        let value = GodspeedSettings.environment["OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "0"
        return ["1", "true", "yes", "on"].contains(value)
    }()

    /// How long a batch's final look waits while the window shows a busy sign (spinner, page loading).
    /// A window showing none is read at once.
    static let batchSettleMs = 1_500
}

/// Remembers the last observation per app so a batch that changed nothing can say so.
final class BatchObservationMemory: @unchecked Sendable {
    /// Per agent (see `ClientScope`): "unchanged since your last batch" and failure counts are this agent's own.
    static var shared: BatchObservationMemory { scoped.current }
    private static let scoped = ScopedStore<BatchObservationMemory>(make: { _ in BatchObservationMemory() })

    private let lock = NSLock()
    private var lastObservationHash: [String: Int] = [:]
    private var lastStateText: [String: String] = [:]

    /// The last full state text the model saw for `app` (set by top-level reads and batch replies).
    func shownText(app: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastStateText[app.lowercased()]
    }

    /// Records the full state text the model was shown for `app`.
    func recordShown(app: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        lastStateText[app.lowercased()] = text
    }
    private var failures: [String: (step: String, count: Int)] = [:]

    /// Stores `hash` for `app` and returns the hash stored before it.
    func exchange(app: String, hash: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let previous = lastObservationHash[app]
        lastObservationHash[app] = hash
        return previous
    }

    /// Records how a batch on `app` ended and returns how many batches in a row failed on this same
    /// step (1 for a first failure, 0 when the batch succeeded).
    func recordOutcome(app: String, failedStep: String?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let failedStep else {
            failures[app] = nil
            return 0
        }
        let count = failures[app]?.step == failedStep ? (failures[app]?.count ?? 0) + 1 : 1
        failures[app] = (failedStep, count)
        return count
    }
}

extension ComputerUseToolDispatcher {
    /// Whether a step opens a dialog or editor that only takes input while its app is in front: a
    /// press_menu of such an item (Save, Export, New Folder, a title ending "…"), or a command chord that
    /// presses one.
    func stepOpensDialog(_ step: BatchTool.Step, pid: pid_t) -> Bool {
        if step.tool == "press_menu" {
            if let path = step.arguments["path"] as? String, let titles = try? menuPathTitles(path) {
                return FocusBorrow.menuPathOpensDialog(titles)
            }
            if let titles = step.arguments["path"] as? [String] {
                return FocusBorrow.menuPathOpensDialog(titles)
            }
            return false
        }
        if step.tool == "press_key", let key = step.arguments["key"] as? String, let title = FocusBorrow.menuTitle(forKey: key, pid: pid) {
            return FocusBorrow.menuTitleOpensDialog(title)
        }
        return false
    }

    func runBatch(arguments: [String: Any]) throws -> ToolCallResult {
        let defaultApp = (arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let wantsScreenshot = (arguments["screenshot"] as? Bool) ?? false
        let goal = (arguments["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let foreground = (arguments["foreground"] as? Bool) ?? false
        // Parsed first: a malformed done_when fails the call before any step runs.
        let doneConditions = try DoneCheck.parse(arguments["done_when"])

        var lines: [String] = []
        // Focus borrowed for this batch: whole-batch (foreground: true) or per dialog step (see FocusBorrow).
        let focus = FocusBorrowSession()
        defer { focus.close() }
        if foreground, !FocusBorrow.isEnabled {
            lines.append("Focus borrowing is off (OPEN_COMPUTER_USE_FOCUS_BORROW=0), so these steps ran in the background.")
        }

        // Recipe bookkeeping for this batch (BatchRecipes.Run): values, locators, auto-save.
        let recipeRun = BatchRecipes.Run(goal: goal, values: arguments["values"], app: defaultApp) { [self] app in
            LeanOutput.stateText(of: callToolAsResult(name: "get_app_state", arguments: ["app": app, "include_screenshot": NSNumber(value: false)]))
        }
        recipeRun.doneWhen = doneConditions
        // A goal with no steps replays the recipe saved for it.
        var rawSteps = arguments["steps"]
        var replayed: BatchRecipes.Recipe?
        let givenSteps = (rawSteps as? [Any]) ?? []
        if givenSteps.isEmpty, !goal.isEmpty, BatchRecipes.isEnabled {
            guard let recipe = recipeRun.find(app: defaultApp) else {
                // No steps and no recipe, but an app: the model wants to look. Read it instead of failing a turn.
                if let app = defaultApp {
                    let state = callToolAsResult(name: "get_app_state", arguments: ["app": app])
                    return ToolCallResult(
                        content: [.text("No steps and no saved recipe for \"\(goal)\", so this is the app's current state.")] + state.content,
                        isError: state.isError,
                        batchReceipt: .init(
                            totalSteps: 0, observation: state.isError ? .failed : .returned,
                            doneCheck: doneConditions.isEmpty ? .notRequested : .skipped
                        ),
                        failureCode: state.failureCode
                    )
                }
                throw ComputerUseError.invalidArguments(
                    "no saved recipe for \"\(goal)\"; send the steps (add remember: true to save them once they work)"
                )
            }
            replayed = recipe
            rawSteps = recipeRun.replaySteps(recipe)
            lines.append("Replaying the saved recipe for \"\(recipe.goal)\" (\(recipe.steps.count) steps, used \(recipe.uses) times).")
        }
        let replayApp = replayed.flatMap { $0.app == "browser" ? nil : $0.app }
        let steps = try BatchTool.parseSteps(rawSteps, defaultApp: defaultApp ?? replayApp)
        var receipt = TrajectoryLog.BatchReceipt(
            totalSteps: steps.count, doneCheck: doneConditions.isEmpty ? .notRequested : .skipped
        )
        func markStepObservation(_ observation: BatchEffects.Receipt) {
            receipt.steps[receipt.steps.count - 1].observation = observation
        }
        var failed = false
        var lastApp = defaultApp ?? replayApp
        var changedSomething = false
        var trailingObservation: ToolCallResult?
        var lastStepText = ""
        var lastResultText = ""
        var usedBrowser = false
        var stepResults: [(step: String, result: String)] = []
        var pageReadTexts: [String] = []
        // One batch holds the shared agent, so other agents wait for it; a batch that runs long is cut short
        // between steps and says which steps are left.
        let startedAt = Date()
        var stoppedForTime = false

        // Per-step effects and window continuity (BatchEffects). One extra read of the app per mutating step,
        // switched off for the batch when the app reads slowly or with effects: false.
        let effectsOn = BatchEffects.isEnabled && ((arguments["effects"] as? Bool) ?? true)
        var effectsDisabled = false
        var watchApp: String?
        var watchState: String?
        var boundWindow: BatchEffects.WindowSig?
        var movedTo: String?
        var goneReported = Set<Int>()
        var pendingLastEffect: (app: String, before: String, position: Int, line: Int, tool: String)?
        var failureReceipt: BatchEffects.Receipt?
        var failedNumber = 0
        // Time spent on effect reads (not waits). Past this the rest of the batch runs without them, so a
        // slow app cannot turn a 10-step batch into a minute of bookkeeping.
        var effectSeconds = 0.0
        let effectBudgetSeconds = 8.0

        func windowID(_ app: String) -> UInt32? {
            (try? AppDiscovery.resolveRunning(app)).flatMap { ElementNumbering.forApp(pid: $0.pid).currentWindowID }
        }
        func readWatch(_ app: String, settleMs: Int) -> (text: String, sig: BatchEffects.WindowSig, seconds: Double)? {
            let began = Date()
            var readArguments: [String: Any] = ["app": app, "include_screenshot": NSNumber(value: false)]
            if settleMs > 0 { readArguments["settle_ms"] = settleMs }
            let read = callToolAsResult(name: "get_app_state", arguments: readArguments)
            guard !read.isError, let text = LeanOutput.stateText(of: read) else { return nil }
            // Seconds net of the settle wait asked for: only a slow read of the app counts toward the 2.5 s cutoff.
            let total = Date().timeIntervalSince(began)
            effectSeconds += total
            let slow = max(0, total - Double(settleMs) / 1000)
            return (text, BatchEffects.windowSig(state: text, id: windowID(app)), slow)
        }
        /// Effect and window lines for a step that took `before` to `after`; follows a dialog, remembers a move.
        /// `noEffect` is true when the step should have changed something and nothing visible did: the step
        /// line then ends with "no effect seen" instead of a separate "no visible change" line.
        func effectLines(before: String, after: String, sig: BatchEffects.WindowSig, tool: String) -> (lines: [String], noEffect: Bool) {
            var raw = BatchEffects.effectLines(before: before, after: after, reportedGone: &goneReported)
            let noEffect = BatchEffects.sawNoChange(raw) && BatchEffects.expectsVisibleChange(tool: tool)
            if noEffect { raw = [] }
            var result = raw.map { "   " + $0 }
            if let bound = boundWindow {
                switch BatchEffects.compare(bound: bound, now: sig) {
                case .same:
                    movedTo = nil
                case .dialog(let note):
                    result.append("   " + note)
                    boundWindow = sig
                    movedTo = nil
                case .moved(let title):
                    movedTo = title
                    result.append("   windows: now \"\(title)\", not the window this batch started in")
                }
            }
            return (result, noEffect)
        }

        for (offset, plannedStep) in steps.enumerated() {
            let number = offset + 1
            let step = recipeRun.prepared(plannedStep, number: number, before: watchState)
            if offset > 0, Date().timeIntervalSince(startedAt) > BatchTool.timeBudget {
                lines.append("Stopped after \(Int(BatchTool.timeBudget)) seconds, before step \(number). Steps \(number)-\(steps.count) were not run; send them in a new batch.")
                stoppedForTime = true
                receipt.stop = .timeBudget
                break
            }
            if step.tool == "browser" {
                // Browser steps act on the agent's own background tab; the batch reads that tab back.
                usedBrowser = true
            } else if let app = step.arguments["app"] as? String, !app.isEmpty {
                lastApp = app
            }

            if step.tool == BatchTool.waitName {
                let app = (step.arguments["app"] as? String) ?? lastApp
                lastStepText = BatchTool.describe(step)
                trailingObservation = nil
                guard let app, !app.isEmpty, var wait = try? BatchEffects.Wait(arguments: step.arguments) else {
                    lines.append("\(number). \(lastStepText): FAILED: wait needs an app (pass app on the batch or the step)")
                    stepResults.append((lastStepText, "FAILED: no app"))
                    lastResultText = "failed: wait needs an app"
                    failed = true
                    failedNumber = number
                    receipt.steps.append(.init(failureCode: .invalidArguments, observation: .notSent))
                    receipt.stop = .stepFailure
                    break
                }
                let waitStart = Date()
                let effectSecondsBeforeWait = effectSeconds
                defer { effectSeconds = effectSecondsBeforeWait }
                // Never past the batch's own time budget: three 30 s waits must not run 90 s.
                let limit = wait.pollSeconds(elapsedInBatch: Date().timeIntervalSince(startedAt), budget: BatchTool.timeBudget)
                let budgetCut = limit < Double(wait.timeoutMs) / 1000
                var met = false
                while true {
                    if let read = readWatch(app, settleMs: 0) {
                        if wait.isMet(state: read.text, id: read.sig.id) {
                            met = true
                            watchApp = app
                            watchState = read.text
                            if case .window = wait.kind { boundWindow = read.sig; movedTo = nil }
                            else if boundWindow == nil { boundWindow = read.sig }
                            break
                        }
                    }
                    if Date().timeIntervalSince(waitStart) >= limit { break }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                let waited = Int(Date().timeIntervalSince(waitStart) * 1000)
                // A settle wait is only a pause: a screen that keeps moving (an animation, a clock) is not a failure.
                if !met, wait.timeoutReason == "the screen kept changing", !budgetCut {
                    lines.append("\(number). \(lastStepText): ok (waited \(waited) ms; the screen was still changing)")
                    lastResultText = "ok"
                    stepResults.append((lastStepText, "ok"))
                    receipt.steps.append(.init())
                    continue
                }
                if met {
                    lines.append("\(number). \(lastStepText): ok (\(waited) ms)")
                    lastResultText = "ok"
                    stepResults.append((lastStepText, "ok"))
                    receipt.steps.append(.init())
                    continue
                }
                let reason = "timed out after \(waited) ms: \(wait.timeoutReason)" + (budgetCut ? " (the batch's \(Int(BatchTool.timeBudget)) s time budget was nearly used up)" : "")
                lines.append("\(number). \(lastStepText): FAILED: \(reason)")
                if number < steps.count { lines.append("Steps \(number + 1)-\(steps.count) were not run.") }
                lastResultText = "failed: \(reason)"
                stepResults.append((lastStepText, "FAILED: \(reason)"))
                failed = true
                failedNumber = number
                receipt.steps.append(.init(failureCode: .timeout))
                receipt.stop = .stepFailure
                break
            }

            let isMutating = step.tool != "browser" && !BatchTool.readOnlyTools.contains(step.tool)
            let stepApp = (step.arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // The batch's numbers belong to the window it started in: stop before an element step that
            // would act on another window (a dialog the previous step opened itself is followed, not a stop).
            if let title = movedTo, normalizedElementIndexArgument(step.arguments["element_index"]) != nil {
                lines.append("window changed after \(offset) steps (now \"\(title)\"). Steps \(number)-\(steps.count) were not run; read the app with get_app_state and send them again.")
                stoppedForTime = true
                receipt.stop = .windowChanged
                break
            }
            if effectsOn, !effectsDisabled, isMutating, let app = stepApp, watchApp != app || watchState == nil {
                // First look at this app in the batch: what steps are compared against.
                if let read = readWatch(app, settleMs: 0) {
                    watchApp = app
                    watchState = read.text
                    boundWindow = read.sig
                    movedTo = nil
                    goneReported = []
                    if read.seconds > 2.5 || effectSeconds > effectBudgetSeconds { effectsDisabled = true }
                }
            }

            // Bring the app forward for the whole batch (foreground: true), or from the first step that opens
            // a dialog or editor on. The borrow stays until the batch's final read (see FocusBorrowSession).
            if step.tool != "browser", FocusBorrow.isEnabled,
               let app = step.arguments["app"] as? String, !app.isEmpty,
               let pid = (try? AppDiscovery.resolveRunning(app))?.pid,
               foreground || stepOpensDialog(step, pid: pid) || BatchTool.dialogWasShown(app: app) {
                if !focus.ensure(pid: pid) {
                    lines.append("Could not bring \(app) to the front; the steps below ran in the background.")
                }
            }

            trailingObservation = nil
            // Notes a step collects (a dialog that opened, a Cancel press, an element that moved) are kept here,
            // so the batch reply shows them. A step's own result alone would drop them.
            let stepLog = SmartLog()
            let result = callStepAsResult(name: step.tool, arguments: step.arguments, log: stepLog, notesInResult: false)
            let stepNotes = stepLog.notes
            lastStepText = BatchTool.describe(step)
            if result.isError {
                lastResultText = "failed: \(BatchTool.firstLine(result.textContent))"
                stepResults.append((BatchTool.describe(step), "FAILED: \(BatchTool.firstLine(result.textContent))"))
                // Never retried here: a failure that may have reached the app says "outcome unknown".
                failureReceipt = BatchEffects.failureReceipt(result.textContent)
                receipt.steps.append(.init(
                    failureCode: result.failureCode ?? TrajectoryLog.failureCode(message: result.textContent),
                    observation: failureReceipt
                ))
                receipt.stop = .stepFailure
                failedNumber = number
                lines.append(BatchEffects.line(
                    "\(number). \(BatchTool.describe(step)): FAILED: \(BatchTool.firstLine(result.textContent))",
                    receipt: failureReceipt
                ))
                lines += stepNotes
                if number < steps.count {
                    lines.append("Steps \(number + 1)-\(steps.count) were not run.")
                }
                failed = true
                break
            }

            lastResultText = "ok"
            receipt.steps.append(.init())
            stepResults.append((BatchTool.describe(step), "ok"))
            let browserAction = ((step.arguments["action"] as? String) ?? "").lowercased()
            let readsOnly = BatchTool.readOnlyTools.contains(step.tool)
                || (step.tool == "browser" && ["read", "state", "look", "snapshot", "info", "tabs", "wait", "peek"].contains(browserAction))
            if !readsOnly {
                changedSomething = true
            }

            let isPageRead = step.tool == "browser" && ["read", "state", "look", "snapshot"]
                .contains(((step.arguments["action"] as? String) ?? "").lowercased())
            let isLastStep = offset == steps.count - 1
            let stepLineIndex = lines.count
            if BatchTool.informationalTools.contains(step.tool) { pageReadTexts.append(result.textContent) }
            if BatchTool.informationalTools.contains(step.tool), !isPageRead || !isLastStep {
                // A page read in the middle of a batch keeps its numbered list; the last one becomes the state.
                lines.append("\(number). \(BatchTool.describe(step)): ok\n\(BatchTool.clipped(result.textContent))")
            } else {
                lines.append("\(number). \(BatchTool.describe(step)): ok")
            }
            lines += stepNotes

            // What this step changed. The last step is judged against the final read below.
            if effectsOn, !effectsDisabled, isMutating, let app = stepApp, watchApp == app, let before = watchState {
                if isLastStep {
                    pendingLastEffect = (app, before, lines.count, stepLineIndex, step.tool)
                } else if let read = readWatch(app, settleMs: 600) {
                    let effect = effectLines(before: before, after: read.text, sig: read.sig, tool: step.tool)
                    if effect.noEffect {
                        lines[stepLineIndex] = BatchEffects.line(lines[stepLineIndex], receipt: .noEffectSeen)
                        markStepObservation(.noEffectSeen)
                    }
                    lines += effect.lines
                    watchState = read.text
                    if read.seconds > 2.5 || effectSeconds > effectBudgetSeconds {
                        effectsDisabled = true
                        lines.append("   (effects off for the rest of this batch: the app reads slowly)")
                    }
                } else {
                    // The step ran, but the check read failed or timed out, so its result is not known.
                    lines[stepLineIndex] = BatchEffects.line(lines[stepLineIndex], receipt: .outcomeUnknown)
                    markStepObservation(.outcomeUnknown)
                }
            } else if step.tool == "get_app_state", effectsOn, let app = stepApp, let text = LeanOutput.stateText(of: result) {
                // An explicit read: the model now knows this window, so it is the one to stay in.
                watchApp = app
                watchState = text
                boundWindow = BatchEffects.windowSig(state: text, id: windowID(app))
                movedTo = nil
            }

            // A batch that ends with a read reuses it as its final state.
            trailingObservation = step.tool == "get_app_state" || isPageRead ? result : nil
            if let stop = recipeRun.verify(number: number, total: steps.count, lines: lines) {
                lines.append(stop)
                failed = true
                receipt.stop = .recipeVerification
                break
            }
        }

        // A menu command or shortcut often opens a sheet or dialog that takes a moment to appear; give it
        // that moment before the final read, so the model sees the dialog instead of the old window.
        if !failed, trailingObservation == nil, let last = steps.last,
           last.tool == "press_menu" || (last.tool == "press_key" && ((last.arguments["key"] as? String) ?? "").lowercased().contains("+")) {
            Thread.sleep(forTimeInterval: 0.35)
        }

        // One fresh look at the app after the steps (reuse a get_app_state the batch ended with).
        var observation = trailingObservation
        if observation == nil, usedBrowser, lastApp == nil || steps.last?.tool == "browser" {
            observation = callToolAsResult(name: "browser", arguments: ["action": "read"])
        }
        // A batch that ends in the browser is remembered as the browser's, not as an app it also used earlier:
        // otherwise the page text would become that app's "last shown" state and skew the next app read.
        if steps.last?.tool == "browser" { lastApp = "browser" }
        if observation == nil, let lastApp {
            observation = callToolAsResult(
                name: "get_app_state",
                arguments: [
                    "app": lastApp,
                    "include_screenshot": NSNumber(value: wantsScreenshot),
                    "settle_ms": LeanDefaults.batchSettleMs,
                ]
            )
        }

        // The final read is taken: give focus back before anything slower (done checks, the checker model).
        focus.close()

        if let pending = pendingLastEffect, !failed {
            if let observation, !observation.isError, let text = LeanOutput.stateText(of: observation) {
                let sig = BatchEffects.windowSig(state: text, id: windowID(pending.app))
                let effect = effectLines(before: pending.before, after: text, sig: sig, tool: pending.tool)
                if effect.noEffect, pending.line < lines.count {
                    lines[pending.line] = BatchEffects.line(lines[pending.line], receipt: .noEffectSeen)
                    markStepObservation(.noEffectSeen)
                }
                lines.insert(contentsOf: effect.lines, at: min(pending.position, lines.count))
            } else if pending.line < lines.count {
                lines[pending.line] = BatchEffects.line(lines[pending.line], receipt: .outcomeUnknown)
                markStepObservation(.outcomeUnknown)
            }
        }

        if failed {
            lines.append(BatchEffects.advice(for: failureReceipt, stepNumber: failedNumber))
        }

        var unchanged = false
        var screenChanged = true
        var repeatedFailures = 0
        // Memory key: the app, or "browser" for a batch that only drove the agent's page.
        let memoryKey = lastApp ?? (usedBrowser ? "browser" : nil)
        if let memoryKey {
            repeatedFailures = BatchObservationMemory.shared.recordOutcome(app: memoryKey, failedStep: failed ? lastStepText : nil)
            if repeatedFailures > 1 {
                lastResultText += " (attempt \(repeatedFailures))"
            }
        }
        // What the model saw after the previous batch on this app (read before this reply replaces it).
        let previousShown = memoryKey.flatMap { BatchObservationMemory.shared.shownText(app: $0) }
        if let observation, let memoryKey, !observation.isError {
            let stateHash = BatchTool.stateText(of: observation).hashValue
            let previous = BatchObservationMemory.shared.exchange(app: memoryKey, hash: stateHash)
            screenChanged = previous != stateHash
            unchanged = changedSomething && previous == stateHash
        }

        // Stuck by rule: no model needed. One line says so.
        let stuckLine = StuckRules.line(
            repeatedFailures: repeatedFailures,
            failedStep: failed ? lastStepText : nil,
            appLookedIdentical: unchanged
        )
        if let stuckLine { lines.append(stuckLine) }

        // Done by check: each done_when condition is tested directly. A verified goal needs no model.
        var verifiedDone = false
        // A failed batch is not checked: "gone" and "file exists" can be true without these steps having worked.
        if !doneConditions.isEmpty, !failed, !stoppedForTime {
            let browserUsed = usedBrowser
            let evidence = DoneCheck.Evidence(
                screenText: (observation.map { BatchTool.stateText(of: $0) } ?? "") + "\n" + pageReadTexts.joined(separator: "\n"),
                pageURL: { [self] in
                    guard browserUsed else { return nil }
                    return callToolAsResult(name: "browser", arguments: ["action": "info"]).textContent
                }
            )
            let doneResult = DoneCheck.check(doneConditions, evidence: evidence)
            if case .verified = doneResult { verifiedDone = true }
            receipt.doneCheck = verifiedDone ? .verified : .unmet
            lines.append(DoneCheck.line(for: doneResult))
        }

        var refereeSaysDone = false
        // Optional referee: asked only when neither the done check nor the stuck rules decided. It gets a
        // short summary (goal, steps, repeats, screen change, dialog, changed lines), not the raw screen.
        if Referee.isEnabled, !goal.isEmpty, !verifiedDone, stuckLine == nil, let observation, !observation.isError {
            let state = LeanOutput.stateText(of: observation) ?? observation.textContent
            let changes = previousShown.flatMap { AXStateDiff.diff(previous: $0, current: state) }
            let summary = RefereeSummary.build(
                goal: goal,
                steps: stepResults,
                repeatedFailures: repeatedFailures,
                screenChanged: screenChanged,
                dialogOpen: RefereeSummary.dialogOpen(in: state),
                changes: changes,
                screen: RefereeSummary.screen(from: state)
            )
            let result = unchanged ? lastResultText + "; app unchanged since the previous batch" : lastResultText
            if let verdict = Referee.decide(goal: goal, lastStep: lastStepText, result: result, summary: summary) {
                refereeSaysDone = verdict.label == "done" && verdict.confidence >= BatchRecipes.saveConfidence
                if let hint = Referee.hint(for: verdict) {
                    lines.append(hint)
                    receipt.decisionHint = true
                }
            }
        }

        // Recipes: save a verified clean run, record a replay, heal locators (BatchRecipes.Run).
        lines += recipeRun.finish(app: defaultApp ?? lastApp ?? "browser", steps: steps, lines: lines, failed: failed, stopped: stoppedForTime,
                                  remember: arguments["remember"] as? Bool, verifiedDone: verifiedDone, refereeSaysDone: refereeSaysDone)

        // The final read is taken; hand focus back now rather than after the reply is composed.
        focus.close()

        var content: [ToolResultContentItem] = [.text(lines.joined(separator: "\n"))]
        if let observation {
            receipt.observation = observation.isError ? .failed : .returned
            var shown = observation
            if let memoryKey, let current = LeanOutput.stateText(of: observation) {
                // Compare with what the model last saw for this app (a get_app_state or the previous batch),
                // not with reads inside this batch it never saw. After a failure send the full state.
                let previous = BatchObservationMemory.shared.shownText(app: memoryKey)
                if !failed { shown = LeanOutput.diffed(observation, previous: previous) }
                BatchObservationMemory.shared.recordShown(app: memoryKey, text: current)
            }
            content.append(contentsOf: shown.content)
        }
        return ToolCallResult(content: content, isError: failed, batchReceipt: receipt)
    }
}
