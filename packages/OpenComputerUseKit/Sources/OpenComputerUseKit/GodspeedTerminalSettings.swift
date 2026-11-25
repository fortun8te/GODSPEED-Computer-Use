import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// User-local preferences only. No permission grants, daemon changes or input actions.
public enum GodspeedTerminalSettings {
    enum Section: Int, CaseIterable, Sendable {
        case cursor, compute, workspace, privacy

        var title: String {
            switch self {
            case .cursor: return "Cursor & appearance"
            case .compute: return "Local compute"
            case .workspace: return "Background & observation"
            case .privacy: return "Privacy & diagnostics"
            }
        }

        var summary: String {
            switch self {
            case .cursor: return "Colour, motion, feedback and identity"
            case .compute: return "Recipes and optional model helpers"
            case .workspace: return "Quiet operation and concise reads"
            case .privacy: return "Local records and timing"
            }
        }
    }

    struct Item: Sendable {
        let key: String
        let name: String
        let section: Section
        let fallback: String
        let environment: String?
        let kind: Kind
        let help: String

        enum Kind: Sendable {
            case toggle, choice([String]), color, endpoint(allowEmpty: Bool), name, seconds
        }

        init(_ key: String, _ name: String, _ section: Section, fallback: String,
             environment: String?, kind: Kind, help: String) {
            self.key = key
            self.name = name
            self.section = section
            self.fallback = fallback
            self.environment = environment.map { "OPEN_COMPUTER_USE_" + $0 }
            self.kind = kind
            self.help = help
        }
    }

