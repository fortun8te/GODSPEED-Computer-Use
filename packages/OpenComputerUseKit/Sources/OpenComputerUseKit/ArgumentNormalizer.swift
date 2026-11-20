import Foundation

/// Makes a tool call forgiving. Every call (a single tool call, or a step of a batch) passes through
/// `normalize` before dispatch: argument names that weak models commonly use are mapped to the names
/// the tool takes, values are coerced to the types it expects, key spellings are normalised, quotes
/// around labels are stripped, and a missing `app` is filled from the app used last. `problem` turns a
/// call that still lacks a required argument into one corrective line with an example call.
enum ArgumentNormalizer {
    // MARK: - Tables

    /// Tools that act on one app window; they take `app`.
    static let appTools: Set<String> = [
        "get_app_state", "query", "wait_for", "click", "hover", "perform_secondary_action", "scroll", "scroll_into_view", "drag",
        "type_text", "press_key", "press_menu", "set_value", "select_text",
    ]

    static let windowBoundTools: Set<String> = [
        "click", "hover", "perform_secondary_action", "scroll", "scroll_into_view", "drag", "type_text", "press_key",
        "set_value", "select_text", "wait_for",
    ]

    /// Tools that act on one accessibility element, by `element_index` or `label`.
    static let elementTools: Set<String> = ["click", "hover", "perform_secondary_action", "scroll", "scroll_into_view", "set_value", "select_text"]

    /// Spellings for `app` on every app tool and on batch.
    private static let appAliases = [
        "application": "app", "app_name": "app", "appName": "app", "application_name": "app",
        "bundle_id": "app", "bundleId": "app", "target_app": "app", "program": "app",
    ]

    /// Spellings for an element's number. A numeric value is an element index; anything else is a label.
    private static let elementNumberAliases = [
        "element_index", "elementIndex", "element_id", "elementId", "element_number", "index", "id", "idx",
    ]

    /// Spellings for an element's visible name. A number-typed value is an index; a string is a label.
    private static let elementNameAliases = ["element", "target", "name", "element_name", "visible_name"]

    /// Per-tool spellings (wrong name → real name). Each applies only when the real name is absent.
    private static let toolAliases: [String: [String: String]] = [
        "click": [
            "text": "label", "clicks": "click_count", "count": "click_count", "times": "click_count",
            "method": "click_method",
        ],
        "perform_secondary_action": [
            "action_name": "action", "secondary_action": "action", "secondary": "action", "perform": "action",
        ],
        "scroll": [
            "dir": "direction", "scroll_direction": "direction", "way": "direction",
            "amount": "pages", "count": "pages", "times": "pages", "page": "pages", "number_of_pages": "pages",
        ],
        "set_value": [
            "text": "value", "content": "value", "new_value": "value", "newValue": "value", "to": "value",
        ],
        "select_text": [
            "content": "text", "selected": "text", "phrase": "text", "selected_text": "text", "string": "text",
        ],
        "type_text": [
            "content": "text", "value": "text", "input": "text", "string": "text", "message": "text", "body": "text",
        ],
        "press_key": [
            "keys": "key", "shortcut": "key", "combo": "key", "hotkey": "key", "combination": "key",
            "keystroke": "key", "press": "key", "keypress": "key", "key_combo": "key", "key_combination": "key",
        ],
        "press_menu": [
            "menu": "path", "item": "path", "label": "path", "labels": "path", "menu_path": "path",
            "menuPath": "path", "menu_item": "path", "menu_title": "path", "title": "path",
        ],
        "drag": [
            "x1": "from_x", "y1": "from_y", "x2": "to_x", "y2": "to_y",
            "start_x": "from_x", "start_y": "from_y", "end_x": "to_x", "end_y": "to_y",
        ],
        "query": [
            "label": "text", "name": "text", "query": "text", "q": "text", "search": "text", "match": "text",
        ],
        "get_app_state": [
            "screenshot": "include_screenshot", "ax": "include_ax",
        ],
        "browser": [
            "operation": "action", "command": "action", "mode": "action", "do": "action",
            "href": "url", "address": "url", "uri": "url",
            "content": "text", "value": "text", "input": "text",
            "keys": "key", "shortcut": "key",
            "tab": "tab_id", "tabId": "tab_id", "wait_state": "state",
        ],
        "batch": [
            "actions": "steps", "calls": "steps", "commands": "steps", "plan": "steps",
            "sequence": "steps", "tool_calls": "steps",
        ],
    ]

