import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// User-local preferences only. No permission grants, daemon changes or input actions.
public enum GodspeedTerminalSettings {
    struct Item {
        let key: String
        let name: String
        let group: String
        let fallback: String
        let environment: String?
        let kind: Kind

        enum Kind { case toggle, choice([String]), color, endpoint(allowEmpty: Bool) }
    }

    static let items: [Item] = [
        .init(key: "cursor_visible", name: "Show agent cursor", group: "APPEARANCE", fallback: "on", environment: "OPEN_COMPUTER_USE_VISUAL_CURSOR", kind: .toggle),
        .init(key: "cursor_speed", name: "Cursor speed", group: "APPEARANCE", fallback: "normal", environment: "OPEN_COMPUTER_USE_CURSOR_SPEED", kind: .choice(["calm", "normal", "fast", "instant"])),
        .init(key: "cursor_color", name: "Cursor color", group: "APPEARANCE", fallback: "default", environment: "OPEN_COMPUTER_USE_CURSOR_COLOR", kind: .color),
        .init(key: "cursor_lens", name: "Cursor lens", group: "APPEARANCE", fallback: "off", environment: "OPEN_COMPUTER_USE_CURSOR_LENS", kind: .toggle),
        .init(key: "recipes", name: "Verified recipes", group: "INTELLIGENCE", fallback: "on", environment: "OPEN_COMPUTER_USE_RECIPES", kind: .toggle),
        .init(key: "decision_hints", name: "Decision hints", group: "INTELLIGENCE", fallback: "off", environment: "OPEN_COMPUTER_USE_REFEREE_URL", kind: .toggle),
        .init(key: "find_on_screen", name: "Visual grounding", group: "INTELLIGENCE", fallback: "off", environment: "OPEN_COMPUTER_USE_VISION_URL", kind: .toggle),
        .init(key: "helper_url", name: "Vision / decision helper", group: "INTELLIGENCE", fallback: "http://127.0.0.1:8765", environment: nil, kind: .endpoint(allowEmpty: false)),
        .init(key: "gsd1_url", name: "GSD1 advisory helper", group: "INTELLIGENCE", fallback: "off", environment: "OPEN_COMPUTER_USE_GSD1_URL", kind: .endpoint(allowEmpty: true)),
        .init(key: "compact_reads", name: "Compact observations", group: "EXECUTION", fallback: "off", environment: "OPEN_COMPUTER_USE_COMPACT_READS", kind: .toggle),
        .init(key: "screenshots_by_default", name: "Screenshots by default", group: "EXECUTION", fallback: "off", environment: "OPEN_COMPUTER_USE_DEFAULT_SCREENSHOT", kind: .toggle),
        .init(key: "browser", name: "Browser integration", group: "EXECUTION", fallback: "auto", environment: "OPEN_COMPUTER_USE_BROWSER", kind: .choice(["auto", "on", "off"])),
        .init(key: "strict_background", name: "Accessibility-only mode", group: "EXECUTION", fallback: "off", environment: "OPEN_COMPUTER_USE_STRICT_BACKGROUND", kind: .toggle),
    ]

