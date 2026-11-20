import Foundation

enum StrictBackground {
    @TaskLocal static var requested = false

    static func enabled(environment: [String: String] = GodspeedSettings.environment) -> Bool {
        requested || enabledFlag(environment["OPEN_COMPUTER_USE_STRICT_BACKGROUND"])
    }

    static func enabledFlag(_ value: String?) -> Bool {
        ["1", "true", "yes", "on"].contains(value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    static func requestedBy(_ name: String, arguments: [String: Any]) -> Bool {
        if arguments["strict_background"] as? Bool == true { return true }
        guard name == BatchTool.name || name == "browser" else { return false }
        func containsRequest(_ steps: [Any]) -> Bool {
            steps.contains { item in
                guard let step = item as? [String: Any] else { return false }
                if step["strict_background"] as? Bool == true { return true }
                if let nested = (step["args"] ?? step["arguments"]) as? [String: Any],
                   nested["strict_background"] as? Bool == true { return true }
                return containsRequest(step["steps"] as? [Any] ?? [])
            }
        }
        return containsRequest(arguments["steps"] as? [Any] ?? [])
    }

    static func validate(_ tool: String, arguments: [String: Any]) throws {
        guard enabled() else { return }
        switch tool {
        case BatchTool.name:
            if arguments["foreground"] as? Bool == true {
                throw ComputerUseError.backgroundUnsupported("This batch requests foreground focus.")
            }
        case "open":
            switch SmartSteps.openPlan(path: arguments["path"] as? String, url: arguments["url"] as? String,
                                      app: arguments["app"] as? String, home: NSHomeDirectory()) {
            case .url, nil: break // Web URLs use the browser's own route check.
            default: throw ComputerUseError.backgroundUnsupported("Opening an app, file or app link can change foreground focus.")
            }
        case "press_key", "press_menu", "save_as", "drag", "perform_secondary_action":
            throw ComputerUseError.backgroundUnsupported("\(tool) has no strict background route.")
        case "get_app_state":
            if let placement = arguments["window_placement"] as? String, placement.lowercased() != "keep" {
                throw ComputerUseError.backgroundUnsupported("This observation requests window placement.")
            }
        case "click":
            let method = (arguments["click_method"] as? String ?? "auto").lowercased()
            let button = (arguments["mouse_button"] as? String ?? "left").lowercased()
            guard ["", "auto", "accessibility"].contains(method), button == "left",
                  !["x", "y"].contains(where: { arguments[$0] != nil }) else {
                throw ComputerUseError.backgroundUnsupported("Strict background clicks need an accessibility element.")
            }
        case "type_text":
            let replace = arguments["replace"] ?? arguments["replace_existing"] ?? arguments["clear"] ?? arguments["clear_first"]
            let method = (arguments["key_method"] as? String ?? "auto").lowercased()
            guard ["", "auto"].contains(method), replace as? Bool != true,
                  !enabledFlag(replace as? String) else {
                throw ComputerUseError.backgroundUnsupported("This typing request needs keyboard events.")
            }
        default:
            break
        }
    }
}