    private static let modifierNames = [
        "cmd": "super", "command": "super", "super": "super", "meta": "super", "win": "super",
        "ctrl": "ctrl", "control": "ctrl",
        "alt": "alt", "option": "alt", "opt": "alt",
        "shift": "shift",
    ]

    private static let namedKeys = [
        "enter": "Return", "return": "Return",
        "esc": "Escape", "escape": "Escape",
        "backspace": "BackSpace", "delete": "BackSpace", "del": "BackSpace",
        "tab": "Tab", "space": "space", "spacebar": "space",
        "up": "Up", "uparrow": "Up", "arrowup": "Up",
        "down": "Down", "downarrow": "Down", "arrowdown": "Down",
        "left": "Left", "leftarrow": "Left", "arrowleft": "Left",
        "right": "Right", "rightarrow": "Right", "arrowright": "Right",
        "pageup": "PageUp", "pagedown": "PageDown", "home": "Home", "end": "End",
    ]

    // MARK: - Required arguments

    private struct Need {
        let keys: [String]
        let text: String
        var allowsEmpty = false
    }

    private static let appNeed = Need(keys: ["app"], text: "\"app\" (the app name)")
    private static let elementNeed = Need(
        keys: ["label", "labels", "element_index"],
        text: "\"label\" (its visible name) or \"element_index\""
    )

    /// What each tool needs before it can run. Each entry needs at least one of its keys.
    private static let needs: [String: [Need]] = [
        "batch": [Need(keys: ["steps", "goal"], text: "\"steps\" (a list of steps) or a \"goal\" with a saved recipe")],
        "get_app_state": [appNeed],
        "list_apps": [],
        "query": [appNeed, Need(keys: ["text", "role"], text: "\"text\" or \"role\"")],
        "click": [appNeed, Need(
            keys: ["label", "labels", "element_index", "x"],
            text: "\"label\" (its visible name), \"element_index\", or \"x\" and \"y\""
        )],
        "drag": [
            appNeed,
            Need(keys: ["from_x", "from_label", "from_index", "label", "element_index", "files"], text: "a drag source"),
            Need(keys: ["to_x", "to_label", "to_index", "files"], text: "a drag destination"),
        ],
        "type_text": [appNeed, Need(keys: ["text"], text: "\"text\" (what to type)")],
        "press_key": [appNeed, Need(keys: ["key"], text: "\"key\", e.g. \"cmd+s\"")],
        "press_menu": [appNeed, Need(keys: ["path"], text: "\"path\", e.g. \"File > Save\"")],
        "set_value": [
            appNeed, elementNeed,
            Need(keys: ["value"], text: "\"value\" (may be empty to clear)", allowsEmpty: true),
        ],
        "scroll": [
            appNeed,
            Need(keys: ["direction"], text: "\"direction\" (up, down, left or right)"),
            elementNeed,
        ],
        "wait_for": [appNeed, Need(keys: ["label"], text: "an exact label"), Need(keys: ["condition"], text: "a wait condition")],
        "hover": [appNeed, elementNeed],
        "scroll_into_view": [appNeed, elementNeed],
        "select_text": [appNeed, Need(keys: ["text"], text: "\"text\", exactly as shown"), elementNeed],
        "perform_secondary_action": [
            appNeed,
            Need(keys: ["action"], text: "\"action\", e.g. \"AXShowMenu\""),
            elementNeed,
        ],
        "browser": [Need(keys: ["action"], text: "\"action\" (open, go, read, click, type, key, peek, tabs, use_tab, wait, info or upload)")],
    ]

