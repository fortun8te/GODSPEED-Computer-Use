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
    private var chords: [String: [String: String]] = [:]
    private var confirmed: Set<String> = []

    public init() {}

    public func parse(app: String, items: [MenuItem]) {
        lock.lock(); defer { lock.unlock() }
        for item in items {
            guard !Self.isDestructive(item.title), let chord = Self.chord(character: item.commandCharacter, mask: item.modifierMask) else { continue }
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
              let title = path.split(separator: ">", omittingEmptySubsequences: true).last.map(String.init), !Self.isDestructive(title) else { return nil }
        return chord
    }

    public func invalidate(app: String) {
        lock.lock(); defer { lock.unlock() }
        chords.removeValue(forKey: app)
        confirmed = confirmed.filter { !$0.hasPrefix(app + "\u{1f}") }
    }

    private static func key(_ app: String, _ path: String) -> String { app + "\u{1f}" + path }
    private static func isDestructive(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "…", with: "")
        return ["delete", "quit", "close", "erase", "empty trash", "log out", "restart", "shut down"].contains { normalized.hasPrefix($0) }
    }
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
