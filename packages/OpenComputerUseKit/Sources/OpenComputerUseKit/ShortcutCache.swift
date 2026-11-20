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

    /// Destructive word stems, English first, then Dutch, German, French and Spanish.
    /// Stems are folded (lowercase, no diacritics, ß as ss) and matched per word:
    /// short stems (4 letters or fewer) must match a whole word, longer ones a word prefix.
    private static let destructiveStems: [String] = [
        // English
        "delete", "remove", "erase", "quit", "close", "stop", "empty trash", "move to trash",
        "log out", "logout", "sign out", "signout", "restart", "shut down", "shutdown",
        "force quit", "discard", "revert", "format",
        // Dutch
        "verwijder", "wis", "wissen", "sluit", "afmelden", "uitloggen", "herstart",
        "opnieuw opstarten", "zet uit", "prullenmand", "leegmaken", "weggooien",
        // German
        "löschen", "entfernen", "beenden", "schließen", "abmelden", "neustarten",
        "herunterfahren", "papierkorb leeren", "verwerfen", "zurücksetzen", "formatieren",
        // French
        "supprimer", "effacer", "quitter", "fermer", "déconnexion", "déconnecter",
        "vider la corbeille", "corbeille", "redémarrer", "éteindre", "forcer à quitter",
        "réinitialiser", "formater",
        // Spanish
        "eliminar", "borrar", "suprimir", "salir", "cerrar", "cerrar sesión", "vaciar la papelera",
        "papelera", "reiniciar", "apagar", "descartar", "restablecer", "formatear",
    ]

    private static let destructivePhrases: [[String]] = destructiveStems.map(words(in:))

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

    public func invalidate(app: String) {
        lock.lock(); defer { lock.unlock() }
        chords.removeValue(forKey: app)
        confirmed = confirmed.filter { !$0.hasPrefix(app + "\u{1f}") }
    }

    /// True when a menu title names an action that must never be replayed as a shortcut.
    /// Matching is case-, diacritic- and punctuation-insensitive ("Log out…", "Löschen", "Déconnexion").
    public static func isDestructive(_ title: String) -> Bool {
        let tokens = words(in: title)
        guard !tokens.isEmpty else { return false }
        return destructivePhrases.contains { phrase in containsPhrase(phrase, in: tokens) }
    }

    private func blocked(_ title: String) -> Bool {
        Self.isDestructive(title) || extraDestructive(title)
    }

    /// Folds case, diacritics and ß, then splits on anything that is not a letter,
    /// so ellipses, hyphens and punctuation all act as separators.
    private static func words(in text: String) -> [String] {
        text.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    private static func containsPhrase(_ phrase: [String], in tokens: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return false }
        for start in 0...(tokens.count - phrase.count) {
            let matched = phrase.enumerated().allSatisfy { offset, stem in
                let token = tokens[start + offset]
                return stem.count <= 4 ? token == stem : token.hasPrefix(stem)
            }
            if matched { return true }
        }
        return false
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
