import Foundation

public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let annotations: [String: Any]
    public let inputSchema: [String: Any]

    public init(name: String, description: String, annotations: [String: Any], inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.annotations = annotations
        self.inputSchema = inputSchema
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]

        if !annotations.isEmpty {
            dictionary["annotations"] = annotations
        }

        return dictionary
    }
}

public enum ToolDefinitions {
    public static var all: [ToolDefinition] {
        configured(virtualDisplayEnabled: VirtualDisplayConfig.current.enabled)
    }

    public static func isKnown(_ name: String) -> Bool {
        definitions.contains { $0.name == name }
    }

    static func available(environment: [String: String]) -> [ToolDefinition] {
        configured(
            virtualDisplayEnabled: VirtualDisplayConfig.load(environment: environment).enabled,
            browserAvailable: BrowserBridge.executablePath(environment: GodspeedSettings.merged(environment)) != nil
        )
    }

    static func configured(
        virtualDisplayEnabled: Bool, browserAvailable: Bool = BrowserBridge.isAvailable
    ) -> [ToolDefinition] {
        // `browser` is listed only when Open Browser Use is installed.
        let definitions = definitions.filter { $0.name != "browser" || browserAvailable }
        guard !virtualDisplayEnabled else { return definitions }
        return definitions.map { tool in
            guard tool.name == "get_app_state" else { return tool }
            var schema = tool.inputSchema
            var properties = schema["properties"] as? [String: Any] ?? [:]
            properties.removeValue(forKey: "window_placement")
            schema["properties"] = properties
            return ToolDefinition(name: tool.name, description: tool.description, annotations: tool.annotations, inputSchema: schema)
        }
    }