    static let items: [Item] = [
        .init("cursor_visible", "Show agent cursor", .cursor, fallback: "on",
              environment: "VISUAL_CURSOR", kind: .toggle,
              help: "Show a separate, click-through agent cursor. Your real pointer stays yours."),
        .init("cursor_color", "Accent colour", .cursor, fallback: "auto",
              environment: "CURSOR_COLOR", kind: .color,
              help: "Choose a fixed accent, original graphite, or a stable automatic colour for each client."),
        .init("cursor_speed", "Travel speed", .cursor, fallback: "normal",
              environment: "CURSOR_SPEED", kind: .choice(["calm", "normal", "fast", "instant"]),
              help: "Set the pace of the drawn cursor. Actions do not wait for cursor animation. Instant skips travel and click pulses."),
        .init("cursor_motion", "Motion", .cursor, fallback: "system",
              environment: "CURSOR_MOTION", kind: .choice(["system", "reduced"]),
              help: "System uses smooth movement and respects macOS Reduce Motion. Reduced removes travel and lean."),
        .init("cursor_feedback", "Action feedback", .cursor, fallback: "on",
              environment: "CURSOR_FEEDBACK", kind: .toggle,
              help: "Show click and typing indications. Turn this off for a quieter cursor."),
        .init("cursor_label", "Name tag", .cursor, fallback: "on",
              environment: "CURSOR_LABEL", kind: .toggle,
              help: "Show the client name beside its cursor so overlapping agents are easier to identify."),
        .init("cursor_name", "Cursor name", .cursor, fallback: "auto",
              environment: "CURSOR_NAME", kind: .name,
              help: "Use a nickname or auto for the connected client's name. Start with a letter; use up to 20 letters, digits, spaces or hyphens."),
        .init("cursor_idle_hide_seconds", "Hide after idle", .cursor, fallback: "6",
              environment: "CURSOR_IDLE_HIDE_SECONDS", kind: .seconds,
              help: "Seconds before the parked cursor disappears after the last action. Choose 0.2 to 60. Ending the turn clears it sooner."),
        .init("cursor_lens", "Magnifying lens", .cursor, fallback: "off",
              environment: "CURSOR_LENS", kind: .toggle,
              help: "Magnify a local crop beneath the pointer. This adds capture work; leave it off for lighter operation."),
        .init("cursor_float", "Show above other windows", .cursor, fallback: "off",
              environment: "CURSOR_FLOAT", kind: .toggle,
              help: "Off keeps the cursor with its target window, behind your work. On lets it appear over other windows."),
        .init("model_helpers", "Model helpers", .compute, fallback: "on",
              environment: "MODEL_HELPERS", kind: .toggle,
              help: "Master switch for optional Godspeed model calls, warmups and auto-start. Off keeps accessibility, OCR and verified recipes available. It does not change the model in your connected agent."),
        .init("recipes", "Verified recipes", .compute, fallback: "on",
              environment: "RECIPES", kind: .toggle,
              help: "Reuse verified local workflows with fresh target checks instead of asking a model to select every step."),
        .init("handoff_helper", "Handoff chooser", .compute, fallback: "on",
              environment: "HANDOFF_HELPER", kind: .toggle,
              help: "Allow the local chooser when a handoff cannot proceed deterministically. Exact actions and verified recipes still work when this is off."),
        .init("decision_hints", "Decision hints", .compute, fallback: "off",
              environment: "REFEREE_URL", kind: .toggle,
              help: "Request optional local model advice after a batch. Advice does not itself send input."),
        .init("find_on_screen", "Vision fallback", .compute, fallback: "off",
              environment: "VISION_URL", kind: .toggle,
              help: "Allow the local vision helper after accessibility and local OCR cannot resolve a target."),
        .init("helper_url", "Local helper URL", .compute, fallback: "http://127.0.0.1:8765",
              environment: nil, kind: .endpoint(allowEmpty: false),
              help: "Base URL of the loopback vision, decision and handoff service. Changing this does not download or install a model."),
        .init("gsd1_url", "GSD1 advisory helper", .compute, fallback: "off",
              environment: "GSD1_URL", kind: .endpoint(allowEmpty: true),
              help: "Optional loopback GSD1 scoring service. It returns advice; it does not deliver actions."),
        .init("background_only", "Keep apps in background", .workspace, fallback: "off",
              environment: "BACKGROUND_ONLY", kind: .toggle,
              help: "Prevent app activation and window raising. Standard MCP launchers always enforce this, regardless of the saved value."),
        .init("strict_background", "Strict background mode", .workspace, fallback: "off",
              environment: "STRICT_BACKGROUND", kind: .toggle,
              help: "Refuse native routes that need temporary keyboard focus or foreground delivery. Some apps and actions will be unavailable."),
        .init("browser", "Browser integration", .workspace, fallback: "auto",
              environment: "BROWSER", kind: .choice(["auto", "on", "off"]),
              help: "Auto enables browser tools when the browser helper is available. On still requires that helper to be installed."),
        .init("compact_reads", "Compact observations", .workspace, fallback: "off",
              environment: "COMPACT_READS", kind: .toggle,
              help: "Send smaller observations while retaining actionable element references and verification evidence."),
        .init("screenshots_by_default", "Screenshots on reads", .workspace, fallback: "off",
              environment: "DEFAULT_SCREENSHOT", kind: .toggle,
              help: "Attach a screenshot to ordinary app-state reads. Off keeps reads lighter; explicit screenshots remain available."),
        .init("batch_diff", "Change-only batch replies", .workspace, fallback: "on",
              environment: "BATCH_DIFF", kind: .toggle,
              help: "Return what changed after a batch when a compact difference is sufficient."),
        .init("semantic_replies", "Change summaries", .workspace, fallback: "on",
              environment: "SEMANTIC_REPLIES", kind: .toggle,
              help: "Add concise, locally computed change summaries to longer batch replies."),
        .init("learning_log", "Local learning records", .privacy, fallback: "on",
              environment: "LEARNING_LOG", kind: .toggle,
              help: "Keep scrubbed local workflow and helper records for evaluation. Disabling new records does not remove existing files."),
        .init("learning_log_images", "Keep helper image crops", .privacy, fallback: "off",
              environment: "LEARNING_LOG_IMAGES", kind: .toggle,
              help: "Save eligible crops already used by the vision helper in local learning records. Requires learning records; off by default."),
        .init("trajectory_log", "Outcome & timing records", .privacy, fallback: "on",
              environment: "TRAJECTORY_LOG", kind: .toggle,
              help: "Record tool outcomes and timing locally. Default records omit UI text, arguments and screenshots. Reconnect clients after changing this."),
        .init("debug_timing", "Timing on stderr", .privacy, fallback: "off",
              environment: "DEBUG_TIMING", kind: .toggle,
              help: "Print diagnostic timing counters to stderr. Useful for profiling; leave off for normal use."),
    ]