    /// One valid call per tool. `APP` stands for the app name; the example is what a model should send.
    static let examples: [String: String] = [
        "batch": "{\"steps\": [{\"tool\": \"click\", \"label\": \"Send\"}]}",
        "get_app_state": "{\"app\": \"APP\"}",
        "list_apps": "{}",
        "query": "{\"app\": \"APP\", \"text\": \"Send\"}",
        "click": "{\"app\": \"APP\", \"label\": \"Send\"}",
        "drag": "{\"app\": \"APP\", \"from_x\": 100, \"from_y\": 200, \"to_x\": 300, \"to_y\": 200}",
        "type_text": "{\"app\": \"APP\", \"text\": \"hello\"}",
        "press_key": "{\"app\": \"APP\", \"key\": \"cmd+s\"}",
        "press_menu": "{\"app\": \"APP\", \"path\": \"File > Save\"}",
        "set_value": "{\"app\": \"APP\", \"label\": \"Title\", \"value\": \"Hello\"}",
        "scroll": "{\"app\": \"APP\", \"direction\": \"down\", \"label\": \"Body\"}",
        "select_text": "{\"app\": \"APP\", \"label\": \"Body\", \"text\": \"hello\"}",
        "perform_secondary_action": "{\"app\": \"APP\", \"label\": \"Send\", \"action\": \"AXShowMenu\"}",
        "browser": "{\"action\": \"go\", \"url\": \"example.com\"}",
    ]

    // MARK: - Public entry points

    /// The call with its argument names, value types and key names corrected, and `app` filled from
    /// `lastApp` when the call names none. Unknown tools only get the generic corrections.
    static func normalize(tool: String, arguments: [String: Any], lastApp: String?) -> [String: Any] {
        var args = arguments
        if tool == "drag" { expandDragPoints(&args) }
        if tool == "press_menu" { mergeMenuPath(&args) }
        renameArguments(&args, tool: tool)
        renameElementArguments(&args, tool: tool)
        // {"url": "example.com"} with no action is a page visit: the browser's "go".
        if tool == "browser", !isPresent(args["action"], allowsEmpty: false), isPresent(args["url"], allowsEmpty: false) {
            args["action"] = "go"
        }
        if tool == "click" { applyClickFlags(&args) }
        // select_text with only the words to select means the document's text: the window's one text area.
        if tool == "select_text", !["label", "labels", "element_index"].contains(where: { isPresent(args[$0], allowsEmpty: false) }) {
            args["label"] = "text entry area"
        }
        if elementTools.contains(tool) || tool == "browser", let list = args["label"] as? [Any] {
            // A list of labels is the same as `labels`.
            args["label"] = nil
            if !isPresent(args["labels"], allowsEmpty: false) { args["labels"] = list }
        }

        var out: [String: Any] = [:]
        for (key, value) in args {
            out[key] = coerce(value, kind: kind(of: key, tool: tool), key: key, tool: tool)
        }

        if appTools.contains(tool), !isPresent(out["app"], allowsEmpty: false), let lastApp, !lastApp.isEmpty {
            out["app"] = lastApp
        }
        return out
    }