    /// Order is the order a model should reach for them: batch and browser first, element tools next,
    /// rare tools last.
    private static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: BatchTool.name,
            description: "Use for 2 or more steps in a native Mac app, not for a web page (use browser) or one lone step (use that tool). Runs in the background, dialogs included. Send 2-10 steps; they run in order and stop at the first failure. The reply is one line per step (ok, or FAILED with the reason) plus the app's state. A step is a tool name and its arguments: {\"tool\": \"click\", \"label\": \"Send\"}. Whole form: {\"tool\": \"fill\", \"fields\": {\"To\": \"sam@x.com\"}, \"submit\": \"Send\"}; add \"web\": true for a page. Wait for something slow: {\"tool\": \"wait\", \"window\": \"Export\"} (or text, gone, settle: true, timeout_ms).",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name, used by steps that name none"),
                    "steps": [
                        "type": "array",
                        "maxItems": BatchTool.maxSteps,
                        "description": "Steps, in order",
                        "items": [
                            "type": "object",
                            "properties": [
                                "tool": [
                                    "type": "string",
                                    "description": "Tool name: any app tool, browser, or fill",
                                ],
                            ],
                            "required": ["tool"],
                            "additionalProperties": true,
                        ],
                    ],
                    "goal": stringProperty(description: "One sentence: what you are trying to get done. The reply may then say done or stuck. With no steps, replays the saved recipe for it."),
                    "done_when": ["type": ["object", "array"], "description": "How the reply knows the goal is done, checked directly: {\"text\": \"Message sent\"} (on screen), {\"field\": \"Volume\", \"equals\": \"40\"}, {\"gone\": \"Loading\"}, {\"file_exists\": \"~/Desktop/out.pdf\"}, {\"url_contains\": \"/thanks\"}. One object or a list. Met: the reply says \"Done: verified\"."],
                    "foreground": ["type": "boolean", "default": false, "description": "Last resort only: bring the app forward (skipped while the user is using the Mac). Steps, dialogs included, normally work in the background."],
                    "remember": ["type": "boolean", "default": false, "description": "Save these steps as the recipe for goal once they all succeed."],
                    "screenshot": ["type": "boolean", "default": false, "description": "Also return a screenshot."],
                ],
                required: []
            )
        ),
        ToolDefinition(
            name: HandoffTool.name,
            description: "Use to hand off a bounded subtask in a native Mac app (5 to 30 steps), not for one or two known steps (use batch). GODSPEED runs it alone and returns only when done, stuck or unsure. Give app, goal and done_when. Optional values: text to type, by field name. It replays a saved recipe if one exists, else picks labelled controls itself, never pressing risky ones (Delete, Send, Buy, Pay). When unsure it returns the reason and the top options for you to decide.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name"),
                    "goal": stringProperty(description: "One bounded subtask, one sentence"),
                    "done_when": ["type": ["object", "array"], "description": "Required. {\"text\": \"Saved\"}, {\"field\": \"Name\", \"equals\": \"Ann\"}, {\"gone\": \"Loading\"}, {\"file_exists\": \"~/x.pdf\"}, {\"url_contains\": \"/thanks\"}; one object or a list."],
                    "values": ["type": "object", "description": "Text to type, field name to text: {\"Name\": \"Ann\"}", "additionalProperties": ["type": "string"]],
                    "max_steps": ["type": "integer", "default": 15, "maximum": 30],
                    "time_budget_s": ["type": "number", "default": 60, "maximum": 300],
                ],
                required: ["app", "goal", "done_when"]
            )
        ),
        ToolDefinition(
            name: "browser",
            description: "Use for web pages, in your own background Chrome tab; the user's tab is never touched. Not for native Mac apps (use batch or app tools), and never app tools in Google Chrome. Actions: open, go, read (numbered links, buttons, fields, headings; find: \"words\" lists only matching lines, full: true lists more), screenshot (visible page), click, drag (between visible controls in one tab), type, key, select, check, uncheck, hover, scroll, back, forward, reload, wait_for, peek (up to 6 URLs), tabs, use_tab, wait, info, upload. A whole form is ONE call: batch {\"steps\": [{\"tool\": \"fill\", \"web\": true, \"fields\": {\"Name\": \"Ada\", \"Plan\": \"Team\"}, \"submit\": \"Send\"}]} (text boxes, dropdowns and checkboxes). Replies already show what changed; read again only when unsure.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "action": stringProperty(
                        description: "What to do",
                        enumValues: ["open", "go", "read", "screenshot", "click", "drag", "type", "key", "hover", "select", "check", "uncheck", "scroll", "back", "forward", "reload", "wait_for", "tabs", "use_tab", "wait", "info", "upload", "peek"]
                    ),
                    "label": stringProperty(description: "Visible text of the target, e.g. \"Sign in\""),
                    "find": stringProperty(description: "read: only controls and text that mention these words"),
                    "full": ["type": "boolean", "default": false, "description": "read: list about four times as much"],
                    "index": integerProperty(description: "Element number from read"),
                    "to_label": stringProperty(description: "drag: destination label in the same tab"),
                    "to_index": integerProperty(description: "drag: destination element number from read"),
                    "text": stringProperty(description: "type: text to enter. wait_for: text to wait for"),
                    "replace": ["type": "boolean", "default": false, "description": "type: true replaces the field's value"],
                    "option": stringProperty(description: "select: option text or value, e.g. Canada"),
                    "direction": stringProperty(description: "scroll: default down", enumValues: ["up", "down", "left", "right", "top", "bottom"]),
                    "amount": ["type": "number", "description": "scroll: pixels. Default most of a screen"],
                    "timeout": ["type": "number", "description": "wait_for, wait: seconds, max 30"],
                    "key": stringProperty(description: "key: Enter, Tab, Escape, ArrowDown, or Cmd+A"),
                    "url": stringProperty(description: "open, go: URL, e.g. example.com"),
                    "urls": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 6,
                        "description": "peek: up to 6 URLs",
                    ],
                    "tab_id": integerProperty(description: "use_tab: tab id from tabs"),
                    "state": stringProperty(description: "wait: load (default) or domcontentloaded", enumValues: ["load", "domcontentloaded"]),
                    "files": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "upload: local file paths",
                    ],
                ],
                required: ["action"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Use to read a Mac app's key window as a numbered element list, starting its session if needed; not for finding one control (use query). Call it first for an app you have not read this turn. A batch reply already ends with this state. Add include_screenshot only when the list is not enough.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "compact": ["type": "boolean", "default": false,
                                "description": "Keep actionable controls and focus, omit extra layout text"],
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "include_ax": ["type": "boolean", "default": true, "description": "False skips the element list and invalidates earlier element numbers."],
                    "include_screenshot": ["type": "boolean", "default": LeanDefaults.includeScreenshot, "description": "Also return a screenshot, e.g. for pixel clicks."],
                    "text_limit": textLimitProperty(description: "Max text characters per element; \"max\" for all. Default 500."),
                    "max_tree_nodes": positiveIntegerProperty(description: "Default 1200."),
                    "max_tree_depth": positiveIntegerProperty(description: "Default 64."),
                    "window_placement": stringProperty(
                        description: "keep (default). agent_display moves the window to the agent's hidden display so a covered window can be read. restore brings it back.",
                        enumValues: WindowPlacement.allCases.map(\.rawValue)
                    ),
                    "settle_ms": positiveIntegerProperty(description: "Wait up to this many ms (max 5000) while the window shows it is busy or loading."),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "click",
            description: "Use to press a control by label (visible name) or element_index; x and y pixels only when it has no name. Not for typing (type_text) or fields (set_value). Example: {\"app\": \"Notes\", \"label\": \"Send\"}.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element number"),
                    "x": numberProperty(description: "X pixel from a screenshot"),
                    "y": numberProperty(description: "Y pixel from a screenshot"),
                    "click_count": integerProperty(description: "Default 1"),
                    "mouse_button": stringProperty(
                        description: "Default left.",
                        enumValues: ["left", "right", "middle"]
                    ),
                    "click_method": stringProperty(
                        description: "auto (default), accessibility (needs element_index), app_post, sky_click, or global (moves the real pointer; only if the user enabled it).",
                        enumValues: ClickMethod.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Use to type literal text into the focused field; not to replace a field's value (use set_value). Click the field first. Example: {\"app\": \"Notes\", \"text\": \"hello\"}.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Text to type"),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "text"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: "Use for a key or shortcut, not for menu commands (use press_menu). Press a key or combination: \"Return\", \"Escape\", \"Tab\", \"Down\", \"cmd+s\" (modifiers: cmd, shift, alt, ctrl). Example: {\"app\": \"Notes\", \"key\": \"cmd+s\"}.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "key": stringProperty(description: "Key or combination, e.g. \"cmd+s\""),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Use to set a field's whole value and check that it reads back; not to add text at the cursor (use type_text). An empty value clears it. Give label (or element_index) and value.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element number"),
                    "value": stringProperty(description: "Value to assign"),
                ],
                required: ["app", "value"]
            )
        ),
        ToolDefinition(
            name: "press_menu",
            description: "Use to run a menu command by path, e.g. \"File > Save\"; not for buttons in the window (use click). Works without activating the app. Titles ignore case, spaces and a trailing …. A title not found returns the items at that level.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "path": stringProperty(description: "Menu title, then items down to the command: \"File > Save\", or [\"File\", \"Save\"]."),
                ],
                required: ["app", "path"]
            )
        ),
        ToolDefinition(
            name: SmartSteps.saveAsName,
            description: "Use to save the front document under a new name; not for a plain Save (press_menu). It does File > Save As… (Save… for an untitled one), then the folder, the name and Save, inside one focus borrow. The reply gives the saved path once the file is on disk; otherwise it gives the reason and any dialog that is open. Example: {\"app\": \"TextEdit\", \"path\": \"~/Desktop/notes.txt\"}.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "path": stringProperty(description: "Full path of the file to save, e.g. ~/Desktop/notes.txt"),
                ],
                required: ["app", "path"]
            )
        ),
        ToolDefinition(
            name: SmartSteps.openName,
            description: "Use to open a file, a web address or an app; not to click through Finder or a dialog. Opens a file in its default app (or app), a web address in the browser tool (url), or launches an app (app alone). Nothing is brought to the front. The reply says what opened. Examples: {\"path\": \"~/Downloads/report.pdf\"}, {\"url\": \"example.com\"}, {\"app\": \"Notes\"}.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "path": stringProperty(description: "File path to open, e.g. ~/Desktop/a.pdf"),
                    "url": stringProperty(description: "Web address, opened in the browser tool"),
                    "app": stringProperty(description: "App to open the path in, or the app to launch when no path or url is given"),
                ],
                required: []
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: "Use to scroll a list or page by pages; not to find one control (use query). Example: {\"app\": \"Notes\", \"direction\": \"down\", \"label\": \"Body\"}.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "direction": stringProperty(description: "Scroll direction: up, down, left, or right"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element identifier"),
                    "pages": numberProperty(description: "Number of pages to scroll. Fractional values are supported. Defaults to 1"),
                ],
                required: ["app", "direction"]
            )
        ),
        ToolDefinition(
            name: "query",
            description: "Use to find controls in the app's window by text and/or role, without a full read; not to see the whole window (use get_app_state). Matches get an index for click, set_value and scroll. Running apps only; indexes expire after 120 seconds.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Text in the control's title, description or value. Substring unless exact."),
                    "role": stringProperty(description: "Accessibility role, e.g. button (AX prefix optional)"),
                    "exact": ["type": "boolean", "description": "Complete match instead of substring. Default false."],
                    "limit": positiveIntegerProperty(description: "Default 20, max 100."),
                    "max_nodes": positiveIntegerProperty(description: "Traversal cap. Default 500, max 5000."),
                    "window_id": positiveIntegerProperty(description: "Search this window (CGWindowID) instead of the current one."),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "list_apps",
            description: "Use to see which apps are running or were used in the last 14 days; not to read an app's window (use get_app_state).",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "select_text",
            description: "Use to select text inside a text element, or place the cursor before or after it; not to replace a field's value (use set_value). text must match the accessibility tree exactly. If not unique, add prefix or suffix. Give label (or element_index).",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Text element identifier"),
                    "text": stringProperty(description: "Target text as shown in the accessibility tree"),
                    "prefix": stringProperty(description: "Optional text immediately before the target, used to disambiguate repeated matches"),
                    "suffix": stringProperty(description: "Optional text immediately after the target, used to disambiguate repeated matches"),
                    "selection": stringProperty(
                        description: "Whether to select the text or place the cursor before or after it. Defaults to text.",
                        enumValues: TextSelectionMode.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app", "text"]
            )
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Use to run a secondary accessibility action, e.g. AXShowMenu, listed on an element; not for an ordinary press (use click).",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element identifier"),
                    "action": stringProperty(description: "Secondary accessibility action name, e.g. \"AXShowMenu\""),
                ],
                required: ["app", "action"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: "Use to drag between two pixel points only when no other tool does it (not for scrolling or selecting text). Both points must be inside the app's window. Delivery does not verify the UI result; window moves or Finder drag-and-drop are not guaranteed. Global pointer use is off unless the user has enabled it.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "from_x": numberProperty(description: "Start X coordinate"),
                    "from_y": numberProperty(description: "Start Y coordinate"),
                    "to_x": numberProperty(description: "End X coordinate"),
                    "to_y": numberProperty(description: "End Y coordinate"),
                    "modifiers": ["type": "array", "items": ["type": "string"],
                                  "description": "Optional shift, option, command, or control during the drag"],
                ],
                required: ["app", "from_x", "from_y", "to_x", "to_y"]
            )
        ),
    ]
}

