import Foundation

/// GODSPEED settings the user picks in PURE (Settings > GODSPEED), stored in `~/.godspeed/settings.json`.
/// Each setting maps onto the environment variable GODSPEED already understands; a variable that is set
/// in the process environment always wins, so harnesses and agent configs keep full control.
///
///     {
///       "cursor_visible": true,            -> OPEN_COMPUTER_USE_VISUAL_CURSOR
///       "cursor_color": "#2F6FDE",         -> OPEN_COMPUTER_USE_CURSOR_COLOR ("default" = the original grey)
///       "cursor_lens": true,               -> OPEN_COMPUTER_USE_CURSOR_LENS (the glass pointer magnifies what is under it)
///       "cursor_speed": "normal",          -> OPEN_COMPUTER_USE_CURSOR_SPEED (calm 2, normal 4, fast 8, instant)
///       "screenshots_by_default": false,   -> OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT
///       "decision_hints": false,           -> OPEN_COMPUTER_USE_REFEREE_URL = helper_url
///       "find_on_screen": false,           -> OPEN_COMPUTER_USE_VISION_URL = helper_url
///       "helper_url": "http://127.0.0.1:8765",
///       "recipes": true,                   -> OPEN_COMPUTER_USE_RECIPES
///       "browser": true                    -> OPEN_COMPUTER_USE_BROWSER
///     }
///
/// The file is checked for changes as requests read settings.
enum GodspeedSettings {
    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".godspeed/settings.json")
    }

    /// The request environment with the settings file filled in underneath it.
    static var environment: [String: String] {
        merged(RequestConfiguration.environment)
    }

    /// `base` with every setting from the file added where `base` does not already set that variable.
    static func merged(_ base: [String: String]) -> [String: String] {
        var result = base
        for (key, value) in mappedVariables(from: cache.load()) where result[key] == nil {
            result[key] = value
        }
        return result
    }

    /// The settings file translated into GODSPEED environment variables.
    static func mappedVariables(from settings: [String: Any]) -> [String: String] {
        var variables: [String: String] = [:]
        func flag(_ key: String) -> String? {
            (settings[key] as? Bool).map { $0 ? "1" : "0" }
        }
        if let value = flag("cursor_visible") { variables["OPEN_COMPUTER_USE_VISUAL_CURSOR"] = value }
        if let color = settings["cursor_color"] as? String, !color.isEmpty, color.lowercased() != "default" {
            variables["OPEN_COMPUTER_USE_CURSOR_COLOR"] = color
        }
        if let speed = settings["cursor_speed"] {
            switch (speed as? String)?.lowercased() {
            case "calm": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "2"
            case "normal": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "4"
            case "fast": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "8"
            case "instant": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "instant"
            default:
                if let number = speed as? NSNumber { variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = number.stringValue }
            }
        }
        if let value = flag("screenshots_by_default") { variables["OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT"] = value }
        let helper = (settings["helper_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:8765"
        if (settings["decision_hints"] as? Bool) == true { variables["OPEN_COMPUTER_USE_REFEREE_URL"] = helper }
        if (settings["find_on_screen"] as? Bool) == true { variables["OPEN_COMPUTER_USE_VISION_URL"] = helper }
        if let value = flag("cursor_lens") { variables["OPEN_COMPUTER_USE_CURSOR_LENS"] = value }
        if let value = flag("recipes") { variables["OPEN_COMPUTER_USE_RECIPES"] = value }
        if let value = flag("browser") { variables["OPEN_COMPUTER_USE_BROWSER"] = value }
        return variables
    }

    private static let cache = SettingsFileCache()
}

/// Re-reads the settings file only when its modification date changes.
private final class SettingsFileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var modified: Date?
    private var checked: TimeInterval = 0
    private var values: [String: Any] = [:]

    func load() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        // A stat at most every half second keeps per-action cost negligible.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - checked > 0.5 else { return values }
        checked = now
        let url = GodspeedSettings.fileURL
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard date != modified else { return values }
        modified = date
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = object
        } else {
            values = [:]
        }
        return values
    }
}
