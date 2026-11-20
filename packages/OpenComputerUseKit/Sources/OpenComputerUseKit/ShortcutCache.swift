import Foundation

public final class ShortcutCache: @unchecked Sendable {
    public struct MenuItem: Sendable {
        public let path: String
        public let title: String
        public let commandCharacter: String
        public let modifierMask: Int
        public init(path: String, title: String, commandCharacter: String, modifierMask: Int) {
            self.path = path; self.title = title; self.commandCharacter = commandCharacter; self.modifierMask = modifierMask
        }
    }

    private let lock = NSLock()
    private let extraDestructive: @Sendable (String) -> Bool
    private var chords: [String: [String: String]] = [:]
    private var confirmed: Set<String> = []

    /// `isExtraDestructive` is an additional caller-supplied check (for example Godspeed's
    /// ActionPolicy risk check). It is used on top of `isDestructive`, never instead of it.
    public init(isExtraDestructive: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.extraDestructive = isExtraDestructive
    }

    public func parse(app: String, items: [MenuItem]) {
        lock.lock(); defer { lock.unlock() }
        for item in items {
            guard !blocked(item.title), let chord = Self.chord(character: item.commandCharacter, mask: item.modifierMask) else { continue }
            chords[app, default: [:]][item.path] = chord
            confirmed.remove(Self.key(app, item.path))
        }
    }

    public func confirm(app: String, path: String) {
        lock.lock(); defer { lock.unlock() }
        if chords[app]?[path] != nil { confirmed.insert(Self.key(app, path)) }
    }

    public func lookup(app: String, path: String, includeUnverified: Bool = false) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let chord = chords[app]?[path], includeUnverified || confirmed.contains(Self.key(app, path)),
              let title = path.split(separator: ">", omittingEmptySubsequences: true).last.map(String.init), !blocked(title) else { return nil }
        return chord
    }

    /// Where press_menu sends a path: the menu itself, or a confirmed key equivalent. Strict mode always uses the menu.
    public enum Route: Equatable, Sendable {
        case menu
        case shortcut(String)
    }

    /// The route for one press_menu path. Only a confirmed, non-destructive chord leaves the menu.
    public func route(app: String, path: String, strict: Bool) -> Route {
        guard !strict, let chord = lookup(app: app, path: path) else { return .menu }
        return .shortcut(chord)
    }

    /// Cache key: an app's bundle id and version, so an update starts with no confirmed shortcuts.
    public static func appKey(bundleID: String, version: String) -> String {
        bundleID + "@" + version
    }

    private struct Saved: Codable {
        var chords: [String: [String: String]]
        var confirmed: [String]
    }

    /// Writes the chords and confirmations as JSON. Holds only menu titles and key names.
    public func save(to url: URL) throws {
        lock.lock()
        let saved = Saved(chords: chords, confirmed: confirmed.sorted())
        lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: url, options: .atomic)
    }

    /// Restores saved state. A missing file is an empty cache, not an error.
    public func load(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        lock.lock()
        defer { lock.unlock() }
        chords = saved.chords
        confirmed = Set(saved.confirmed)
    }

    public func invalidate(app: String) {
        lock.lock(); defer { lock.unlock() }
        chords.removeValue(forKey: app)
        confirmed = confirmed.filter { !$0.hasPrefix(app + "\u{1f}") }
    }

    /// True when a menu title names an action that must never be replayed as a shortcut.
    /// The word list is RiskLexicon's, shared with every other destructive check.
    public static func isDestructive(_ title: String) -> Bool {
        RiskLexicon.isDestructive(title)
    }

    private func blocked(_ title: String) -> Bool {
        Self.isDestructive(title) || extraDestructive(title)
    }

    private static func key(_ app: String, _ path: String) -> String { app + "\u{1f}" + path }
    private static func chord(character: String, mask: Int) -> String? {
        guard mask != 8, !character.isEmpty else { return nil }
        var parts: [String] = ["cmd"]
        if mask & 1 != 0 { parts.append("shift") }
        if mask & 2 != 0 { parts.append("option") }
        if mask & 4 != 0 { parts.append("ctrl") }
        parts.append(character.lowercased())
        return parts.joined(separator: "+")
    }
}