/// Shared by every element action: the element's visible name, so a model need not count indexes.
private func labelProperty() -> [String: Any] {
    stringProperty(description: "Visible name, e.g. \"Send\". Instead of element_index.")
}

private func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]

    if !required.isEmpty {
        schema["required"] = required
    }

    return schema
}

private func defaultAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "openWorldHint": false,
    ]
}

private func readOnlyAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
        "readOnlyHint": true,
    ]
}

private func keyMethodProperty() -> [String: Any] {
    stringProperty(
        description: "auto (default) or sky_key (background keyboard; needs a window from get_app_state).",
        enumValues: KeyMethod.allCases.map(\.rawValue)
    )
}

private func stringProperty(description: String, enumValues: [String]? = nil) -> [String: Any] {
    var property: [String: Any] = [
        "type": "string",
        "description": description,
    ]

    if let enumValues {
        property["enum"] = enumValues
    }

    return property
}

private func integerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "description": description,
    ]
}

private func positiveIntegerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "minimum": 1,
        "description": description,
    ]
}

private func textLimitProperty(description: String) -> [String: Any] {
    [
        "anyOf": [
            [
                "type": "integer",
                "minimum": 1,
            ],
            [
                "type": "string",
                "enum": [SnapshotTextLimit.maxKeyword],
            ],
        ],
        "description": description,
    ]
}

private func numberProperty(description: String) -> [String: Any] {
    [
        "type": "number",
        "description": description,
    ]
}