    struct Accent: Sendable {
        let name: String
        let value: String
        let swatch: String
    }

    static let accents: [Accent] = [
        .init(name: "Auto", value: "auto", swatch: "#a1a1aa"),
        .init(name: "Graphite", value: "default", swatch: "#9ca3af"),
        .init(name: "Blue", value: "#2f6fde", swatch: "#2f6fde"),
        .init(name: "Violet", value: "#8b5cf6", swatch: "#8b5cf6"),
        .init(name: "Pink", value: "#ec4899", swatch: "#ec4899"),
        .init(name: "Coral", value: "#fb7185", swatch: "#fb7185"),
        .init(name: "Amber", value: "#f59e0b", swatch: "#f59e0b"),
        .init(name: "Mint", value: "#34d399", swatch: "#34d399"),
        .init(name: "Teal", value: "#14b8a6", swatch: "#14b8a6"),
        .init(name: "Sky", value: "#38bdf8", swatch: "#38bdf8"),
    ]

    struct Edit: Sendable {
        let key: String
        let input: String
    }

    struct Preset: Sendable {
        let name: String
        let detail: String
        let edits: [Edit]
    }

    static let presets: [Preset] = [
        .init(name: "Model-free", detail: "Local accessibility, OCR and recipes; optional model helpers disabled.", edits: [
            .init(key: "model_helpers", input: "off"), .init(key: "recipes", input: "on"),
            .init(key: "compact_reads", input: "on"), .init(key: "screenshots_by_default", input: "off"),
            .init(key: "batch_diff", input: "on"),
        ]),
        .init(name: "Quiet", detail: "Stay behind your work, with fewer effects and a shorter idle cursor.", edits: [
            .init(key: "background_only", input: "on"), .init(key: "cursor_float", input: "off"),
            .init(key: "cursor_lens", input: "off"), .init(key: "cursor_idle_hide_seconds", input: "2"),
            .init(key: "cursor_feedback", input: "off"),
        ]),
        .init(name: "Balanced", detail: "Smooth, visible progress with background delivery and concise reads.", edits: [
            .init(key: "background_only", input: "on"), .init(key: "cursor_float", input: "off"),
            .init(key: "cursor_speed", input: "normal"), .init(key: "cursor_motion", input: "system"),
            .init(key: "cursor_label", input: "on"), .init(key: "cursor_feedback", input: "on"),
            .init(key: "cursor_idle_hide_seconds", input: "6"), .init(key: "recipes", input: "on"),
            .init(key: "compact_reads", input: "on"),
        ]),
    ]

