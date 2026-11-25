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
        configured(virtualDisplayEnabled: VirtualDisplayConfig.current.enabled,
                   backgroundOnly: backgroundOnlyMode(),
                   leanListing: leanListingEnabled(GodspeedSettings.environment),
                   gsd1Enabled: LocalDecisionTool.baseURL() != nil)
    }

    public static func isKnown(_ name: String) -> Bool {
        definitions.contains { $0.name == name }
    }

    static func available(environment: [String: String]) -> [ToolDefinition] {
        let settings = GodspeedSettings.merged(environment)
        return configured(
            virtualDisplayEnabled: VirtualDisplayConfig.load(environment: environment).enabled,
            browserAvailable: BrowserBridge.executablePath(environment: settings) != nil,
            backgroundOnly: backgroundOnlyMode(environment: settings),
            leanListing: leanListingEnabled(settings),
            gsd1Enabled: LocalDecisionTool.baseURL(environment: settings) != nil
        )
    }

    private static func leanListingEnabled(_ environment: [String: String]) -> Bool {
        StrictBackground.enabledFlag(environment["OPEN_COMPUTER_USE_LEAN_TOOL_LIST"])
    }

    // Specialized tools remain callable inside a batch. Keep direct entry points
    // for observation, native actions, local handoff and browser work.
    static let batchOnlyTools: Set<String> = [
        "gesture", "hover", "perform_secondary_action", "scroll_into_view", "wait_for"
    ]

    private static let leanDescriptions: [String: String] = [
        "App name or bundle identifier": "App name or bundle ID.",
        "Window ID from get_app_state or query; refuses if the target changed.": "Pin the Window ID from a read.",
        "Exact ref from get_app_state with include_refs. Use instead of label, index or pixels.": "Exact ref from get_app_state include_refs. Replaces other targets.",
        "Visible name, e.g. \"Send\". Instead of element_index.": "Visible name instead of element_index.",
    ]

    static func configured(
        virtualDisplayEnabled: Bool, browserAvailable: Bool = BrowserBridge.isAvailable,
        backgroundOnly: Bool = false, leanListing: Bool = false, gsd1Enabled: Bool = false
    ) -> [ToolDefinition] {
        // `browser` is listed only when Open Browser Use is installed.
        let definitions = definitions.filter { tool in
            (tool.name != "browser" || browserAvailable)
                && (tool.name != LocalDecisionTool.name || gsd1Enabled)
                && (!leanListing || !batchOnlyTools.contains(tool.name))
        }
        return definitions.map { tool in
            var schema = tool.inputSchema
            var properties = schema["properties"] as? [String: Any] ?? [:]
            if !virtualDisplayEnabled, tool.name == "get_app_state" {
                properties.removeValue(forKey: "window_placement")
            }
            if backgroundOnly { properties.removeValue(forKey: "foreground") }
            let description = leanListing && tool.name == BatchTool.name
                ? tool.description + " Also supports gesture, hover, perform_secondary_action, scroll_into_view and wait_for as steps."
                : tool.description
            if !backgroundOnly {
                properties["strict_background"] = [
                    "type": "boolean",
                    "description": "Accessibility-only mode. Also disables background keys, menu commands, drag and app or file opening. Nested steps inherit it."
                ]
            }
            if leanListing {
                for key in ["app", "window_id", "ref", "label"] {
                    if var property = properties[key] as? [String: Any],
                       let description = property["description"] as? String,
                       let replacement = leanDescriptions[description] {
                        property["description"] = replacement
                        properties[key] = property
                    }
                }
            }
            schema["properties"] = properties
            return ToolDefinition(name: tool.name, description: description, annotations: tool.annotations, inputSchema: schema)
        }
    }

    /// Order is the order a model should reach for them: batch and browser first, element tools next,
    /// rare tools last.
    private static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: BatchTool.name,
            description: "Use to run ordered steps with a final check. Give each step a tool and its arguments, for example {\"tool\": \"wait\", \"window\": \"Export\"}. Use fill with a fields map and optional submit for a form. On failure, use the receipt to continue from current state.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name, used by steps that name none"),
                    "window_id": positiveIntegerProperty(description: "Pin all native steps in this batch to one observed window. Requires app, explicit steps and background delivery."),
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
                    "goal": stringProperty(description: "One sentence describing the task. To replay a verified recipe, pass the same app, exact goal and any required values without steps."),
                    "resume": stringProperty(description: "Token from a stopped batch's reply. Runs only its steps that never ran, after a fresh read, with the same goal, done_when and window. Send only resume (and values if asked). Steps that may have been sent are never repeated."),
                    "inspect_resume": stringProperty(description: "Read a checkpoint's compact progress, uncertainty and required value slots after a context reset. Send only this token. No actions run and the token is not consumed."),
                    "done_when": ["type": ["object", "array"], "description": #"Completion check. Use {"appeared":"Message sent"}, {"disappeared":"Loading"}, {"file_changed":"~/Desktop/out.pdf"}, {"url_changed":"https://example.com/thanks"}, or {"field":"Volume","equals":"40","since_start":"changed"} for a change since step 1. Plain text, gone, field, URL substring and file_exists checks are weak evidence. Give one check or a list."#],
                    "foreground": ["type": "boolean", "default": false, "description": "Last resort only: bring the app forward (skipped while the user is using the Mac). Steps, dialogs included, normally work in the background."],
                    "remember": ["type": "boolean", "default": false, "description": "Save completed steps as a recipe. Mutating steps require a passing done_when."],
                    "values": ["type": "object", "description": "Explicit recipe slot names and values. Missing or changed values require confirmation before replay."],
                    "return_state": ["type": "boolean", "description": "True explicitly requests the final state. False can skip reading it when direct evidence verifies completion. Recovery still includes state."],
                    "compact": ["type": "boolean", "description": "Smaller receipt and final observation. Default: on for click sequences or batches with done_when. A verified result may omit the implicit tree. Explicit compact:true can also summarize verified step metadata. Recovery keeps individual step receipts."],
                    "effects": ["type": "boolean", "description": "False skips per-step effect reads. Calculator label sequences default to a final display read. True requests intermediate effects where supported."],
                    "screenshot": ["type": "boolean", "default": false, "description": "Also return a screenshot."],
                ],
                required: []
            )
        ),
        ToolDefinition(
            name: HandoffTool.name,
            description: "Use for a bounded Mac subtask. Exact field checks can run without a model. For ambiguous actions, handoff uses the local checker and stops on risk or uncertainty.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name"),
                    "window_id": observedWindowIDProperty(),
                    "goal": stringProperty(description: "One bounded subtask, one sentence"),
                    "done_when": ["type": ["object", "array"], "description": "Required. Check text, exact field and value, a missing label, or a file. Supply one check or a list."],
                    "values": ["type": "object", "description": "Text to type, field name to text: {\"Name\": \"Ann\"}", "additionalProperties": ["type": "string"]],
                    "line_ending": stringProperty(description: "Optional lf or crlf. Include this ending in guarded values and exact checks when omitted."),
                    "document_path": stringProperty(description: "Optional absolute document path that the guarded window must show."),
                    "expected_values": ["type": "object", "description": "Optional current text for fields you intend to replace. Handoff stops if the expected value does not match.", "additionalProperties": ["type": "string"]],
                    "max_steps": ["type": "integer", "default": 15, "maximum": 30],
                    "time_budget_s": ["type": "number", "default": 60, "maximum": 300],
                ],
                required: ["app", "goal", "done_when"]
            )
        ),
        ToolDefinition(
            name: LocalDecisionTool.name,
            description: "Use to score options locally. Action ranks observed controls, Read picks the next evidence read, and Recover advises after independently checked delivery. Keep actions and verification in their existing tools.",
            annotations: ["readOnlyHint": true],
            inputSchema: objectSchema(properties: [
                "role": stringProperty(description: "Decision role", enumValues: LocalDecisionTool.roles),
                "state": ["type": ["object", "string"], "description": "Observed evidence for the selected role."],
                "question": objectSchema(properties: [
                    "type": stringProperty(description: "Typed choice", enumValues: ["choice"]),
                    "instructions": stringProperty(description: "What the options should decide"),
                    "criteria": ["type": "object", "additionalProperties": ["type": "string"],
                                 "description": "Option IDs mapped to their descriptions."],
                ], required: ["type", "instructions", "criteria"]),
            ], required: ["role", "state", "question"])
        ),
        ToolDefinition(
            name: "browser",
            description: "Use for web pages in an owned background Chrome tab. Find controls with read, then use their labels or current references. For forms, use fill_field, select and check. Use type for key events or appending. Batch related changes with a final check. Read again after uncertain delivery.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "action": stringProperty(
                        description: "What to do",
                        enumValues: ["open", "go", "read", "screenshot", "click", "drag", "type", "fill_field", "copy", "cut", "paste", "key", "hover", "select", "select_text", "check", "uncheck", "scroll", "scroll_into_view", "gesture", "back", "forward", "reload", "wait_for", "tabs", "use_tab", "close_tab", "wait", "location", "info", "outline", "frames", "read_text", "link_destination", "control_state", "value", "upload", "peek"]
                    ),
                    "label": stringProperty(description: "Visible text of the target, e.g. \"Sign in\""),
                    "find": stringProperty(description: "read: only controls and text that mention these words"),
                    "find_exact": stringProperty(description: "read: look up controls by exact accessible name without reading the whole page. Returns labels. Omit find."),
                    "full": ["type": "boolean", "default": false, "description": "read: list about four times as much"],
                    "diff": ["type": "boolean", "default": false, "description": "read: return a shorter change summary when the same tab, document, snapshot mode and control references are still valid."],
                    "if_changed": ["type": "boolean", "default": false, "description": "screenshot: omit the image when it exactly matches the last capture of this tab and URL."],
                    "include_link_urls": ["type": "boolean", "default": false, "description": "read: include HTTP(S) link destinations where exposed by the accessibility tree."],
                    "interactive": ["type": "boolean", "default": false, "description": "read: show controls and their references without surrounding page text. Leave off to read or verify page text."],
                    "index": integerProperty(description: "Element number from read"),
                    "mouse_button": stringProperty(description: "click: pointer button, default left.", enumValues: ["left", "right", "middle"]),
                    "click_count": integerProperty(description: "click: 1 by default. Left button also accepts 2 or 3."),
                    "anchor": stringProperty(description: "Click point on a control.", enumValues: ["center", "left", "right", "top", "bottom"]),
                    "offset_x": numberProperty(description: "Click offset right from the anchor."),
                    "offset_y": numberProperty(description: "Click offset down from the anchor."),
                    "modifiers": ["type": "array", "items": ["type": "string", "enum": ["alt", "ctrl", "cmd", "shift"]],
                                  "description": "click or drag: optional modifier keys."],
                    "kind": stringProperty(description: "Gesture equivalent.", enumValues: GestureAction.allCases.map(\.rawValue)),
                    "dwell_ms": integerProperty(description: "Hover dwell, up to 2000 ms."),
                    "hold_ms": integerProperty(description: "Drag or key hold, up to 1000 ms."),
                    "drag_steps": integerProperty(description: "Drag movement steps, 2 to 30."),
                    "verify": dropVerificationProperty(),
                    "to_x": numberProperty(description: "Drag destination viewport X from screenshot."),
                    "to_y": numberProperty(description: "Drag destination viewport Y from screenshot."),
                    "to_label": stringProperty(description: "drag: destination label in the same tab"),
                    "to_index": integerProperty(description: "drag: destination element number from read"),
                    "text": stringProperty(description: "type or direct paste: content to insert. wait_for: text to wait for."),
                    "format": stringProperty(description: "Direct paste format. Defaults to text when text is supplied. Markdown and HTML require a labeled or indexed rich-text editor.", enumValues: ["text", "markdown", "html"]),
                    "start": integerProperty(description: "select_text start in UTF-16 units."),
                    "length": integerProperty(description: "select_text length in UTF-16 units."),
                    "prefix": stringProperty(description: "Text immediately before a repeated selection."),
                    "suffix": stringProperty(description: "Text immediately after a repeated selection."),
                    "selection": stringProperty(description: "Select text or place the cursor.", enumValues: TextSelectionMode.allCases.map(\.rawValue)),
                    "replace": ["type": "boolean", "default": false, "description": "type: true replaces the field's value"],
                    "option": stringProperty(description: "select: option text or value, e.g. Canada"),
                    "direction": stringProperty(description: "scroll: default down", enumValues: ["up", "down", "left", "right", "top", "bottom"]),
                    "amount": ["type": "number", "description": "Legacy scroll in pixels."],
                    "unit": stringProperty(description: "Scroll chunk unit.", enumValues: ["lines", "pages", "points"]),
                    "step_size": integerProperty(description: "Units per scroll chunk. One for pages."),
                    "max_steps": integerProperty(description: "Scroll chunk limit, up to 20."),
                    "until_visible": stringProperty(description: "Stop scrolling when this exact label is in view."),
                    "condition": stringProperty(description: "wait_for with a label: require this control state.", enumValues: ["visible", "enabled", "checked", "unchecked", "appears", "disappears", "value_changed"]),
                    "from_value": stringProperty(description: "Previous value for a value_changed wait."),
                    "url_contains": stringProperty(description: "wait_for: wait until the actual tab URL contains this text and the page is ready."),
                    "timeout": ["type": "number", "description": "wait_for, wait: seconds, max 30"],
                    "key": stringProperty(description: "key: Enter, Tab, Escape, ArrowDown, or Cmd+A"),
                    "url": stringProperty(description: "open, go: URL, e.g. example.com"),
                    "urls": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 6,
                        "description": "peek: up to 6 URLs",
                    ],
                    "tab_id": integerProperty(description: "Tab ID from tabs. close_tab requires the explicit ID of a tab opened by this connection and never claimed."),
                    "state": stringProperty(description: "wait: load (default) or domcontentloaded", enumValues: ["load", "domcontentloaded"]),
                    "files": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "upload: local file paths. Supply the file input label or index to select directly.",
                    ],
                ],
                required: ["action"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Use to read a Mac app's key window as a numbered element list, starting its session if needed; not for one control (use query). Call first for an app not read this turn. A batch reply already ends with this state. Add include_screenshot only if the list is not enough.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": positiveIntegerProperty(description: "Read this exact window in the running app without changing focus or placement."),
                    "compact": ["type": "boolean", "default": false,
                                "description": "Keep actionable controls and focus, omit extra layout text"],
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "include_ax": ["type": "boolean", "default": true, "description": "False skips the element list and invalidates earlier element numbers."],
                    "include_refs": ["type": "boolean", "default": false, "description": "Return opaque refs for exact native element actions. Requires include_ax."],
                    "include_screenshot": ["type": "boolean", "default": LeanDefaults.includeScreenshot, "description": "Also return a screenshot, e.g. for pixel clicks."],
                    "include_menu_bar": ["type": "boolean", "default": false, "description": "Include the app menu bar in the AX list. For a known menu command, use press_menu."],
                    "visual_queries": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 2, "description": "Optional semantic descriptions of icons or canvas targets. Requires window_id, include_ax and include_screenshot; returns unverified pixel proposals, never acts."],
                    "visual_region": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4, "description": "Optional [x,y,width,height] fractions from top left to restrict visual_queries to a region."],
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
            description: "Use to press a control by label (visible name) or element_index; x and y pixels only when it has no name. Not for typing (type_text) or fields (set_value).",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element number"),
                    "ref": nativeElementRefProperty(),
                    "visual_snapshot": stringProperty(description: "Optional token from visual search. Requires window_id and x/y; rejects changed screenshots."),
                    "x": numberProperty(description: "X pixel from a screenshot"),
                    "y": numberProperty(description: "Y pixel from a screenshot"),
                    "click_count": integerProperty(description: "1 to 32, default 1. sky_click allows 1 or 2."),
                    "anchor": stringProperty(description: "Click point on a control.", enumValues: ["center", "left", "right", "top", "bottom"]),
                    "offset_x": numberProperty(description: "Click offset right from the anchor."),
                    "offset_y": numberProperty(description: "Click offset down from the anchor."),
                    "modifiers": ["type": "array", "items": ["type": "string"], "description": "Click with cmd, shift, alt or ctrl."],
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
            name: "clipboard",
            description: "Use to read, write or clear this client's private clipboard. Use press_key with cmd+c, cmd+x or cmd+v for Mac selections, and browser copy, cut or paste in Chrome.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "action": stringProperty(description: "read, write, or clear"),
                    "text": stringProperty(description: "Plain text for write")
                ],
                required: ["action"]
            )
        ),
        ToolDefinition(
            name: TeachMode.toolName,
            description: "Use to watch Michael do a task in one app and save it as a batch recipe. start (app, goal) records only that app, for up to 10 minutes. stop saves the steps as an unverified recipe and prints them. status says whether recording is on. Text typed into secure fields is never stored.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "action": stringProperty(description: "start, stop or status", enumValues: ["start", "stop", "status"]),
                    "app": stringProperty(description: "App to watch, for start"),
                    "goal": stringProperty(description: "What the task does, for start, e.g. Email Sam the report"),
                ],
                required: ["action"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Use to type literal text into the focused field; to set a field's whole value use set_value. Click the field first. replace: true selects the focused field's text first (search boxes, chat inputs set_value cannot write).",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Text to type"),
                    "replace": ["type": "boolean", "description": "Select the focused field's existing text first, so the typed text replaces it"],
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "text"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: "Use for a key or shortcut, not for menu commands (use press_menu). Press a key or combination: \"Return\", \"Escape\", \"Tab\", \"Down\", \"cmd+s\" (modifiers: cmd, shift, alt, ctrl).",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "key": stringProperty(description: "Key or combination, e.g. \"cmd+s\""),
                    "hold_ms": integerProperty(description: "Hold for up to 1000 ms in the already focused window."),
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
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element number"),
                    "ref": nativeElementRefProperty(),
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
                    "file_path": stringProperty(description: "For Finder File > Duplicate or File > Rename, the absolute path of one file."),
                    "new_name": stringProperty(description: "For path-based Finder Rename, the new filename in the same folder."),
                    "path": stringProperty(description: "Menu title, then items down to the command: \"File > Save\", or [\"File\", \"Save\"]."),
                ],
                required: ["app", "path"]
            )
        ),
        ToolDefinition(
            name: SmartSteps.saveAsName,
            description: "Use to save the front document under a new name; not for a plain Save (press_menu). It does File > Save As… (Save… for an untitled one), then the folder, the name and Save, inside one focus borrow. The reply gives the saved path once the file is on disk; otherwise it gives the reason and any dialog that is open.",
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
            description: "Use to open a file, a web address or an app; not to click through Finder or a dialog. Opens a file in its default app (or app), a web address in the browser tool (url), or launches an app (app alone). Nothing is brought to the front. The reply says what opened.",
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
            description: "Use to scroll an app area. Explicit chunks stop when movement stops or an exact label comes into view.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "direction": stringProperty(description: "Scroll direction: up, down, left, or right"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element identifier"),
                    "ref": nativeElementRefProperty(),
                    "pages": numberProperty(description: "Legacy page estimate. Defaults to 1."),
                    "unit": stringProperty(description: "Verified chunk unit.", enumValues: ["lines", "pages", "points"]),
                    "step_size": integerProperty(description: "Units per chunk. One for pages."),
                    "max_steps": integerProperty(description: "Chunk limit, up to 20."),
                    "until_visible": stringProperty(description: "Exact label inside this scroll area."),
                ],
                required: ["app", "direction"]
            )
        ),
        ToolDefinition(
            name: "scroll_into_view",
            description: "Use to reveal a known Mac control through its accessibility action.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element number"),
                    "label": labelProperty(),
                    "window_id": observedWindowIDProperty(),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "gesture",
            description: "Use for an app gesture equivalent. Give a zoom control or an explicit menu path.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(properties: [
                "app": stringProperty(description: "App name or bundle identifier"),
                "window_id": observedWindowIDProperty(),
                "kind": stringProperty(description: "Gesture equivalent.", enumValues: GestureAction.allCases.map(\.rawValue)),
                "label": labelProperty(),
                "element_index": stringProperty(description: "Control number."),
                "menu_path": stringProperty(description: "App command path, e.g. View > Zoom In."),
            ], required: ["app", "kind"])
        ),
        ToolDefinition(
            name: "wait_for",
            description: "Use to wait for an exact control label or a value change in the observed window.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [
                "app": stringProperty(description: "App name or bundle identifier"),
                "window_id": observedWindowIDProperty(),
                "label": stringProperty(description: "Exact control label."),
                "condition": stringProperty(description: "What to verify.", enumValues: ControlWait.Condition.allCases.map(\.rawValue)),
                "from_value": stringProperty(description: "Previous value for value_changed. Defaults to the first sample."),
                "timeout": integerProperty(description: "Seconds, 1 to 30. Default 10."),
            ], required: ["app", "label", "condition"])
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
            description: "Use to select text in a field by exact text or UTF-16 range. Add prefix or suffix for repeated text.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Text element identifier"),
                    "ref": nativeElementRefProperty(),
                    "start": integerProperty(description: "Start in UTF-16 units."),
                    "length": integerProperty(description: "Length in UTF-16 units. Zero places the cursor."),
                    "text": stringProperty(description: "Target text as shown in the accessibility tree"),
                    "prefix": stringProperty(description: "Optional text immediately before the target, used to disambiguate repeated matches"),
                    "suffix": stringProperty(description: "Optional text immediately after the target, used to disambiguate repeated matches"),
                    "selection": stringProperty(
                        description: "Whether to select the text or place the cursor before or after it. Defaults to text.",
                        enumValues: TextSelectionMode.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Use to run a secondary accessibility action, e.g. AXShowMenu, listed on an element; not for an ordinary press (use click).",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element identifier"),
                    "ref": nativeElementRefProperty(),
                    "action": stringProperty(description: "Secondary accessibility action name, e.g. \"AXShowMenu\""),
                ],
                required: ["app", "action"]
            )
        ),
        ToolDefinition(
            name: "hover",
            description: "Use to hover over a control and read its tooltip or hover state. Set dwell_ms for delayed menus.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "label": labelProperty(),
                    "element_index": stringProperty(description: "Element number"),
                    "ref": nativeElementRefProperty(),
                    "dwell_ms": integerProperty(description: "Hover dwell, up to 2000 ms."),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: "Use to drag controls or screenshot points inside one window. Add a batch check to verify the drop.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "window_id": observedWindowIDProperty(),
                    "visual_snapshot": stringProperty(description: "Optional token from visual search. Requires window_id and explicit pixel endpoints; rejects changed screenshots."),
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "from_label": stringProperty(description: "Source control label."),
                    "from_index": integerProperty(description: "Source control reference."),
                    "to_label": stringProperty(description: "Destination control label."),
                    "to_index": integerProperty(description: "Destination control reference."),
                    "hold_ms": integerProperty(description: "Hold before moving, up to 1000 ms."),
                    "drag_steps": integerProperty(description: "Movement steps, 2 to 30."),
                    "verify": dropVerificationProperty(),
                    "from_x": numberProperty(description: "Start X coordinate"),
                    "from_y": numberProperty(description: "Start Y coordinate"),
                    "to_x": numberProperty(description: "End X coordinate"),
                    "to_y": numberProperty(description: "End Y coordinate"),
                    "modifiers": ["type": "array", "items": ["type": "string"],
                                  "description": "Optional shift, option, command, or control during the drag"],
                ],
                required: ["app"]
            )
        ),
    ]
}

/// Shared by every element action: the element's visible name, so a model need not count indexes.
private func observedWindowIDProperty() -> [String: Any] {
    [
        "type": "integer", "minimum": 1, "maximum": UInt32.max,
        "description": "Window ID from get_app_state or query; refuses if the target changed."
    ]
}

private func nativeElementRefProperty() -> [String: Any] {
    stringProperty(description: "Exact ref from get_app_state with include_refs. Use instead of label, index or pixels.")
}

private func dropVerificationProperty() -> [String: Any] {
    objectSchema(properties: [
        "label": stringProperty(description: "Expected control."),
        "condition": stringProperty(description: "Drop check.", enumValues: ControlWait.Condition.allCases.map(\.rawValue)),
        "from_value": stringProperty(description: "Previous value for value_changed."),
        "timeout": integerProperty(description: "Seconds, up to 30."),
    ], required: ["label", "condition"])
}

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
