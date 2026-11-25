import CoreFoundation
import Foundation

/// GODSPEED preferences, edited by `godspeed settings`, stored in `~/.godspeed/settings.json`.
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
///       "browser": true,                   -> OPEN_COMPUTER_USE_BROWSER
///       "background_only": true,            -> OPEN_COMPUTER_USE_BACKGROUND_ONLY
///       "strict_background": true          -> OPEN_COMPUTER_USE_STRICT_BACKGROUND
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
        merged(base, settings: cache.load())
    }

    static func merged(_ base: [String: String], settings: [String: Any]) -> [String: String] {
        var result = base
        for (key, value) in mappedVariables(from: settings) where result[key] == nil {
            // A client's explicit referee endpoint also selects its handoff service unless
            // it supplies a separate handoff endpoint. A saved helper URL must not mask it.
            if key == "OPEN_COMPUTER_USE_HANDOFF_URL", base["OPEN_COMPUTER_USE_REFEREE_URL"] != nil { continue }
            result[key] = value
        }
        return result
    }

    /// The settings file translated into GODSPEED environment variables.
    static func mappedVariables(from settings: [String: Any]) -> [String: String] {
        var variables: [String: String] = [:]
        func flag(_ key: String) -> String? {
            guard let number = settings[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue ? "1" : "0"
        }
        if let value = settings["gsd1_url"] as? String {
            variables["OPEN_COMPUTER_USE_GSD1_URL"] = value
        }
        if let value = flag("cursor_visible") { variables["OPEN_COMPUTER_USE_VISUAL_CURSOR"] = value }
        if let color = settings["cursor_color"] as? String, !color.isEmpty {
            variables["OPEN_COMPUTER_USE_CURSOR_COLOR"] = color
        }
        if let name = settings["cursor_name"] as? String {
            variables["OPEN_COMPUTER_USE_CURSOR_NAME"] = name
        }
        if let motion = settings["cursor_motion"] as? String, ["system", "reduced"].contains(motion) {
            variables["OPEN_COMPUTER_USE_CURSOR_MOTION"] = motion
        }
        if let seconds = settings["cursor_idle_hide_seconds"] as? NSNumber,
           CFGetTypeID(seconds) != CFBooleanGetTypeID(),
           seconds.doubleValue.isFinite, (0.2...60).contains(seconds.doubleValue) {
            variables["OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS"] = seconds.stringValue
        }
        if let speed = settings["cursor_speed"] {
            switch (speed as? String)?.lowercased() {
            case "calm": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "2"
            case "normal": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "4"
            case "fast": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "8"
            case "instant": variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = "instant"
            default:
                if let number = speed as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                   number.doubleValue.isFinite, number.doubleValue > 0 {
                    variables["OPEN_COMPUTER_USE_CURSOR_SPEED"] = number.stringValue
                }
            }
        }
        if let value = flag("screenshots_by_default") { variables["OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT"] = value }
        let helper = (settings["helper_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:8765"
        if let configured = settings["helper_url"] as? String, !configured.isEmpty {
            variables["OPEN_COMPUTER_USE_HANDOFF_URL"] = configured
        }
        if flag("decision_hints") == "1" { variables["OPEN_COMPUTER_USE_REFEREE_URL"] = helper }
        if flag("find_on_screen") == "1" { variables["OPEN_COMPUTER_USE_VISION_URL"] = helper }
        if let value = flag("cursor_lens") { variables["OPEN_COMPUTER_USE_CURSOR_LENS"] = value }
        if let value = flag("cursor_feedback") { variables["OPEN_COMPUTER_USE_CURSOR_FEEDBACK"] = value }
        if let value = flag("cursor_label") { variables["OPEN_COMPUTER_USE_CURSOR_LABEL"] = value }
        if let value = flag("cursor_float") { variables["OPEN_COMPUTER_USE_CURSOR_FLOAT"] = value }
        if let value = flag("model_helpers") { variables["OPEN_COMPUTER_USE_MODEL_HELPERS"] = value }
        if let value = flag("handoff_helper") { variables["OPEN_COMPUTER_USE_HANDOFF_HELPER"] = value }
        if let value = flag("recipes") { variables["OPEN_COMPUTER_USE_RECIPES"] = value }
        if let value = flag("strict_background") { variables["OPEN_COMPUTER_USE_STRICT_BACKGROUND"] = value }
        if let value = flag("compact_reads") { variables["OPEN_COMPUTER_USE_COMPACT_READS"] = value }
        if let value = flag("batch_diff") { variables["OPEN_COMPUTER_USE_BATCH_DIFF"] = value }
        if let value = flag("semantic_replies") { variables["OPEN_COMPUTER_USE_SEMANTIC_REPLIES"] = value }
        if let value = flag("learning_log") { variables["OPEN_COMPUTER_USE_LEARNING_LOG"] = value }
        if let value = flag("learning_log_images") { variables["OPEN_COMPUTER_USE_LEARNING_LOG_IMAGES"] = value }
        if let value = flag("trajectory_log") { variables["OPEN_COMPUTER_USE_TRAJECTORY_LOG"] = value }
        if let value = flag("debug_timing") { variables["OPEN_COMPUTER_USE_DEBUG_TIMING"] = value }
        if let value = flag("background_only") { variables["OPEN_COMPUTER_USE_BACKGROUND_ONLY"] = value }
        if let value = flag("relay_grant") { variables["OPEN_COMPUTER_USE_RELAY_GRANT"] = value }
        if let value = flag("browser") { variables["OPEN_COMPUTER_USE_BROWSER"] = value }
        return variables
    }

    private static let cache = SettingsFileCache()
}

/// Atomic replacements can preserve modification dates. Include file identity and size, and keep
/// the last valid preferences while an editor is halfway through a write. Deletion resets defaults.
final class SettingsFileCache: @unchecked Sendable {
    private struct Signature: Equatable {
        let fileNumber: UInt64
        let size: UInt64
        let modified: Date?
    }

    private let lock = NSLock()
    private let url: URL
    private let clock: () -> TimeInterval
    private let readAttributes: (URL) throws -> [FileAttributeKey: Any]
    private var signature: Signature?
    private var checked: TimeInterval?
    private var values: [String: Any] = [:]

    init(url: URL = GodspeedSettings.fileURL,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         attributes: @escaping (URL) throws -> [FileAttributeKey: Any] = {
             try FileManager.default.attributesOfItem(atPath: $0.path)
         }) {
        self.url = url
        self.clock = clock
        readAttributes = attributes
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == CocoaError.Code.fileNoSuchFile.rawValue
                || error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
        }
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(POSIXErrorCode.ENOENT.rawValue)
                || error.code == Int(POSIXErrorCode.ENOTDIR.rawValue)
        }
        return false
    }

    func load() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        // A stat at most every half second keeps per-action cost negligible.
        let now = clock()
        if let checked, now >= checked, now - checked < 0.5 { return values }
        checked = now
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try readAttributes(url)
        } catch {
            // fileExists also returns false for inaccessible paths. Only positive evidence of
            // deletion may reset preferences; a permission or I/O failure must not re-enable
            // helpers (or other defaults) the user previously disabled.
            if Self.isMissing(error) {
                values = [:]
                signature = nil
            }
            return values
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= 1_048_576 else { return values }
        let current = Signature(fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                                size: size.uint64Value, modified: attributes[.modificationDate] as? Date)
        guard current != signature else { return values }
        // A failed read is retried next time, even if a correcting write keeps the same timestamp.
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return values }
        values = object
        signature = current
        return values
    }
}