    /// One corrective line for a call that lacks a required argument, or nil when it has them all.
    static func problem(tool: String, arguments: [String: Any]) -> String? {
        for need in needs[tool] ?? [] where !need.keys.contains(where: { isPresent(arguments[$0], allowsEmpty: need.allowsEmpty) }) {
            let app = (arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "<app name>"
            let example = correctedExample(tool: tool, arguments: arguments, app: app)
            return "\(tool) needs \(need.text). Example: \(tool) \(example)"
        }
        return nil
    }

    /// The tool's example call with the caller's own short text and number values put in, so the reply shows
    /// the call corrected rather than a generic one. Key order follows the template. Batch keeps its template.
    private static func correctedExample(tool: String, arguments: [String: Any], app: String) -> String {
        let template = (examples[tool] ?? "{}").replacingOccurrences(of: "APP", with: app)
        guard tool != "batch", let regex = try? NSRegularExpression(pattern: #""([a-z_]+)": ("[^"]*"|[0-9.]+)"#) else { return template }
        let source = template as NSString
        var result = template
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            let key = source.substring(with: match.range(at: 1))
            guard key != "app", let literal = given(arguments[key]) else { continue }
            let range = Range(match.range(at: 2), in: result)!
            result.replaceSubrange(range, with: literal)
        }
        return result
    }

    /// A JSON literal for a short, non-empty string or a number the caller already gave.
    private static func given(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty, text.count <= 60,
           let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
           let json = String(data: data, encoding: .utf8) {
            return String(json.dropFirst().dropLast())
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return "\(number)" }
        return nil
    }

    /// Key spellings to the names KeyPressParser reads: "CMD+S", "Command-S", "cmd s", "⌘S" → "super+s";
    /// "enter" → "Return"; "esc" → "Escape".
    static func normalizeKey(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (symbol, word) in [("⌘", "cmd+"), ("⇧", "shift+"), ("⌥", "alt+"), ("⌃", "ctrl+")] {
            text = text.replacingOccurrences(of: symbol, with: word)
        }

        // "cmd+-" and "cmd++": the key itself is a minus or a plus sign.
        var trailingKey: String?
        if text.count >= 2, let last = text.last, last == "+" || last == "-",
           let before = text.dropLast().last, before == "+" || before == "-" || before == " " {
            trailingKey = String(last)
            text = String(text.dropLast())
        }

        var tokens = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "+" || $0 == "-" })
            .map(String.init)
        if let trailingKey { tokens.append(trailingKey) }
        guard !tokens.isEmpty else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }

        var modifiers: [String] = []
        var key: String?
        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            if index < tokens.count - 1, let modifier = modifierNames[lower] {
                if !modifiers.contains(modifier) { modifiers.append(modifier) }
            } else {
                key = namedKeys[lower] ?? lower
            }
        }
        return (modifiers + [key].compactMap { $0 }).joined(separator: "+")
    }

    // MARK: - Renaming

    /// {"menu": "File", "item": "Save As…"} (and submenu/menu_item spellings) is one path, "File > Save As…".
    /// The plain renames below would keep only one of the two titles.
    private static func mergeMenuPath(_ args: inout [String: Any]) {
        guard !isPresent(args["path"], allowsEmpty: false), let menu = args["menu"] as? String, !menu.isEmpty else { return }
        var parts = [menu]
        for key in ["submenu", "item", "menu_item", "menuItem", "command"] {
            if let part = args[key] as? String, !part.isEmpty { parts.append(part); args[key] = nil }
        }
        guard parts.count > 1 else { return }
        args["menu"] = nil
        args["path"] = parts
    }

    private static func expandDragPoints(_ args: inout [String: Any]) {
        for (name, prefix) in [("from", "from"), ("start", "from"), ("to", "to"), ("end", "to")] {
            guard let raw = args[name], let point = pointValue(raw) else { continue }
            args[name] = nil
            if args["\(prefix)_x"] == nil { args["\(prefix)_x"] = point.x }
            if args["\(prefix)_y"] == nil { args["\(prefix)_y"] = point.y }
        }
    }

    private static func pointValue(_ value: Any) -> (x: Double, y: Double)? {
        if let object = value as? [String: Any] {
            guard let rawX = object["x"], let rawY = object["y"], let x = numeric(rawX), let y = numeric(rawY) else {
                return nil
            }
            return (x, y)
        }
        if let list = value as? [Any], list.count == 2, let x = numeric(list[0]), let y = numeric(list[1]) {
            return (x, y)
        }
        if let text = value as? String {
            let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }
            guard parts.count == 2, let x = numeric(parts[0]), let y = numeric(parts[1]) else { return nil }
            return (x, y)
        }
        return nil
    }

    private static func renameArguments(_ args: inout [String: Any], tool: String) {
        var pairs: [(alias: String, canonical: String)] = []
        if appTools.contains(tool) || tool == "batch" {
            pairs += appAliases.map { (alias: $0.key, canonical: $0.value) }
        }
        for (alias, canonical) in (toolAliases[tool] ?? [:]).sorted(by: { $0.key < $1.key }) {
            pairs.append((alias: alias, canonical: canonical))
        }
        for (alias, canonical) in pairs {
            guard let value = args.removeValue(forKey: alias) else { continue }
            put(value, as: canonical, into: &args, allowsEmptyCanonical: canonical == "value")
        }
    }

    private static func renameElementArguments(_ args: inout [String: Any], tool: String) {
        guard elementTools.contains(tool) || tool == "browser" else { return }
        let numberKey = tool == "browser" ? "index" : "element_index"

        for key in elementNumberAliases {
            guard let value = args.removeValue(forKey: key) else { continue }
            put(value, as: elementIndexText(value) != nil ? numberKey : "label", into: &args)
        }
        for key in elementNameAliases {
            guard let value = args.removeValue(forKey: key) else { continue }
            let isNumber = !(value is String) && numeric(value) != nil
            put(value, as: isNumber ? numberKey : "label", into: &args)
        }
    }

    /// `button` is the mouse button when it names one, and otherwise a label; `right_click` and
    /// `double_click` set the button and the count.
    private static func applyClickFlags(_ args: inout [String: Any]) {
        if let button = args.removeValue(forKey: "button") {
            let word = textValue(button)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if ["left", "right", "middle"].contains(word) {
                put(word, as: "mouse_button", into: &args)
            } else {
                put(button, as: "label", into: &args)
            }
        }
        if let flag = args.removeValue(forKey: "right_click"), boolean(flag) as? Bool == true {
            args["mouse_button"] = "right"
        }
        let doubleFlag = args.removeValue(forKey: "double_click") ?? args.removeValue(forKey: "double")
        if let doubleFlag, boolean(doubleFlag) as? Bool == true {
            put(2, as: "click_count", into: &args)
        }
    }

    private static func put(_ value: Any, as key: String, into args: inout [String: Any], allowsEmptyCanonical: Bool = false) {
        if !isPresent(args[key], allowsEmpty: allowsEmptyCanonical) { args[key] = value }
    }

    private static func isPresent(_ value: Any?, allowsEmpty: Bool) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let text = value as? String { return allowsEmpty || !text.isEmpty }
        if let list = value as? [Any] { return !list.isEmpty }
        return true
    }

    // MARK: - Coercion

    private enum Kind {
        case none, bool, int, number, elementIndex, text, label, labels, lower, key, textLimit, list
    }

    private static func kind(of key: String, tool: String) -> Kind {
        switch key {
        case "screenshot", "remember", "foreground", "replace", "include_ax", "include_screenshot", "exact":
            return .bool
        case "window_id":
            return tool == "query" ? .int : .none
        case "click_count", "limit", "max_nodes", "max_tree_nodes", "max_tree_depth", "settle_ms", "tab_id":
            return .int
        case "index":
            return tool == "browser" ? .int : .elementIndex
        case "element_index":
            return .elementIndex
        case "x", "y", "from_x", "from_y", "to_x", "to_y", "pages", "amount", "timeout":
            return .number
        case "label", "app", "path":
            return .label
        case "labels":
            return .labels
        case "direction", "mouse_button", "click_method", "key_method", "selection", "window_placement", "state":
            return .lower
        case "key":
            return .key
        case "text_limit":
            return .textLimit
        case "urls", "files", "steps":
            return .list
        case "text", "value", "action", "url", "goal", "prefix", "suffix":
            return .text
        default:
            return .none
        }
    }

    private static func coerce(_ value: Any, kind: Kind, key: String, tool: String) -> Any {
        switch kind {
        case .none:
            return value
        case .bool:
            return boolean(value) ?? value
        case .int:
            return integer(value) ?? value
        case .number:
            return number(value) ?? value
        case .elementIndex:
            return elementIndexText(value) ?? value
        case .text:
            if let text = textValue(value) { return text }
            return value
        case .label:
            if let list = value as? [Any] {
                return list.compactMap { item in textValue(item).map { stripQuotes($0) } }
            }
            if let text = textValue(value) { return stripQuotes(text) }
            return value
        case .labels:
            if let text = value as? String { return [stripQuotes(text)] }
            if let list = value as? [Any] {
                return list.compactMap { item in textValue(item).map { stripQuotes($0) } }
            }
            return value
        case .lower:
            guard let text = textValue(value)?.trimmingCharacters(in: .whitespaces).lowercased() else { return value }
            return key == "direction" ? directionWord(text) : text
        case .key:
            let joined: String?
            if let list = value as? [Any] {
                joined = list.compactMap { textValue($0) }.joined(separator: "+")
            } else {
                joined = textValue(value)
            }
            guard let joined else { return value }
            return tool == "press_key" ? normalizeKey(joined) : joined
        case .textLimit:
            if textValue(value)?.trimmingCharacters(in: .whitespaces).lowercased() == "max" { return "max" }
            return integer(value) ?? value
        case .list:
            if let text = value as? String { return [text] }
            return value
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A number from a number or numeric text ("12", " 1.5 ", "120px"). Booleans are not numbers.
    private static func numeric(_ value: Any) -> Double? {
        if isBoolean(value) { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            return Double(trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed)
        }
        return nil
    }

    private static func boolean(_ value: Any) -> Any? {
        if isBoolean(value), let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "y", "on", "1": return true
            case "false", "no", "n", "off", "0": return false
            default: return nil
            }
        }
        if let number = numeric(value), number == 0 || number == 1 { return number == 1 }
        return nil
    }

    private static func integer(_ value: Any) -> Any? {
        guard let number = numeric(value), number.isFinite, number.rounded(.towardZero) == number,
              abs(number) < 1e15 else { return nil }
        return Int(number)
    }

    private static func number(_ value: Any) -> Any? {
        guard let number = numeric(value), number.isFinite else { return nil }
        return number
    }

    /// An element index as text: 12, "12", 12.0 and "#12" all become "12". Anything else is nil.
    private static func elementIndexText(_ value: Any) -> Any? {
        if let number = integer(value) as? Int { return number >= 0 ? String(number) : nil }
        if let text = value as? String, let number = Int(text.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" })),
           number >= 0 {
            return String(number)
        }
        return nil
    }

    /// Text for a string-typed argument: numbers and booleans become their text. Not trimmed, so typed text keeps its spaces.
    private static func textValue(_ value: Any) -> String? {
        if isBoolean(value), let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Removes one pair of matching quotes around a label or app name, and surrounding spaces.
    static func stripQuotes(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("«", "»"), ("`", "`")]
        for (open, close) in pairs where first == open && last == close {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// "DOWN", "page down", "scroll downwards" → "down". Other words pass through lowercased.
    private static func directionWord(_ lower: String) -> String {
        for word in ["up", "down", "left", "right"] where lower.contains(word) {
            return word
        }
        return lower
    }
}

/// The app the most recent tool call named, so a later call that leaves `app` out can use it.
/// Shared by every thread that calls the dispatcher.
final class RecentAppMemory: @unchecked Sendable {
    /// Per agent (see `ClientScope`): a step without `app` goes to the app this agent used last, not another's.
    static var shared: RecentAppMemory { scoped.current }
    private static let scoped = ScopedStore<RecentAppMemory>(make: { _ in RecentAppMemory() })

    private let lock = NSLock()
    private var app: String?

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return app
    }

    func remember(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        app = trimmed
    }
}