    enum Failure: LocalizedError {
        case invalid(String)
        case changed
        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            case .changed: return "Settings changed on disk. Nothing saved. Reopen the menu to keep the other editor's changes."
            }
        }
    }

    /// Original bytes detect external edits; canonical values detect a real, net change.
    struct Draft {
        let url: URL
        private(set) var original: Data?
        private(set) var values: [String: Any]
        private var baseline: Data

        var changed: Bool { (try? Self.canonical(values)) != baseline }

        init(url: URL) throws {
            self.url = url
            original = try Self.read(url)
            if let original {
                guard let decoded = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
                    throw Failure.invalid("Settings must be a JSON object. Repair the file before editing.")
                }
                values = decoded
            } else {
                values = [:]
            }
            baseline = try Self.canonical(values)
        }

        private static func canonical(_ values: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        }

        private static func read(_ url: URL) throws -> Data? {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { return nil }
                throw Failure.invalid("Cannot read settings. Use a regular file owned by your user.")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == getuid(), info.st_size >= 0, info.st_size <= 1024 * 1024 else {
                throw Failure.invalid("Settings must be a user-owned regular file of at most 1 MiB.")
            }
            let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
            guard data.count <= 1024 * 1024 else { throw Failure.invalid("Settings exceed 1 MiB.") }
            return data
        }

        mutating func apply(_ item: Item, input: String) throws {
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()
            if lower == "reset" {
                values.removeValue(forKey: item.key)
                return
            }
            let next: Any
            switch item.kind {
            case .toggle:
                if ["1", "on", "yes", "true"].contains(lower) { next = true }
                else if ["2", "0", "off", "no", "false"].contains(lower) { next = false }
                else { throw Failure.invalid("Choose 1 / on, 2 / off, or reset.") }
            case .choice(let options):
                let selected = Int(lower).flatMap { (1...options.count).contains($0) ? options[$0 - 1] : nil } ?? lower
                guard options.contains(selected) else {
                    throw Failure.invalid("Choose " + options.joined(separator: " / ") + ".")
                }
                if item.key == "browser" {
                    if selected == "auto" { values.removeValue(forKey: item.key); return }
                    next = selected == "on"
                } else { next = selected }
            case .color:
                let accent = Int(lower).flatMap { (1...accents.count).contains($0) ? accents[$0 - 1] : nil }
                    ?? accents.first { $0.name.lowercased() == lower || $0.value == lower }
                guard let color = accent?.value ?? (isHex(lower) ? lower : nil) else {
                    throw Failure.invalid("Choose a colour number, colour name, auto, graphite, or #RRGGBB.")
                }
                next = color
            case .endpoint(let allowEmpty):
                if allowEmpty, lower == "off" { values.removeValue(forKey: item.key); return }
                guard value.utf8.count <= 256, !hasControls(value),
                      let parts = URLComponents(string: value), parts.url != nil,
                      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                      ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host?.lowercased() ?? ""),
                      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                      parts.port.map({ (1...65535).contains($0) }) ?? true else {
                    throw Failure.invalid("Enter a loopback HTTP(S) URL without credentials, query or fragment.")
                }
                next = value
            case .name:
                if lower == "auto" { values.removeValue(forKey: item.key); return }
                guard validName(value) else {
                    throw Failure.invalid("Use 1–20 letters, digits, spaces or hyphens, starting with a letter.")
                }
                next = value
            case .seconds:
                guard let number = Double(value), number.isFinite, (0.2...60).contains(number) else {
                    throw Failure.invalid("Choose a number of seconds from 0.2 to 60.")
                }
                next = number
            }
            values[item.key] = next
        }

        mutating func stage(_ preset: Preset) throws {
            var proposed = self
            for edit in preset.edits {
                guard let item = items.first(where: { $0.key == edit.key }) else {
                    throw Failure.invalid("Unknown preset setting.")
                }
                try proposed.apply(item, input: edit.input)
            }
            self = proposed
        }

        mutating func reset(_ section: Section) {
            for item in items where item.section == section { values.removeValue(forKey: item.key) }
        }

        mutating func undo() {
            values = (try? JSONSerialization.jsonObject(with: baseline)) as? [String: Any] ?? [:]
        }

        mutating func save() throws {
            guard changed else { return }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw Failure.invalid("Settings directory must be user-owned and not writable by others.")
            }
            // Cooperating menu instances serialize their compare-and-replace operation.
            let lock = open(directory.appendingPathComponent(".settings.lock").path,
                            O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
            guard lock >= 0 else { throw Failure.invalid("Cannot open the settings lock.") }
            defer { close(lock) }
            guard fstat(lock, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == getuid(), info.st_nlink == 1, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                throw Failure.invalid("Another editor may be saving. Try again; your changes are still here.")
            }
            defer { flock(lock, LOCK_UN) }
            guard try Self.read(url) == original else { throw Failure.changed }

            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            let output = data + Data([10])
            var template = Array(directory.appendingPathComponent(".settings.XXXXXX").path.utf8CString)
            let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
            guard descriptor >= 0 else { throw Failure.invalid("Cannot create a private settings file.") }
            let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); _ = unlink(temporary) }
            try handle.write(contentsOf: output)
            try handle.synchronize()
            guard try Self.read(url) == original else { throw Failure.changed }
            guard rename(temporary, url.path) == 0 else { throw Failure.invalid("Could not replace the settings file.") }
            original = output
            baseline = try Self.canonical(values)
        }
    }

    private static func isHex(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 20 && name.utf8.count <= 96
            && name.unicodeScalars.first.map(CharacterSet.letters.contains) == true
            && name.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == " " || $0 == "-"
            }
    }

    private static func hasControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }
    }

    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }.prefix(256)))
    }

    static func shown(_ item: Item, values: [String: Any]) -> String {
        let value = values[item.key]
        switch item.kind {
        case .toggle:
            guard let value else { return item.fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return "(invalid)" }
            return number.boolValue ? "on" : "off"
        case .color:
            let raw = (value as? String ?? item.fallback).lowercased()
            return accents.first { $0.value == raw }?.name ?? (isHex(raw) ? raw.uppercased() : "(custom)")
        case .seconds:
            if let value {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else { return "(invalid)" }
                return number.stringValue + " s"
            }
            return item.fallback + " s"
        case .endpoint:
            guard let value else { return item.fallback }
            guard let text = value as? String, !hasControls(text),
                  let parts = URLComponents(string: text), parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host?.lowercased() ?? "") else {
                return "(custom URL)"
            }
            // Paths can contain tokens too. Show the origin, never credentials, queries or custom paths.
            var origin = parts
            origin.path = ""
            return sanitized(origin.string ?? "(custom URL)") + (parts.path.isEmpty || parts.path == "/" ? "" : "/…")
        case .choice:
            if item.key == "browser", let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "on" : "off"
            }
            if let number = value as? NSNumber, item.key == "cursor_speed" { return number.stringValue }
            fallthrough
        case .name:
            guard let value else { return item.fallback }
            return (value as? String).map(sanitized) ?? "(invalid)"
        }
    }

    static func hasOverride(_ item: Item, environment: [String: String]) -> Bool {
        if item.key == "helper_url" {
            return ["OPEN_COMPUTER_USE_REFEREE_URL", "OPEN_COMPUTER_USE_VISION_URL", "OPEN_COMPUTER_USE_HANDOFF_URL"]
                .contains { environment[$0] != nil }
        }
        return item.environment.map { environment[$0] != nil } == true
    }

    static func columns(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            if [.nonspacingMark, .enclosingMark].contains(scalar.properties.generalCategory) { return count }
            let measured = Int(wcwidth(Int32(scalar.value)))
            if measured >= 0 { return count + measured }
            // wcwidth can reject Unicode under the C locale. Keep widths conservative without changing
            // the process-wide locale (the settings command also belongs to the app executable).
            let wide = scalar.properties.isEmojiPresentation || (0x1100...0x115f).contains(scalar.value)
                || (0x2e80...0xa4cf).contains(scalar.value) || (0xac00...0xd7a3).contains(scalar.value)
                || (0xf900...0xfaff).contains(scalar.value) || (0xff00...0xff60).contains(scalar.value)
                || (0x20000...0x3fffd).contains(scalar.value)
            return count + (wide ? 2 : 1)
        }
    }

    static func clipped(_ text: String, to width: Int) -> String {
        let clean = sanitized(text)
        guard columns(in: clean) > width else { return clean }
        guard width > 1 else { return width == 1 ? "…" : "" }
        var result = ""
        for character in clean {
            if columns(in: result + String(character)) > width - 1 { break }
            result.append(character)
        }
        return result + "…"
    }

    static func wrapped(_ text: String, width: Int) -> [String] {
        let width = max(1, width)
        var result: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            let indentation = String(repeating: " ", count: min(width - 1, paragraph.prefix { $0 == " " }.count))
            var line = indentation
            var hasWord = false
            for word in sanitized(paragraph).split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                if hasWord, columns(in: line + " " + word) > width {
                    result.append(line)
                    line = indentation
                    hasWord = false
                }
                if columns(in: indentation + word) > width {
                    for character in word {
                        if columns(in: line + String(character)) > width {
                            result.append(line)
                            line = indentation
                        }
                        line.append(character)
                    }
                } else {
                    if hasWord { line += " " }
                    line += word
                }
                hasWord = true
            }
            result.append(hasWord ? line : "")
        }
        return result
    }

    private static func row(number: Int?, item: Item, values: [String: Any],
                            environment: [String: String], width: Int) -> [String] {
        let prefix = number.map { String(format: "  %2d  ", $0) } ?? "  "
        let suffix = hasOverride(item, environment: environment) ? " [env]" : ""
        let value = shown(item, values: values)
        if width < 60 {
            return [clipped(prefix + item.name, to: width),
                    "      " + clipped(value, to: width - 6 - suffix.count) + suffix]
        }
        let nameWidth = min(29, width - 25)
        let name = clipped(item.name, to: nameWidth)
        let padding = String(repeating: " ", count: max(0, nameWidth - columns(in: name)))
        return [prefix + name + padding + "  " + clipped(value, to: width - prefix.count - nameWidth - 2 - suffix.count) + suffix]
    }

    /// Home or one focused settings page. Read-only output uses snapshot instead.
    static func menu(values: [String: Any], environment: [String: String], dirty: Bool,
                     width: Int = 80, section: Section? = nil) -> String {
        let width = max(24, width)
        var lines = wrapped("GODSPEED  /  SETTINGS", width: width)
        lines += wrapped(dirty ? "Local preferences · unsaved changes" : "Local preferences · no pending changes", width: width)
        lines.append("")
        if let section {
            lines += wrapped(section.title.uppercased(), width: width)
            lines.append("")
            for (index, item) in items.filter({ $0.section == section }).enumerated() {
                lines += row(number: index + 1, item: item, values: values, environment: environment, width: width)
            }
            lines += [""] + wrapped("[number] edit   [r] defaults   [b] back", width: width)
        } else {
            for section in Section.allCases {
                lines += wrapped("  \(section.rawValue + 1)  \(section.title)", width: width)
                lines += wrapped("     \(section.summary)", width: width)
                lines.append("")
            }
            lines += wrapped("  5  Presets", width: width)
            lines += wrapped("     Model-free / Quiet / Balanced", width: width)
            lines += [""] + wrapped("[1–5] open   [u] undo all edits", width: width)
        }
        lines += wrapped("[s] save & exit   [q] quit", width: width)
        if environmentOverrides(environment) {
            lines += [""] + wrapped("[env] overrides the saved value in this shell.", width: width)
        }
        return lines.joined(separator: "\n")
    }

    static func snapshot(values: [String: Any], environment: [String: String], width: Int = 80) -> String {
        let width = max(24, width)
        var lines = wrapped("GODSPEED  /  SETTINGS", width: width)
        lines += wrapped("Saved preferences · read-only", width: width)
        for section in Section.allCases {
            lines += [""] + wrapped(section.title.uppercased(), width: width)
            for item in items where item.section == section {
                lines += row(number: nil, item: item, values: values, environment: environment, width: width)
            }
        }
        lines += [""] + wrapped("[env] marks a current-shell override; saved values are shown.", width: width)
        lines += wrapped("MCP launchers enforce background-only delivery. Reconnect clients after changing startup settings.", width: width)
        return lines.joined(separator: "\n")
    }

    private static func environmentOverrides(_ environment: [String: String]) -> Bool {
        items.contains { hasOverride($0, environment: environment) }
    }

    static func supportsColor(environment: [String: String], terminal: Bool) -> Bool {
        guard terminal, environment["NO_COLOR"] == nil, environment["CLICOLOR"] != "0",
              let term = environment["TERM"]?.lowercased(), !term.isEmpty, term != "dumb" else { return false }
        return ["truecolor", "24bit"].contains(environment["COLORTERM"]?.lowercased() ?? "")
            || ["xterm", "screen", "tmux", "rxvt", "alacritty", "kitty", "wezterm", "foot", "ghostty"]
                .contains(where: term.contains)
    }

    static func palette(width: Int, color: Bool) -> String {
        accents.enumerated().map { index, accent in
            var swatch = "●"
            if color, let rgb = UInt32(accent.swatch.dropFirst(), radix: 16) {
                swatch = "\u{001B}[38;2;\((rgb >> 16) & 255);\((rgb >> 8) & 255);\(rgb & 255)m●\u{001B}[0m"
            }
            let label = clipped(accent.name + (accent.value.hasPrefix("#") ? "  " + accent.value.uppercased() : ""), to: max(1, width - 9))
            return String(format: "  %2d  ", index + 1) + swatch + " " + label
        }.joined(separator: "\n")
    }

    private static func detail(_ item: Item, draft: Draft, environment: [String: String],
                               width: Int, color: Bool) -> String {
        var lines = wrapped("GODSPEED  /  " + item.name.uppercased(), width: width)
        lines += [""] + wrapped(item.help, width: width)
        lines += [""] + wrapped("Current choice: " + shown(item, values: draft.values), width: width)
        if hasOverride(item, environment: environment) {
            lines += wrapped("An environment override takes priority here. This edits the saved preference.", width: width)
        }
        lines.append("")
        switch item.kind {
        case .toggle: lines += ["  1  on", "  2  off"]
        case .choice(let choices):
            lines += choices.enumerated().map { "  \($0.offset + 1)  \($0.element)" }
        case .color:
            lines.append(palette(width: width, color: color))
            lines += wrapped("Or enter a custom #RRGGBB colour.", width: width)
        case .endpoint(let allowEmpty):
            lines += wrapped(allowEmpty ? "Enter a loopback URL, or off." : "Enter a loopback URL.", width: width)
        case .name: lines += wrapped("Enter a nickname, or auto.", width: width)
        case .seconds: lines += wrapped("Enter seconds from 0.2 to 60.", width: width)
        }
        lines += [""] + wrapped("[r] reset to default   [Enter / b] back", width: width)
        return lines.joined(separator: "\n")
    }

    static func presetPreview(_ preset: Preset, draft: Draft, width: Int = 80) throws -> String {
        var proposed = draft
        try proposed.stage(preset)
        var lines = wrapped("GODSPEED  /  " + preset.name.uppercased(), width: width)
        lines += [""] + wrapped(preset.detail, width: width)
        lines.append("")
        for edit in preset.edits {
            guard let item = items.first(where: { $0.key == edit.key }) else { continue }
            lines += wrapped("\(item.name): \(shown(item, values: draft.values)) → \(shown(item, values: proposed.values))", width: width)
        }
        lines += [""] + wrapped("Only these settings change. Environment overrides still win.", width: width)
        lines += wrapped("[a] apply to draft   [Enter / b] back", width: width)
        return lines.joined(separator: "\n")
    }

    /// Line-based input keeps terminal state intact and makes EOF, cancelled edits and save errors testable.
    static func interact(draft: inout Draft, environment: [String: String], terminal: Bool,
                         width: () -> Int = { 80 }, input: () -> String?, output: (String) -> Void) {
        let redraw = terminal && environment["TERM"] != nil && environment["TERM"] != "dumb"
        let color = supportsColor(environment: environment, terminal: terminal)
        var section: Section?
        var notice = ""

        func screen(_ body: String) {
            if redraw { output("\u{001B}[2J\u{001B}[H") }
            output(body + "\n")
        }
        func prompt() -> String? {
            output("\n> ")
            return input()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func discard() {
            if draft.changed { output("\nUnsaved changes discarded.\n") }
        }

        while true {
            let columns = max(24, width())
            screen(menu(values: draft.values, environment: environment, dirty: draft.changed, width: columns, section: section))
            if !notice.isEmpty { output("\n" + wrapped(notice, width: columns).joined(separator: "\n") + "\n") }
            notice = ""
            guard let raw = prompt() else { discard(); return }
            let command = raw.lowercased()
            if command == "q" {
                if !draft.changed { return }
                output("\n" + wrapped("Unsaved changes: [s] save  [d] discard  [Enter] keep editing", width: columns).joined(separator: "\n") + "\n")
                guard let exit = prompt()?.lowercased() else { discard(); return }
                if exit == "d" { discard(); return }
                if exit != "s" { continue }
                do { try draft.save(); output("\nSettings saved.\n"); return }
                catch { notice = error.localizedDescription; continue }
            }
            if command == "s" {
                let changed = draft.changed
                do {
                    try draft.save()
                    output(changed ? "\nSettings saved. Reconnect clients if needed.\n" : "\nNo changes to save.\n")
                    return
                } catch { notice = error.localizedDescription; continue }
            }
            if command == "b" || command.isEmpty { section = nil; continue }
            if command == "u", section == nil { draft.undo(); notice = "Edits undone."; continue }
            if command == "r", let section { draft.reset(section); notice = "Section defaults staged. Save to keep them."; continue }

            if section == nil, command == "5" {
                var lines = wrapped("GODSPEED  /  PRESETS", width: columns)
                lines += [""] + wrapped("Preview a preset before applying it to your draft.", width: columns)
                for (index, preset) in presets.enumerated() {
                    lines += [""] + wrapped("  \(index + 1)  \(preset.name)", width: columns)
                    lines += wrapped(preset.detail, width: columns)
                }
                lines += [""] + wrapped("[1–3] preview   [Enter / b] back", width: columns)
                screen(lines.joined(separator: "\n"))
                guard let choice = prompt() else { discard(); return }
                guard let number = Int(choice), (1...presets.count).contains(number) else { continue }
                let preset = presets[number - 1]
                do {
                    screen(try presetPreview(preset, draft: draft, width: columns))
                    guard let confirmation = prompt() else { discard(); return }
                    if confirmation.lowercased() == "a" {
                        try draft.stage(preset)
                        notice = "\(preset.name) staged. Save to keep it."
                    }
                } catch { notice = error.localizedDescription }
                continue
            }

            guard let number = Int(command), number > 0 else {
                notice = "Choose a shown number or command."; continue
            }
            guard let selectedSection = section else {
                if let selected = Section(rawValue: number - 1) { section = selected }
                else { notice = "Choose a page from 1 to 5." }
                continue
            }
            let pageItems = items.filter { $0.section == selectedSection }
            guard pageItems.indices.contains(number - 1) else { notice = "Choose a setting shown on this page."; continue }
            let item = pageItems[number - 1]
            var editNotice = ""
            while true {
                screen(detail(item, draft: draft, environment: environment, width: columns, color: color))
                if !editNotice.isEmpty { output("\n" + wrapped(editNotice, width: columns).joined(separator: "\n") + "\n") }
                guard let value = prompt() else { discard(); return }
                if value.isEmpty || value.lowercased() == "b" { break }
                do {
                    try draft.apply(item, input: value.lowercased() == "r" ? "reset" : value)
                    notice = "\(item.name): \(shown(item, values: draft.values))."
                    break
                } catch { editNotice = error.localizedDescription }
            }
        }
    }

    private static func terminalColumns() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return 80 }
        return max(24, min(120, Int(size.ws_col)))
    }

    public static func run(arguments: [String]) throws {
        if arguments == ["--help"] || arguments == ["-h"] {
            print("Usage: godspeed settings [--show]\nEdit local preferences, or show saved preferences without editing.")
            return
        }
        guard arguments.isEmpty || arguments == ["--show"] else {
            throw Failure.invalid("Usage: godspeed settings [--show]")
        }
        var draft = try Draft(url: GodspeedSettings.fileURL)
        let environment = ProcessInfo.processInfo.environment
        if arguments == ["--show"] {
            print(snapshot(values: draft.values, environment: environment, width: terminalColumns()))
            return
        }
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            throw Failure.invalid("Settings editing requires an interactive terminal. Use --show for read-only output.")
        }
        interact(draft: &draft, environment: environment, terminal: true, width: terminalColumns,
                 input: { readLine() }, output: { print($0, terminator: ""); fflush(nil) })
    }
}