    enum Failure: LocalizedError {
        case invalid(String)
        case changed
        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            case .changed: return "Settings changed on disk. Nothing saved; reopen the menu to avoid overwriting another editor."
            }
        }
    }

    /// Keep the original bytes for conflict detection and retain unknown settings.
    struct Draft {
        let url: URL
        var original: Data?
        var values: [String: Any]
        var changed = false

        init(url: URL) throws {
            self.url = url
            original = try Self.read(url)
            if let original {
                guard let decoded = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw Failure.invalid("Settings must be a JSON object. Repair the file before editing.")
                }
                values = decoded
            } else {
                values = [:]
            }
        }

        private static func read(_ url: URL) throws -> Data? {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw Failure.invalid("Cannot inspect settings file.")
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
                  info.st_size <= 1024 * 1024 else {
                throw Failure.invalid("Settings must be a user-owned regular file of at most 1 MiB.")
            }
            return try Data(contentsOf: url)
        }

        mutating func apply(_ item: Item, input: String) throws {
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()
            if lower == "reset" || (item.key == "browser" && lower == "auto") {
                if values.removeValue(forKey: item.key) != nil { changed = true }
                return
            }
            let next: Any
            switch item.kind {
            case .toggle:
                guard ["on", "off"].contains(lower) else { throw Failure.invalid("Choose on, off, or reset.") }
                next = lower == "on"
            case .choice(let options):
                guard options.contains(lower) else { throw Failure.invalid("Choose " + options.joined(separator: " / ") + ".") }
                next = item.key == "browser" ? (lower == "on") as Any : lower as Any
            case .color:
                guard ["default", "auto"].contains(lower) || value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                    throw Failure.invalid("Choose default, auto, or #RRGGBB.")
                }
                next = lower
            case .endpoint(let allowEmpty):
                if allowEmpty, lower == "off" {
                    if values.removeValue(forKey: item.key) != nil { changed = true }
                    return
                }
                guard value.utf8.count <= 256, let parts = URLComponents(string: value),
                      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                      ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host?.lowercased() ?? ""),
                      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                      parts.port.map({ (1...65535).contains($0) }) ?? true else {
                    throw Failure.invalid("Enter a loopback HTTP(S) URL without credentials, query or fragment.")
                }
                next = value
            }
            values[item.key] = next
            changed = true
        }

        mutating func save() throws {
            guard changed else { return }
            guard try Self.read(url) == original else { throw Failure.changed }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw Failure.invalid("Settings directory must be user-owned and not writable by others.")
            }
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            let output = data + Data([10])
            // A private temporary file on the same filesystem, then a single atomic rename.
            var template = Array(directory.appendingPathComponent(".settings.XXXXXX").path.utf8CString)
            let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
            guard descriptor >= 0 else { throw Failure.invalid("Cannot create a private settings file.") }
            let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                _ = unlink(temporary)
            }
            try handle.write(contentsOf: output)
            try handle.synchronize()
            guard try Self.read(url) == original else { throw Failure.changed }
            guard rename(temporary, url.path) == 0 else { throw Failure.invalid("Could not replace the settings file.") }
            original = output
            changed = false
        }
    }

    static func shown(_ item: Item, values: [String: Any]) -> String {
        guard let value = values[item.key] else { return item.fallback }
        if let boolean = value as? Bool, item.key != "cursor_speed" { return boolean ? "on" : "off" }
        if let string = value as? String {
            // A manually edited file must not inject terminal escape sequences or disclose URL credentials.
            if case .endpoint = item.kind {
                guard let parts = URLComponents(string: string), parts.user == nil, parts.password == nil,
                      parts.query == nil, parts.fragment == nil else { return "(custom URL)" }
            }
            return String(string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80))
        }
        if let number = value as? NSNumber { return number.stringValue }
        return "(custom)"
    }

    static func menu(values: [String: Any], environment: [String: String], dirty: Bool) -> String {
        var lines = ["GODSPEED  /  SETTINGS", "Local preferences · " + (dirty ? "unsaved changes" : "saved")]
        var group = ""
        for (index, item) in items.enumerated() {
            if group != item.group {
                group = item.group
                lines += ["", group]
            }
            let number = String(format: "%2d", index + 1)
            let override = item.environment.map { environment[$0] != nil } == true
            lines.append("  " + number + "  " + item.name.padding(toLength: 26, withPad: " ", startingAt: 0)
                         + shown(item, values: values) + (override ? "  [env override]" : ""))
        }
        lines += ["", "  [1–13] edit    [s] save    [q] discard / exit",
                  "  Environment overrides take priority. Reconnect clients if needed.",
                  "  The standard MCP launcher keeps background-only delivery enabled."]
        return lines.joined(separator: "\n")
    }

    public static func run(arguments: [String]) throws {
        if arguments == ["--help"] || arguments == ["-h"] {
            print("Usage: godspeed settings [--show]\nEdit local Godspeed preferences, or print them without editing.")
            return
        }
        guard arguments.isEmpty || arguments == ["--show"] else {
            throw Failure.invalid("Usage: godspeed settings [--show]")
        }
        var draft = try Draft(url: GodspeedSettings.fileURL)
        let environment = ProcessInfo.processInfo.environment
        if arguments == ["--show"] {
            print(menu(values: draft.values, environment: environment, dirty: false))
            return
        }
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            throw Failure.invalid("Settings editing requires an interactive terminal. Use --show for read-only output.")
        }
        let redraw = environment["TERM"] != "dumb" && environment["TERM"] != nil && environment["NO_COLOR"] == nil
        var notice = ""
        while true {
            if redraw { print("\u{001B}[2J\u{001B}[H", terminator: "") }
            print(menu(values: draft.values, environment: environment, dirty: draft.changed))
            if !notice.isEmpty { print("\n" + notice) }
            print("\n> ", terminator: "")
            fflush(stdout)
            guard let command = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return }
            notice = ""
            if command == "q" {
                if draft.changed { print("Unsaved changes discarded.") }
                return
            }
            if command == "s" {
                try draft.save()
                print("Saved to ~/.godspeed/settings.json.")
                return
            }
            guard let number = Int(command), items.indices.contains(number - 1), number > 0 else {
                notice = "Choose a setting number, s, or q."
                continue
            }
            let item = items[number - 1]
            if case .toggle = item.kind {
                try draft.apply(item, input: shown(item, values: draft.values) == "on" ? "off" : "on")
                continue
            }
            let hint: String
            switch item.kind {
            case .toggle: hint = "on / off"
            case .choice(let options): hint = options.joined(separator: " / ")
            case .color: hint = "default / auto / #RRGGBB"
            case .endpoint(let allowEmpty): hint = allowEmpty ? "loopback URL / off" : "loopback URL"
            }
            print("\(item.name) (\(hint), reset; Enter cancels): ", terminator: "")
            fflush(stdout)
            guard let input = readLine() else { return }
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            do { try draft.apply(item, input: input) }
            catch { notice = error.localizedDescription }
        }
    }
}
