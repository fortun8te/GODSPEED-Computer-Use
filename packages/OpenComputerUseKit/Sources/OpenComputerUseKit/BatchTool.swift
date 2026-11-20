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
    static let readOnlyTools: Set<String> = ["query", "list_apps", "get_app_state", "wait_for"]
    private static let readOnlyBrowserActions: Set<String> = [
        "read", "state", "look", "snapshot", "screenshot", "see", "look_at", "location", "info", "page", "page_info",
        "outline", "frames", "read_text", "link_destination", "control_state", "value", "tabs", "list",
        "wait", "wait_load", "wait_for", "peek", "read_many", "open_many",
    ]

    /// The structured receipt still contains every step, including its original number and duration.
    static func compactRepeatedSuccesses(_ lines: [String]) -> [String] {
        var output: [String] = []
        var index = 0
        func hasAttachedNote(after index: Int) -> Bool {
            lines.indices.contains(index + 1) && lines[index + 1].first?.isWhitespace == true
        }
        while index < lines.count {
            let line = lines[index]
            guard !hasAttachedNote(after: index), !line.contains("\n"), line.hasSuffix(": ok"),
                  let separator = line.range(of: ". "),
                  let first = Int(line[..<separator.lowerBound]), (1...maxSteps).contains(first) else {
                output.append(line)
                index += 1
                continue
            }
            let description = line[separator.upperBound...]
            var end = index + 1
            while end < lines.count, !hasAttachedNote(after: end), lines[end] == "\(first + end - index). \(description)" {
                end += 1
            }
            output.append(end == index + 1 ? line : "\(first)–\(first + end - index - 1). \(description)")
            index = end
        }
        return output
    }

    /// Group consecutive successful steps and omit redundant effect details once the goal is verified.
    /// Keep notices, unconfirmed steps and informational results at their original positions.
    static func compactVerifiedLines(_ lines: [String]) -> [String] {
        var output: [String] = []
        var first: Int?
        var last: Int?
        func appendRun() {
            guard let start = first, let end = last else { return }
            output.append(start == end ? "Step \(start) ok" : "Steps \(start)–\(end) ok")
            first = nil
            last = nil
        }
        for line in lines {
            if line.hasPrefix("   effect: ") || line.hasPrefix("   new: ") || line.hasPrefix("   gone: ")
                || line.hasPrefix("   screen changed a lot: ") || line == "   no visible change" { continue }
            if !line.contains("\n"), line.hasSuffix(": ok"), let separator = line.range(of: ". "),
               let number = Int(line[..<separator.lowerBound]), (1...maxSteps).contains(number) {
                if let last, last + 1 != number { appendRun() }
                if first == nil { first = number }
                last = number
                continue
            }
            appendRun()
            output.append(line)
        }
        appendRun()
        return output
    }

    struct Step {
        let tool: String
        let arguments: [String: Any]

        var isReadOnly: Bool {
            let action = (arguments["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return BatchTool.readOnlyTools.contains(tool) || tool == BatchTool.waitName
                || (tool == "browser" && action.map {
                    BatchTool.readOnlyBrowserActions.contains(ComputerUseToolDispatcher.canonicalBrowserAction($0))
                } == true)
                || (tool == "clipboard" && action == "read")
        }
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
                // The form macro sends its own targets and cannot consume a ref.
                _ = try NativeSnapshotRefs.argument(in: arguments, tool: "fill_form")
                return try expandFill(arguments, number: number, defaultApp: defaultApp, known: known)
            }

            // {"tool": "select", "web": true, ...}: a browser action named as the tool. Browser-only names
            // Hover with an app belongs to the native tool.
            let browserOnly: Set<String> = ["select", "check", "uncheck", "go", "goto", "navigate", "back",
                                            "forward", "reload", "tabs", "use_tab", "close_tab", "upload", "peek", "outline", "frames"]
            let browserShared: Set<String> = ["click", "type", "key", "read", "hover", "drag", "gesture", "scroll", "scroll_into_view", "select_text", "wait", "wait_for", "open", "screenshot"]
            let isWeb = (arguments["web"] as? Bool) == true || (arguments["web"] as? String)?.lowercased() == "true"
            // With "web": true, the native names a model reaches for mean the browser action of the same job. Without
            // this, {"tool": "type_text", "web": true} would type into the app named, which may be the user's own Chrome.
            let webSpellings = ["type_text": "type", "press_key": "key", "get_app_state": "read"]
            let browserName = isWeb ? (webSpellings[lowered] ?? lowered) : lowered
            let nativeWait = (arguments["condition"] as? String).flatMap(ControlWait.Condition.init(rawValue:)) != nil
            let tabWait = lowered == "wait_for" && (!nativeWait || (defaultApp == nil && arguments["app"] == nil))
            let tabHover = lowered == "hover" && defaultApp == nil
                && !arguments.keys.contains(where: { ["app", "application", "app_name", "appName", "bundle_id", "bundleId", "target_app", "program", "application_name"].contains($0) })
            // An explicit web step must never fall through to a native app when Chrome is unavailable.
            if lowered != "browser",
               (isWeb && browserShared.contains(browserName)) || (known.contains("browser")
                   && (browserOnly.contains(lowered) || tabHover || tabWait
                       || (lowered == "scroll_into_view" && defaultApp == nil && arguments["app"] == nil))) {
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

    /// Whether any step uses a snapshot index, ref or coordinates (these go stale between reads,
    /// so such steps are not saved as recipes).
    static func usesPositionalTargets(_ steps: [Step]) -> Bool {
        steps.contains { step in
            ["element_index", "index", "ref", "from_index", "to_index", "x", "y", "from_x", "from_y", "to_x", "to_y"].contains { step.arguments[$0] != nil }
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
    static var includeScreenshot: Bool {
        let value = GodspeedSettings.environment["OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "0"
        return ["1", "true", "yes", "on"].contains(value)
    }

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

    /// Records the full diff baseline for the last observation delivered to the model.
    func recordShown(app: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        lastStateText[app.lowercased()] = text
    }

    func clearShown(app: String) {
        lock.lock()
        defer { lock.unlock() }
        lastStateText[app.lowercased()] = nil
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

    func runBatch(arguments: [String: Any], inheritedDeadline: TimeInterval? = nil,
                  validatedHandoffRecipe: BatchRecipes.Recipe? = nil) throws -> ToolCallResult {
        let clock = ProcessInfo.processInfo
        let startedAt = clock.systemUptime
        let startedOnDisk = Date()
        let deadline = min(startedAt + BatchTool.timeBudget, inheritedDeadline ?? .infinity)
        // Leave a small portion of the same budget for recovery and completion evidence.
        let duration = max(0, deadline - startedAt)
        let actionDeadline = deadline - min(3, duration / 10)
        let defaultApp = (arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let wantsScreenshot = (arguments["screenshot"] as? Bool) ?? false
        let goal = (arguments["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let foreground = (arguments["foreground"] as? Bool) ?? false
        let pinnedWindow = try validatedQueryWindowID(arguments["window_id"])
        if pinnedWindow != nil {
            guard defaultApp != nil, !foreground,
                  let steps = arguments["steps"] as? [Any], !steps.isEmpty else {
                throw ComputerUseError.invalidArguments("A window-bound batch requires app and explicit steps, and must run in the background.")
            }
        }
        // Parsed first: a malformed done_when fails the call before any step runs.
        var doneConditions = try DoneCheck.parse(arguments["done_when"])

        var lines: [String] = []
        // Focus borrowed for this batch: whole-batch (foreground: true) or per dialog step (see FocusBorrow).
        let focus = FocusBorrowSession()
        defer { focus.close() }
        if foreground, !FocusBorrow.isEnabled {
            lines.append("Focus borrowing is off. Enable OPEN_COMPUTER_USE_FOCUS_BORROW to use foreground batches.")
        }

        // Preserve a policy refusal if a recipe cannot inspect its saved target.
        var recipeReadRefusal: ToolCallResult?
        let recipeRun = BatchRecipes.Run(goal: goal, values: arguments["values"], app: defaultApp) { [self] app in
            guard clock.systemUptime < actionDeadline else { return nil }
            let result = callToolAsResult(name: "get_app_state", arguments: [
                "app": app, "include_screenshot": NSNumber(value: false),
            ])
            if result.failureCode?.isActionRefusal == true { recipeReadRefusal = result }
            return result.isError ? nil : LeanOutput.stateText(of: result)
        }
        recipeRun.store = recipeStore
        // A goal with no steps replays the recipe saved for it.
        var rawSteps = arguments["steps"]
        var replayed: BatchRecipes.Recipe?
        if (rawSteps == nil || (rawSteps as? [Any])?.isEmpty == true), !goal.isEmpty, BatchRecipes.isEnabled {
            // Both entry points check the current window, version and slots before loading steps.
            let lookup = recipeRun.lookup(app: defaultApp)
            if let recipeReadRefusal { return recipeReadRefusal }
            switch lookup {
            case .blocked(let reason):
                throw ComputerUseError.invalidArguments(reason)
            case .match(let recipe):
                guard !foreground, defaultApp != nil,
                      pinnedWindow == nil || pinnedWindow == recipe.window?.id,
                      validatedHandoffRecipe == nil || validatedHandoffRecipe?.version == recipe.version,
                      doneConditions.isEmpty || doneConditions == recipe.doneWhen else {
                    throw ComputerUseError.invalidArguments("Confirm the original app, background mode and done_when, or provide fresh steps.")
                }
                doneConditions = recipe.doneWhen
                recipeRun.doneWhen = doneConditions
                if let alreadySatisfied = recipeRun.alreadySatisfied() { return alreadySatisfied }
                replayed = recipe
                rawSteps = try recipeRun.replaySteps(recipe)
                lines.append("Replaying the verified recipe for \"\(recipe.goal)\".")
            case .missing:
                // No steps and no recipe, but an app: the model wants to look. Read it instead of failing a turn.
                if let app = defaultApp, clock.systemUptime < deadline {
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
                    "No replay is available. Provide the app and fresh steps with a deterministic done_when."
                )
            }
        }
        recipeRun.doneWhen = doneConditions
        let parsedSteps = try BatchTool.parseSteps(rawSteps, defaultApp: defaultApp)
        if replayed != nil, let defaultApp, !parsedSteps.allSatisfy({ HandoffTool.isSafeRecipeStep($0, app: defaultApp) }) {
            throw ComputerUseError.invalidArguments("Some saved steps need fresh instructions. Read the app and provide explicit steps.")
        }
        let steps = try parsedSteps.map { step in
            guard let pinnedWindow, let defaultApp else { return step }
            var args = step.arguments
            // A wait only reads state. In a window-bound batch it reads the pinned window, so it is safe
            // unless it waits for a different window to appear.
            if step.tool == BatchTool.waitName {
                if args["window"] != nil || BatchEffects.Wait.keyAliases.contains(where: { $0.value == "window" && args[$0.key] != nil }) {
                    throw ComputerUseError.invalidArguments("A window-bound batch cannot wait for another window. Drop window_id to wait for a new window.")
                }
                if let app = args["app"] as? String, app != defaultApp {
                    throw ComputerUseError.invalidArguments("A wait in a window-bound batch reads its own app.")
                }
                args["app"] = defaultApp
                return BatchTool.Step(tool: step.tool, arguments: args)
            }
            guard (args["app"] as? String) == defaultApp,
                  ArgumentNormalizer.windowBoundTools.contains(step.tool) else {
                throw ComputerUseError.invalidArguments("A window-bound batch accepts \(step.tool) only as one of: \(ArgumentNormalizer.windowBoundTools.sorted().joined(separator: ", ")), wait, on \(defaultApp). Drop window_id to use other steps.")
            }
            if let override = try validatedQueryWindowID(args["window_id"]), override != pinnedWindow {
                throw ComputerUseError.invalidArguments("A batch step cannot override the pinned window.")
            }
            args["window_id"] = pinnedWindow
            return BatchTool.Step(tool: step.tool, arguments: args)
        }
        // Check explicit target arguments before any step can change an app or a page.
        for (offset, step) in steps.enumerated() {
            do {
                if step.tool == BatchTool.waitName { _ = try BatchEffects.Wait(arguments: step.arguments) }
                _ = try NativeSnapshotRefs.argument(in: step.arguments, tool: step.tool)
                if try validatedQueryWindowID(step.arguments["window_id"]) != nil,
                   !ArgumentNormalizer.windowBoundTools.contains(step.tool),
                   step.tool != "query", step.tool != "get_app_state" {
                    throw ComputerUseError.invalidArguments("\(step.tool) cannot be bound to a native window")
                }
                if step.tool == "browser" {
                    let tabID = try Self.validatedBrowserTabID(step.arguments["tab_id"])
                    let action = (step.arguments["action"] as? String)?
                        .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                    if ["close_tab", "use_tab", "claim", "claim_tab", "switch"].contains(action), tabID == nil {
                        throw ComputerUseError.invalidArguments("browser \(action) needs an explicit tab_id")
                    }
                }
            } catch let error as ComputerUseError {
                throw ComputerUseError.invalidArguments("step \(offset + 1): \(error.errorDescription ?? String(describing: error))")
            }
        }
        // Ref steps already own an exact observation. Background focus and
        // effect reads must not replace it before the ref can be used.
        let hasPinnedSteps = pinnedWindow != nil || steps.contains { $0.arguments["window_id"] != nil || $0.arguments["ref"] != nil }
        if hasPinnedSteps && foreground {
            throw ComputerUseError.invalidArguments("A window-bound step requires a background batch.")
        }
        // Only a validated, mutating batch with a goal and no deterministic check can ask for a hint.
        let mayUseReferee = Referee.isEnabled && !goal.isEmpty && doneConditions.isEmpty
            && steps.contains { !$0.isReadOnly }
        if mayUseReferee { Referee.warmInBackground() }
        let remember = arguments["remember"] as? Bool
        recipeRun.canSave = !hasPinnedSteps && !BatchTool.usesPositionalTargets(steps)
            && (remember == true || (remember != false && !doneConditions.isEmpty))
            && steps.contains { !BatchTool.readOnlyTools.contains($0.tool) && $0.tool != BatchTool.waitName }
        var receipt = TrajectoryLog.BatchReceipt(
            totalSteps: steps.count, doneCheck: doneConditions.isEmpty ? .notRequested : .skipped
        )
        func markStepObservation(_ observation: BatchEffects.Receipt) {
            receipt.steps[receipt.steps.count - 1].observation = observation
        }
        var failed = false
        var lastApp = defaultApp
        var changedSomething = false
        var trailingObservation: ToolCallResult?
        var browserImages: [ToolResultContentItem] = []
        var lastStepReturnedBrowserImage = false
        var lastStepText = ""
        var lastResultText = ""
        var lastAttemptedStep: BatchTool.Step?
        var lastBrowserContinuationTab: Int?
        var stepResults: [(step: String, result: String)] = []
        // One batch holds the shared agent, so other agents wait for it; a batch that runs long is cut short
        // between steps and says which steps are left.
        var stoppedForTime = false
        func stopIfOutOfTime(before number: Int) -> Bool {
            guard clock.systemUptime >= actionDeadline else { return false }
            lines.append("The action budget elapsed before step \(number). Steps \(number)-\(steps.count) were not run; send them in a new batch.")
            stoppedForTime = true
            receipt.stop = .timeBudget
            return true
        }

        // Preserve existing step rows and report the first step that never ran.
        func stopIfCancelled() -> Bool {
            guard RequestCancellation.requested else { return false }
            if receipt.stop != .cancelled {
                lines.append("Request cancelled.")
                let next = receipt.steps.count + 1
                if next <= steps.count { lines.append("Steps \(next)-\(steps.count) were not run.") }
                receipt.stop = .cancelled
                stoppedForTime = true
            }
            return true
        }

        // Per-step effects and window continuity (BatchEffects). One extra read of the app per mutating step,
        // switched off for the batch when the app reads slowly or with effects: false.
        // An intermediate snapshot must not replace the observation used by a pinned action.
        // Compact by default whenever a done check is given: a verified goal needs no window dump.
        let compactReply = (arguments["compact"] as? Bool) ?? !doneConditions.isEmpty
        let effectsOn = !hasPinnedSteps && BatchEffects.isEnabled && ((arguments["effects"] as? Bool) ?? true)
        var effectBudget = BatchEffects.ReadBudget()
        var watchApp: String?
        var watchState: String?
        var boundWindow: BatchEffects.WindowSig?
        var movedTo: String?
        var goneReported = Set<Int>()
        var pendingLastEffect: (app: String, before: String, position: Int, line: Int, tool: String)?
        var failedNumber = 0
        func windowID(_ app: String) -> UInt32? {
            (try? AppDiscovery.resolveRunning(app)).flatMap { ElementNumbering.forApp(pid: $0.pid).currentWindowID }
        }
        var waitReadRefusal: ToolCallResult?
        func readWatch(_ app: String, settleMs: Int, optionalEffect: Bool = true) -> BatchEffects.Watch? {
            if optionalEffect, effectBudget.exhausted || clock.systemUptime >= actionDeadline { return nil }
            let began = clock.systemUptime
            var readArguments: [String: Any] = ["app": app, "include_screenshot": NSNumber(value: false)]
            if let pinnedWindow = pinnedWindow ?? replayed?.window?.id, app == defaultApp { readArguments["window_id"] = pinnedWindow }
            if settleMs > 0 { readArguments["settle_ms"] = settleMs }
            let read = TimingLog.measure(optionalEffect ? "batch.effect_read" : "batch.wait_read") {
                callToolAsResult(name: "get_app_state", arguments: readArguments)
            }
            if !optionalEffect, read.failureCode?.isActionRefusal == true { waitReadRefusal = read }
            let text = read.isError ? nil : LeanOutput.stateText(of: read)
            if optionalEffect {
                effectBudget.record(seconds: clock.systemUptime - began, settleMs: settleMs, observed: text != nil)
                if effectBudget.exhausted {
                    lines.append("   (optional effect checks paused for the rest of this batch)")
                }
            }
            guard let text else { return nil }
            return .init(text: text, sig: BatchEffects.windowSig(state: text, id: windowID(app)), result: read)
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

        // These private baseline reads leave the caller's window and element references in place.
        let needsTemporalScreen = doneConditions.contains(where: \.needsTemporalScreen)
        let needsTemporalURL = doneConditions.contains(where: \.needsTemporalURL)
        func completionObservation(step: BatchTool.Step?, app: String?, window: UInt32?, tab: Int?) -> BatchCompletion.Observation? {
            guard clock.systemUptime < deadline else { return nil }
            if step?.tool == "browser", needsTemporalScreen || needsTemporalURL {
                return BatchCompletion.browser(tabID: tab, needsText: needsTemporalScreen,
                                               deadline: min(deadline, clock.systemUptime + 4))
            }
            if needsTemporalScreen, let app { return BatchCompletion.native(app: app, windowID: window) }
            return nil
        }
        let completionBaseline: BatchCompletion?
        if doneConditions.contains(where: \.requiresBaseline), clock.systemUptime < actionDeadline {
            let finalStep = steps.last
            let finalApp = steps.reversed().compactMap { $0.arguments["app"] as? String }.first ?? lastApp
            let window = replayed?.window?.id ?? pinnedWindow ?? (try? validatedQueryWindowID(finalStep?.arguments["window_id"]))
                ?? finalStep.flatMap { observedNativeRefWindow(in: $0.arguments) }
            let tab = try? Self.validatedBrowserTabID(finalStep?.arguments["tab_id"])
            let before = completionObservation(step: finalStep, app: finalApp, window: window, tab: tab)
            completionBaseline = BatchCompletion(conditions: doneConditions, startedAt: startedOnDisk, before: before)
        } else {
            completionBaseline = nil
        }

        for (offset, plannedStep) in steps.enumerated() {
            let number = offset + 1
            if stopIfCancelled() || stopIfOutOfTime(before: number) { break }
            if plannedStep.tool == BatchTool.waitName {
                let step = plannedStep
                lastAttemptedStep = step
                if let app = step.arguments["app"] as? String, !app.isEmpty { lastApp = app }
                let app = (step.arguments["app"] as? String) ?? lastApp
                lastStepText = BatchTool.describe(step)
                trailingObservation = nil
                lastStepReturnedBrowserImage = false
                guard let app, !app.isEmpty, var wait = try? BatchEffects.Wait(arguments: step.arguments) else {
                    lines.append("\(number). \(lastStepText): FAILED: wait needs an app (pass app on the batch or the step)")
                    stepResults.append((lastStepText, "FAILED: no app"))
                    lastResultText = "failed: wait needs an app"
                    failed = true
                    failedNumber = number
                    receipt.steps.append(.init(failureCode: .invalidArguments, observation: .notSent, deliveryState: .notSent))
                    receipt.stop = .stepFailure
                    break
                }
                waitReadRefusal = nil
                let waitStart = clock.systemUptime
                // Never past the batch's own time budget: three 30 s waits must not run 90 s.
                let limit = wait.pollSeconds(elapsedInBatch: clock.systemUptime - startedAt, budget: actionDeadline - startedAt)
                let budgetCut = limit < Double(wait.timeoutMs) / 1000
                var met = false
                var observed = false
                // Shallow checks can defer an expensive read. Only full state
                // can satisfy the original wait predicate or bind its window.
                let fallbackInterval = BatchEffects.WaitReadGate.fallbackInterval
                let firstFullRead = limit <= fallbackInterval ? waitStart : waitStart + fallbackInterval
                var readGate = BatchEffects.WaitReadGate(nextFullRead: firstFullRead)
                while !RequestCancellation.requested, clock.systemUptime - waitStart < limit {
                    let shouldRead = readGate.shouldRead(at: clock.systemUptime) {
                        TimingLog.measure("batch.wait_readiness") {
                            BatchEffects.waitMayBeReady(wait.kind, app: app, windowID: replayed?.window?.id ?? pinnedWindow)
                        }
                    }
                    if shouldRead, clock.systemUptime - waitStart < limit,
                       let read = readWatch(app, settleMs: 0, optionalEffect: false),
                       replayed == nil || BatchRecipes.Window(state: read.text) == replayed?.window {
                        observed = true
                        let busy = wait.kind == .settle
                            && BatchEffects.waitMayBeReady(.settle, app: app, windowID: read.sig.id) != true
                        if wait.isMet(state: busy ? "" : read.text, id: read.sig.id) {
                            met = true
                            if !wantsScreenshot { trailingObservation = read.result }
                            watchApp = app
                            watchState = read.text
                            if case .window = wait.kind { boundWindow = read.sig; movedTo = nil }
                            else if boundWindow == nil { boundWindow = read.sig }
                            break
                        }
                    }
                    if waitReadRefusal != nil { break }
                    let remaining = limit - (clock.systemUptime - waitStart)
                    if remaining <= 0 { break }
                    Thread.sleep(forTimeInterval: min(0.2, remaining))
                }
                if RequestCancellation.requested {
                    receipt.steps.append(.init(failureCode: .cancelled, observation: .notSent, deliveryState: .notSent))
                    lines.append("\(number). \(lastStepText): cancelled during wait")
                    _ = stopIfCancelled()
                    break
                }
                let waited = Int((clock.systemUptime - waitStart) * 1000)
                if met {
                    lines.append("\(number). \(lastStepText): ok (\(waited) ms)")
                    lastResultText = "ok"
                    stepResults.append((lastStepText, "ok"))
                    receipt.steps.append(.init())
                    continue
                }
                let detail = observed ? wait.timeoutReason : "the app state could not be read"
                let reason = waitReadRefusal?.primaryText
                    ?? "timed out after \(waited) ms: \(detail)" + (budgetCut ? " (the batch action budget was nearly used up)" : "")
                lines.append("\(number). \(lastStepText): FAILED: \(reason)")
                if number < steps.count { lines.append("Steps \(number + 1)-\(steps.count) were not run.") }
                lastResultText = "failed: \(reason)"
                stepResults.append((lastStepText, "FAILED: \(reason)"))
                failed = true
                failedNumber = number
                receipt.steps.append(.init(failureCode: waitReadRefusal?.failureCode ?? .timeout,
                                           observation: waitReadRefusal == nil ? nil : .notSent, deliveryState: .notSent))
                receipt.stop = .stepFailure
                break
            }

            let isMutating = plannedStep.tool != "browser" && !BatchTool.readOnlyTools.contains(plannedStep.tool)
            let stepApp = (plannedStep.arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // The batch's numbers belong to the window it started in: stop before an element step that
            // would act on another window (a dialog the previous step opened itself is followed, not a stop).
            if let title = movedTo, replayed != nil
                || normalizedElementIndexArgument(plannedStep.arguments["element_index"]) != nil {
                lines.append("window changed after \(offset) steps (now \"\(title)\"). Steps \(number)-\(steps.count) were not run; read the app with get_app_state and send them again.")
                stoppedForTime = true
                receipt.stop = .windowChanged
                break
            }
            if effectsOn, !effectBudget.exhausted, isMutating, let app = stepApp, watchApp != app || watchState == nil {
                // First look at this app in the batch: what steps are compared against.
                if let read = readWatch(app, settleMs: 0) {
                    watchApp = app
                    watchState = read.text
                    boundWindow = read.sig
                    movedTo = nil
                    goneReported = []
                }
            }

            // Optional effect reads may be disabled or stale. Replays need their own fresh binding.
            let scoped = replayed != nil
                ? recipeRun.prepareReplay(plannedStep, number: number)
                : recipeRun.prepared(plannedStep, number: number, before: stepApp == watchApp ? watchState : nil)
            guard let step = scoped else {
                lastAttemptedStep = plannedStep
                lastBrowserContinuationTab = nil
                if let stepApp { lastApp = stepApp }
                trailingObservation = nil
                lastStepReturnedBrowserImage = false
                lastStepText = BatchTool.describe(plannedStep)
                let refusal = recipeReadRefusal
                let reason = refusal?.primaryText ?? "the saved target could not be confirmed. Read the app before continuing."
                lastResultText = "failed: \(reason)"
                lines.append("\(number). \(lastStepText): FAILED: \(reason)")
                if number < steps.count { lines.append("Steps \(number + 1)-\(steps.count) were not run.") }
                receipt.steps.append(.init(failureCode: refusal?.failureCode ?? .stateUnavailable,
                                           observation: .notSent, deliveryState: .notSent))
                receipt.stop = refusal == nil ? .recipeVerification : .stepFailure
                failedNumber = number
                failed = true
                break
            }

            if stopIfCancelled() || stopIfOutOfTime(before: number) { break }
            lastAttemptedStep = step
            if step.tool != "browser", let app = step.arguments["app"] as? String, !app.isEmpty {
                lastApp = app
            }
            trailingObservation = nil
            lastStepReturnedBrowserImage = false
            // Notes a step collects (a dialog that opened, a Cancel press, an element that moved) are kept here,
            // so the batch reply shows them. A step's own result alone would drop them.
            let stepLog = SmartLog()
            let previousStep = offset > 0 ? steps[offset - 1] : nil
            let awaitsPathEditor = !hasPinnedSteps && step.tool == "type_text" && stepApp != nil
                && previousStep?.tool == "press_key" && (previousStep?.arguments["app"] as? String) == stepApp
                && (previousStep?.arguments["key"] as? String).map(ComputerUseService.canonicalKey) == "cmd+shift+g"
            let isLastStep = offset == steps.count - 1
            let defersNavigationRead = step.tool == "browser" && isLastStep
            var stepArguments = step.arguments
            if isLastStep, step.tool == "get_app_state", wantsScreenshot {
                stepArguments["include_screenshot"] = true
            }
            // A directly verified AX write can use the next explicit read or
            // the batch's final screenshot read. Other writes keep readback.
            let nextStep = steps.dropFirst(number).first
            let nextReadsSameApp = nextStep?.tool == "get_app_state"
                && (nextStep?.arguments["app"] as? String) == stepApp
                && (nextStep?.arguments["include_ax"] as? Bool) != false
                && nextStep?.arguments["window_id"] == nil
            let deferValueRead = step.tool == "set_value"
                && ((isLastStep && wantsScreenshot) || (!effectsOn && nextReadsSameApp))
            let dispatchStarted = clock.systemUptime
            let result = BrowserCallBudget.withDeadline(actionDeadline) {
                Self.$defersBrowserNavigationObservation.withValue(defersNavigationRead) {
                    Self.$clipsBrowserStepObservation.withValue(step.tool == "browser" && !isLastStep) {
                        ComputerUseService.$awaitsModalTextFocus.withValue(awaitsPathEditor) {
                            ComputerUseService.$defersVerifiedSetValueObservation.withValue(deferValueRead) {
                                callStepAsResult(name: step.tool, arguments: stepArguments, log: stepLog, notesInResult: false) {
                                    // An authorized step may borrow focus. Strict and window-bound steps skip this hook.
                                    guard replayed == nil, validatedHandoffRecipe == nil, !hasPinnedSteps, FocusBorrow.isEnabled,
                                      !ActionOptions.usesStrictRoute(step.tool, step.arguments),  // L9: checked actions never borrow focus
                                          let app = step.arguments["app"] as? String, !app.isEmpty,
                                          let pid = (try? AppDiscovery.resolveRunning(app))?.pid,
                                          foreground || self.stepOpensDialog(step, pid: pid) || BatchTool.dialogWasShown(app: app) else { return }
                                    if !focus.ensure(pid: pid) {
                                        stepLog.note("Could not bring \(app) to the front. The step ran in the background.")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let durationMs = ((clock.systemUptime - dispatchStarted) * 1000).rounded()
            lastBrowserContinuationTab = result.browserContinuationTabID
            if RequestCancellation.requested {
                let delivery = step.isReadOnly ? .notSent : result.deliveryState
                let unknown = delivery == .outcomeUnknown
                receipt.steps.append(.init(failureCode: .cancelled, observation: unknown ? .outcomeUnknown : nil,
                                           durationMs: durationMs, deliveryState: delivery))
                lines.append(BatchEffects.cancelledStepLine(number: number, description: BatchTool.describe(step), delivery: delivery))
                _ = stopIfCancelled()
                break
            }
            let stepNotes = stepLog.notes
            lastStepText = BatchTool.describe(step)
            if result.isError || result.deliveryState == .outcomeUnknown {
                lastResultText = "failed: \(BatchTool.firstLine(result.textContent))"
                stepResults.append((BatchTool.describe(step), "FAILED: \(BatchTool.firstLine(result.textContent))"))
                // Never retried here: a failure that may have reached the app says "outcome unknown".
                let failureReceipt = result.failureCode?.isActionRefusal == true
                    ? .notSent : BatchEffects.failureReceipt(result.deliveryState)
                receipt.steps.append(.init(
                    failureCode: result.failureCode ?? .toolError,
                    observation: failureReceipt, durationMs: durationMs, deliveryState: result.deliveryState
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
            receipt.steps.append(.init(durationMs: durationMs, deliveryState: result.deliveryState))
            stepResults.append((BatchTool.describe(step), "ok"))
            let browserAction = ((step.arguments["action"] as? String) ?? "").lowercased()
            if !step.isReadOnly {
                changedSomething = true
            }

            let isPageRead = step.tool == "browser" && ["read", "state", "look", "snapshot"].contains(browserAction)
            if step.tool == "browser", ["screenshot", "see", "look_at"].contains(browserAction) {
                let images = result.content.filter { $0.dictionary["type"] as? String == "image" }
                if !images.isEmpty {
                    browserImages.append(.text("Browser screenshot from step \(number)."))
                    browserImages.append(contentsOf: images)
                    lastStepReturnedBrowserImage = true
                }
            }
            let stepLineIndex = lines.count
            if BatchTool.informationalTools.contains(step.tool), !isPageRead || !isLastStep {
                // A page read in the middle of a batch keeps its numbered list; the last one becomes the state.
                lines.append("\(number). \(BatchTool.describe(step)): ok\n\(BatchTool.clipped(result.textContent))")
            } else if ActionOptions.usesStrictRoute(step.tool, step.arguments) {
                // Keep the action's own receipt even when general effect reads are disabled.
                lines.append("\(number). \(BatchTool.describe(step)): \(BatchTool.firstLine(result.textContent))")
            } else {
                lines.append("\(number). \(BatchTool.describe(step)): ok")
            }
            lines += stepNotes

            // What this step changed. The last step is judged against the final read below.
            if effectsOn, !effectBudget.exhausted, isMutating, let app = stepApp, watchApp == app, let before = watchState {
                if isLastStep {
                    pendingLastEffect = (app, before, lines.count, stepLineIndex, step.tool)
                } else if let read = BatchEffects.Watch.afterAction(
                    snapshot: stepLog.afterActionSnapshot, before: before, tool: step.tool,
                    fallback: { readWatch(app, settleMs: 600) }
                ) {
                    let effect = effectLines(before: before, after: read.text, sig: read.sig, tool: step.tool)
                    if effect.noEffect {
                        lines[stepLineIndex] = BatchEffects.line(lines[stepLineIndex], receipt: .noEffectSeen)
                        markStepObservation(.noEffectSeen)
                    }
                    lines += effect.lines
                    watchState = read.text
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

            // Smart steps may have a newer observation than the action reply. Menu and keyboard
            // shortcuts still use the final settle path because they can open a delayed dialog.
            if step.tool == "get_app_state" || isPageRead {
                trailingObservation = result
            } else if isLastStep, !hasPinnedSteps, stepApp != nil,
                      ["click", "type_text", "set_value", "scroll"].contains(step.tool),
                      let snapshot = stepLog.afterActionSnapshot, snapshot.observedWindowID != nil,
                      DoneCheck.supportsAbsenceCheck(snapshot.renderedText),
                      !snapshot.renderedText.contains("the app hides its web content"),
                      !wantsScreenshot {
                trailingObservation = LeanOutput.condensed(.text(snapshot.renderedText))
            }
            if let stop = recipeRun.verify(number: number, total: steps.count, lines: lines,
                                           observation: receipt.steps.last?.observation) {
                lines.append(stop)
                failed = true
                receipt.stop = .recipeVerification
                break
            }
        }

        if stopIfCancelled() {
            return ToolCallResult(content: [.text(lines.joined(separator: "\n"))], isError: true, batchReceipt: receipt, deliveryState: receipt.deliveryState)
        }

        // A menu command or shortcut often opens a sheet or dialog that takes a moment to appear; give it
        // that moment before the final read, so the model sees the dialog instead of the old window.
        if !failed, !stoppedForTime, trailingObservation == nil, let last = lastAttemptedStep,
           last.tool == "press_menu" || (last.tool == "press_key" && ((last.arguments["key"] as? String) ?? "").lowercased().contains("+")) {
            let remaining = max(0, deadline - clock.systemUptime)
            if remaining > 0, let app = lastApp, !hasPinnedSteps,
               let pid = (try? AppDiscovery.resolveRunning(app))?.pid, stepOpensDialog(last, pid: pid) {
                // Stop the dialog wait as soon as AX exposes a sheet.
                SmartSteps.waitForDialog(pid: pid, timeout: min(0.35, remaining))
            } else if remaining > 0 {
                Thread.sleep(forTimeInterval: min(0.35, remaining))
            }
        }

        let verificationWindow = replayed?.window?.id ?? pinnedWindow ?? (try? validatedQueryWindowID(lastAttemptedStep?.arguments["window_id"]))
            ?? lastAttemptedStep.flatMap { observedNativeRefWindow(in: $0.arguments) }
        // One fresh look at the app after the steps (reuse a get_app_state the batch ended with).
        let lastBrowserAction = (lastAttemptedStep?.arguments["action"] as? String)?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let lastDelivery = receipt.steps.last?.deliveryState ?? .notSent
        let unconfirmedOpen = failed && lastDelivery == .outcomeUnknown && lastAttemptedStep?.tool == "browser"
            && ["open", "new_tab", "open_tab"].contains(lastBrowserAction ?? "")
        let finalClickChecksPage = lastAttemptedStep?.tool == "browser"
            && ["click", "press", "tap"].contains(lastBrowserAction ?? "")
            && !doneConditions.isEmpty && doneConditions.allSatisfy { condition in
                switch condition {
                case .text, .urlContains, .appeared, .urlChanged: return true
                default: return false
                }
            }
        let unconfirmedFinalClick = finalClickChecksPage && failed && lastDelivery == .outcomeUnknown && failedNumber == steps.count
        let finalBrowserTab: Any? = lastAttemptedStep.flatMap { last in
            guard last.tool == "browser" else { return nil }
            if let lastBrowserContinuationTab { return lastBrowserContinuationTab }
            let action = (last.arguments["action"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
            // Opening creates its own tab, even if a caller also supplied an existing tab ID.
            return ["open", "new_tab", "open_tab"].contains(action ?? "") ? nil : last.arguments["tab_id"]
        }
        func browserVerificationArgs(_ action: String) -> [String: Any] {
            var args: [String: Any] = ["action": action]
            args["tab_id"] = finalBrowserTab
            return args
        }
        // Verification, recovery reads and screenshots share a single tail deadline.
        let browserObservationDeadline = min(deadline, clock.systemUptime + (finalClickChecksPage ? 15 : 8))
        func browserObservation(_ action: String) -> ToolCallResult {
            guard clock.systemUptime < browserObservationDeadline else {
                return .text("Browser observation time expired. Refresh the tab before resuming.", isError: true)
            }
            return BrowserCallBudget.withDeadline(browserObservationDeadline) {
                callToolAsResult(name: "browser", arguments: browserVerificationArgs(action))
            }
        }
        func waitForBrowserEvidence(_ condition: DoneCheck.Condition) -> ToolCallResult? {
            let waitDeadline = min(browserObservationDeadline - 1.5, clock.systemUptime + 6)
            guard waitDeadline - clock.systemUptime > 0.6 else { return nil }
            // A submitted form may still be rendering its confirmation. Give the
            // existing event-based wait a short part of the same recovery budget.
            var args = browserVerificationArgs("wait_for")
            args["timeout"] = 5
            switch condition {
            case .appeared(let text): args["text"] = text
            case .urlChanged(let url): args["url_contains"] = url
            default:
                for (key, value) in condition.arguments { args[key] = value }
            }
            return BrowserCallBudget.withDeadline(waitDeadline) {
                Self.$bindsBrowserWaitEvidence.withValue(true) {
                    let result = callToolAsResult(name: "browser", arguments: args)
                    return result.isError ? nil : result
                }
            }
        }
        let pageURL: () -> String? = {
            guard lastAttemptedStep?.tool == "browser" else { return nil }
            let read = browserObservation("location")
            return read.isError ? nil : read.browserObservationURL
        }
        func temporalEvidence() -> BatchCompletion.Observation? {
            guard completionBaseline?.before != nil else { return nil }
            return completionObservation(step: lastAttemptedStep, app: lastApp, window: verificationWindow,
                                         tab: finalBrowserTab as? Int ?? (try? Self.validatedBrowserTabID(finalBrowserTab)))
        }
        var earlyCompletion: DoneCheck.Result?
        if (arguments["return_state"] as? Bool) == false,
           !failed, !stoppedForTime, !wantsScreenshot, trailingObservation == nil,
           pendingLastEffect == nil, lastAttemptedStep?.tool == "browser", !doneConditions.isEmpty,
           doneConditions.allSatisfy({ condition in
               switch condition {
               case .urlContains, .urlChanged: return true
               default: return false
               }
           }) {
            let result = DoneCheck.check(doneConditions, evidence: .init(screenText: nil, pageURL: pageURL),
                                         baseline: completionBaseline, after: temporalEvidence())
            switch result {
            case .verified, .weak: earlyCompletion = result
            case .missing: break
            }
        }
        // When the caller only asked for a verified receipt, files and exact
        // native fields can be checked without a final tree.
        if (arguments["return_state"] as? Bool) == false,
           !failed, !stoppedForTime, !wantsScreenshot, trailingObservation == nil,
           pendingLastEffect == nil, replayed == nil, lastAttemptedStep?.tool != "browser", clock.systemUptime < deadline {
            earlyCompletion = TimingLog.measure("batch.final_direct_check") {
                DoneCheck.directCompletion(doneConditions) { label in
                    guard clock.systemUptime < deadline, let lastApp,
                          (try? requireUsableComputerUseSession()) != nil,
                          let app = try? AppDiscovery.resolveRunning(lastApp),
                          let context = try? SnapshotBuilder.resolveTargetWindow(for: app, windowID: verificationWindow) else { return nil }
                    return SnapshotBuilder.directFieldValue(label, in: context)
                }
            }
        }
        var browserTextChecks: [(DoneCheck.Condition, BrowserEvidenceScope)] = []
        func recordBrowserTextCheck(_ condition: DoneCheck.Condition, from check: ToolCallResult) {
            if case .text(let text) = condition, !DoneCheck.isPlainNumber(text), let scope = check.browserEvidenceScope {
                browserTextChecks.append((condition, scope))
            }
        }
        var observation = trailingObservation
        if receipt.failureCode?.isActionRefusal != true, !unconfirmedOpen, earlyCompletion == nil,
           observation == nil, lastAttemptedStep?.tool == "browser" {
            if unconfirmedFinalClick, let condition = doneConditions.first {
                if let check = waitForBrowserEvidence(condition) { recordBrowserTextCheck(condition, from: check) }
            }
            observation = browserObservation("read")
        }
        // A batch that ends in the browser is remembered as the browser's, not as an app it also used earlier:
        // otherwise the page text would become that app's "last shown" state and skew the next app read.
        if lastAttemptedStep?.tool == "browser" { lastApp = "browser" }
        if unconfirmedOpen {
            lines.append("List browser tabs to check whether the open created a tab before trying again.")
        }
        // An expired ref without a window pin cannot tell us which window to read; a policy refusal needs no read.
        if receipt.failureCode?.isActionRefusal != true, earlyCompletion == nil, observation == nil,
           lastAttemptedStep?.tool != "browser",
           lastAttemptedStep?.arguments["ref"] == nil || verificationWindow != nil,
           clock.systemUptime < deadline, let lastApp {
            var readArguments: [String: Any] = [
                "app": lastApp, "include_screenshot": NSNumber(value: wantsScreenshot),
            ]
            if let verificationWindow {
                readArguments["window_id"] = verificationWindow
            } else {
                readArguments["settle_ms"] = LeanDefaults.batchSettleMs
            }
            observation = TimingLog.measure("batch.final_native_read") {
                callToolAsResult(name: "get_app_state", arguments: readArguments)
            }
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

        var unchanged = false
        var screenChanged = true
        var repeatedFailures = 0
        // Keep repeated failures and observation history attached to their target.
        let memoryKey: String?
        if lastAttemptedStep?.tool == "browser" {
            let bridge = BrowserBridge.shared
            let tab = ComputerUseToolDispatcher.browserTabID(finalBrowserTab) ?? bridge.currentTab
            memoryKey = tab.map { "browser:\(bridge.referenceGeneration):\($0)" }
        } else if let lastApp, let verificationWindow {
            memoryKey = "\(lastApp):window:\(verificationWindow)"
        } else {
            memoryKey = lastApp
        }
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
        // Done by check: each done_when condition is tested directly. A verified goal needs no model.
        var verifiedDone = false
        var recoveredBrowserOutcome = false
        // A final click may have landed. Read its postcondition without replaying the click.
        let ambiguousFinalClick = unconfirmedFinalClick && observation?.isError == false
            && observation?.browserObservationURL?.isEmpty == false
        if !doneConditions.isEmpty, (!failed || ambiguousFinalClick), !stoppedForTime {
            func checkConditions() -> DoneCheck.Result {
                let finalScreen = observation.flatMap { result -> String? in
                    guard !result.isError else { return nil }
                    if lastAttemptedStep?.tool == "browser" {
                        guard result.browserObservationURL?.isEmpty == false,
                              let page = result.browserFullObservationText ?? result.primaryText, page.hasPrefix("Page:") else { return nil }
                        // Filter instructions can repeat the exact search text even when there were no matches.
                        let rows = page.split(separator: "\n").dropFirst().filter { line in
                            !line.hasPrefix("(nothing on this page mentions ")
                                && !line.hasPrefix("(only lines mentioning ")
                                && !line.hasPrefix("(no readable content yet;")
                                && !line.hasPrefix("(little readable text:")
                                && !line.hasPrefix("(controls only;")
                        }
                        let evidence = rows.joined(separator: "\n")
                        return evidence.isEmpty ? nil : evidence
                    }
                    guard let state = LeanOutput.stateText(of: result),
                          DoneCheck.supportsAbsenceCheck(state),
                          !state.contains(SnapshotObservationOptions.accessibilityOmittedNote),
                          !state.contains("the app hides its web content") else { return nil }
                    if let expectedWindow = replayed?.window, BatchRecipes.Window(state: state) != expectedWindow { return nil }
                    if let verificationWindow {
                        let header = state.split(separator: "\n").prefix(3)
                        guard header.count == 3,
                              header.last.map(String.init) == "Window ID: \(verificationWindow)" else { return nil }
                    }
                    return state
                }
                let evidence = DoneCheck.Evidence(
                    screenText: finalScreen,
                    pageURL: {
                        if lastAttemptedStep?.tool == "browser", let observation {
                            return observation.browserObservationURL
                        }
                        return pageURL()
                    },
                    supportsAbsence: lastAttemptedStep?.tool != "browser",
                    directlyVerified: browserTextChecks.filter { $0.1 == observation?.browserEvidenceScope }.map(\.0)
                )
                let after = temporalEvidence()
                if replayed != nil {
                    return recipeRun.checkReplay(evidence: evidence, baseline: completionBaseline, after: after)
                }
                return DoneCheck.check(doneConditions, evidence: evidence, baseline: completionBaseline, after: after)
            }
            var doneResult = earlyCompletion ?? TimingLog.measure("batch.final_check", checkConditions)
            if (!failed || ambiguousFinalClick), finalClickChecksPage, case .missing(let unmet) = doneResult,
               let pending = doneConditions.first(where: { unmet.contains($0.summary) }),
               let check = waitForBrowserEvidence(pending) {
                recordBrowserTextCheck(pending, from: check)
                observation = browserObservation("read")
                doneResult = checkConditions()
            }
            if case .verified = doneResult { verifiedDone = true }
            // Reconciled, not retried: Chrome lost the last click's reply, and fresh page evidence (strong, not a
            // presence-only match from before the batch) shows the requested result.
            if ambiguousFinalClick, verifiedDone {
                recoveredBrowserOutcome = true
                receipt.stop = nil
                lines.append("Chrome did not acknowledge the last click. The requested result was verified from the page.")
            }
            switch doneResult {
            case .verified: receipt.doneCheck = .verified
            case .weak: receipt.doneCheck = .weakEvidence
            case .missing: receipt.doneCheck = .unmet
            }
            lines.append(DoneCheck.line(for: doneResult))
        }
        if failed, !recoveredBrowserOutcome, receipt.failureCode?.isActionRefusal != true {
            lines.append(BatchEffects.advice(for: lastDelivery, stepNumber: failedNumber))
        }
        if let stuckLine, !verifiedDone { lines.append(stuckLine) }

        // Explicit checks and interrupted steps already have a concrete recovery result.
        // Reserve the optional referee for successful batches with no declared outcome check.
        if changedSomething, mayUseReferee, !failed, !stoppedForTime,
           stuckLine == nil, let observation, !observation.isError {
            let state = LeanOutput.stateText(of: observation) ?? observation.textContent
            let changes = previousShown.flatMap { AXStateDiff.diff(previous: $0, current: state) }
            let summary = RefereeSummary.build(
                goal: goal,
                steps: stepResults,
                repeatedFailures: repeatedFailures,
                screenChanged: screenChanged,
                dialogOpen: RefereeSummary.dialogOpen(in: state),
                changes: changes,
                // Select evidence before the summary applies its screen budget.
                screen: RefereeView.build(state: state, goal: goal, doneWhen: lastStepText,
                                                 limit: Referee.maxViewCharacters / 2),
                maxCharacters: Referee.maxViewCharacters
            )
            let result = unchanged ? lastResultText + "; app unchanged since the previous batch" : lastResultText
            // Page text has no native window binding. Do not capture a different window for it.
            let picture = lastApp.flatMap { app in
                Referee.picture(url: Referee.baseURL, state: state, remaining: deadline - clock.systemUptime) {
                    localDecisionImage(app: app, state: state)
                }
            }
            if let verdict = Referee.decide(goal: goal, lastStep: lastStepText, result: result, summary: summary,
                                            imageBase64: picture, remaining: deadline - clock.systemUptime) {
                let showHint = verdict.label != "done" || Referee.allowsCompletionHints
                if showHint, let hint = Referee.hint(for: verdict, browser: lastAttemptedStep?.tool == "browser") {
                    lines.append(hint)
                    receipt.decisionHint = true
                }
            }
        }

        if receipt.failureCode?.isActionRefusal != true, wantsScreenshot, !unconfirmedOpen,
           lastAttemptedStep?.tool == "browser", !lastStepReturnedBrowserImage {
            let capture = browserObservation("screenshot")
            let images = capture.content.filter { $0.dictionary["type"] as? String == "image" }
            if images.isEmpty {
                lines.append("Browser screenshot unavailable: \(BatchTool.firstLine(capture.textContent))")
            } else {
                browserImages.append(.text("Final browser screenshot."))
                browserImages.append(contentsOf: images)
            }
        }

        if stopIfCancelled() {
            return ToolCallResult(content: [.text(lines.joined(separator: "\n"))], isError: true, batchReceipt: receipt, deliveryState: receipt.deliveryState)
        }

        // Record the replay or save a completed explicit run.
        let replayWindowChanged = replayed != nil && receipt.stop == .windowChanged
        lines += recipeRun.finish(app: defaultApp ?? lastApp ?? "browser", steps: steps, lines: lines,
                                  failed: failed || replayWindowChanged, stopped: (stoppedForTime && !replayWindowChanged) || receipt.failureCode?.isActionRefusal == true,
                                  remember: remember, verifiedDone: verifiedDone,
                                  finalState: observation.flatMap { $0.isError ? nil : LeanOutput.stateText(of: $0) })

        // The final read is taken; hand focus back now rather than after the reply is composed.
        focus.close()

        let compactVerified = compactReply && verifiedDone && !failed && !stoppedForTime
        let replyLines = compactVerified ? BatchTool.compactVerifiedLines(lines) : lines
        var content: [ToolResultContentItem] = [.text(replyLines.joined(separator: "\n"))]
        if let observation {
            receipt.observation = observation.isError ? .failed : .returned
            let presented = compactReply && !failed && !stoppedForTime && !observation.isError
                && (doneConditions.isEmpty || verifiedDone)
                ? LeanOutput.condensed(observation, mode: .compactBatch) : observation
            var shown = presented
            if let memoryKey, !presented.isError, LeanOutput.stateText(of: presented) != nil {
                // Compare with what the model last saw for this app (a get_app_state or the previous batch),
                // not with reads inside this batch it never saw. After a failure send the full state.
                shown = LeanOutput.batchNativeObservation(
                    presented, memory: .shared, app: memoryKey,
                    allowsDiff: !failed && !stoppedForTime && (doneConditions.isEmpty || verifiedDone),
                    compactVerified: compactVerified
                )
            } else if compactVerified, lastAttemptedStep?.tool == "browser", !presented.isError {
                shown = LeanOutput.browserHeaderOnly(presented)
            }
            content.append(contentsOf: shown.content)
        }
        content.append(contentsOf: browserImages)
        // A batch stopped for time or window change did not complete: an error, with the same receipt lines.
        let incomplete = receipt.stop == .timeBudget || receipt.stop == .windowChanged
        return ToolCallResult(content: content, isError: (failed || incomplete) && !recoveredBrowserOutcome, batchReceipt: receipt, deliveryState: receipt.deliveryState)
    }
}
