import Foundation

/// The one list of risky words. Every consumer classifies labels through this file (ActionPolicy named
/// risks, ShortcutCache and MenuItemLookup destructive labels, FailureSignatures' risky check), so the
/// lists cannot disagree.
///
/// Matching is per word on folded text: lowercase, diacritics and ß folded, and "…", "...", apostrophes and
/// all other punctuation treated as separators. A stem matches a whole word only. A stem written with a
/// trailing `*` matches any word that starts with it, which covers inflections and compounds
/// ("verwijder*" matches "verwijderen"). Multi-word stems match consecutive words within one label.
enum RiskLexicon {
    enum Category: CaseIterable, Sendable {
        case send, submit, purchase, delete, discard, credentialEntry, overwrite, save, systemSettings
    }

    /// Categories that make a label unsafe to replay from a shortcut, click through a fallback or suggest.
    static let destructiveCategories: Set<Category> = [.send, .submit, .purchase, .delete, .discard, .overwrite]

    private static let stemTable: [Category: [String]] = [
        .send: [
            // English
            "send", "sends", "sent", "sending", "sendmessage", "post", "posts", "posted", "posting",
            "publish", "publishes", "published", "publishing",
            // Dutch
            "verstuur", "verstuurd", "versturen", "verstuurt", "verzend*", "verzenden", "verzonden",
            "stuur", "stuurt", "sturen", "plaats bericht", "plaats reactie", "plaats opmerking",
            // German
            "senden", "sende", "sendet", "absend*", "versend*", "abschicken",
            // French
            "envoyer", "envoie", "envoi", "envoyez", "publier",
            // Spanish
            "enviar", "envia", "enviado", "publicar",
        ],
        .submit: [
            // English
            "submit", "submits", "submitted", "submitting", "upload", "uploads", "uploaded", "uploading",
            "sign in", "signin", "log in", "login", "logins", "sign up",
            // Dutch
            "indien*", "inloggen", "aanmelden", "aanmeld*", "uploaden",
            // German
            "einloggen", "anmelden", "anmeld*", "hochladen", "einreichen",
            // French
            "soumettre", "soumets", "connexion", "se connecter",
            // Spanish
            "iniciar sesion", "subir",
        ],
        .purchase: [
            // English
            "buy", "buys", "buying", "bought", "buy now", "purchase", "purchases", "purchased", "purchasing",
            "pay", "pays", "paying", "paid", "pay now", "payment", "payments", "confirm payment",
            "order", "orders", "ordered", "ordering", "place order", "checkout", "checkouts",
            "transfer", "transfers", "transferred", "transferring", "cancel subscription",
            // Dutch
            "koop", "koopt", "kopen", "betaal*", "betal*", "betaling", "bestel*", "bestelling", "plaats bestelling",
            "afreken*", "overmaak*", "overmaken",
            // German
            "kauf*", "bezahl*", "zahlung", "bestell*",
            // French
            "acheter", "achat", "achete", "payer", "paiement*", "commander", "commande", "confirmer le paiement",
            // Spanish
            "comprar", "compra", "compre", "pagar", "pague", "pagado", "pago", "pedido", "finalizar compra",
        ],
        .delete: [
            // English
            "delete", "deletes", "deleted", "deleting", "remove", "removes", "removed", "removing",
            "erase", "erases", "erased", "erasing", "axdelete", "trash", "move to trash", "empty trash",
            "wipe", "wiped",
            // Dutch
            "verwijder*", "wis", "wist", "gewist", "wissen", "prullenbak*", "prullenmand*", "leegmaken*",
            "weggooi*", "vernietig*", "verplaats naar prullenbak",
            // German
            "losch*", "geloscht", "entfern*", "papierkorb*",
            // French
            "supprim*", "efface*", "corbeille*", "vider la corbeille",
            // Spanish
            "elimin*", "borrar", "borra", "borrado", "suprim*", "papelera*", "vaciar la papelera",
        ],
        .discard: [
            // English
            "discard", "discards", "discarded", "discarding", "quit", "quits", "quitting", "close",
            "stop", "stops", "restart", "restarts", "restarted", "shut down", "shutdown",
            "log out", "logout", "logs out", "sign out", "signout", "force quit", "uninstall", "uninstalls",
            "reset", "revert", "format", "formats", "formatting", "empty", "clear", "cut", "don't save",
            "dont save", "unsubscribe",
            // Dutch
            "afmelden", "afmeldt", "uitloggen", "uitlog*", "herstart*", "opnieuw opstarten", "zet uit", "sluit",
            "sluiten", "afsluit*", "stoppen", "beeindig*", "verwerp*", "terugzetten", "formatteer*",
            // German
            "beenden", "schliessen", "abmelden", "ausloggen", "neustarten", "neu starten", "herunterfahren",
            "verwerfen", "zurucksetzen", "formatieren",
            // French
            "quitter", "fermer", "deconnexion", "deconnecter", "redemarrer", "eteindre", "forcer a quitter",
            "reinitialiser", "formater",
            // Spanish
            "salir", "cerrar", "cerrar sesion", "reiniciar", "apagar", "descartar", "restablecer", "formatear",
        ],
        .credentialEntry: [
            "password", "passwords", "passcode", "passwort", "wachtwoord", "wachtwoorden", "contrasena",
            "mot de passe",
        ],
        .overwrite: [
            "overwrite", "overwrites", "overwritten", "overwriting", "overschrijv*", "replace", "replaces",
            "replaced", "replacing", "vervang*", "ersetzen", "uberschreiben", "remplacer", "ecraser",
            "reemplazar", "sobrescribir", "sobreescribir",
        ],
        .save: [
            "save", "saves", "saved", "saving", "opslaan", "opslaat", "opgeslagen", "speichern", "gespeichert",
            "enregistrer", "enregistre", "guardar", "guardado",
        ],
        .systemSettings: [
            "allow access", "grant permission", "toestaan", "toegang toestaan", "toegang verlenen",
            "zugriff erlauben", "zugriff gewahren", "autoriser", "permettre l acces", "permitir acceso",
            "conceder permiso",
        ],
    ]

    private struct Stem {
        let words: [String]
        let prefixLast: Bool
    }

    private static let stems: [(Category, [Stem])] = Category.allCases.map { category in
        (category, (stemTable[category] ?? []).map { raw in
            Stem(words: words(in: raw.replacingOccurrences(of: "*", with: "")), prefixLast: raw.hasSuffix("*"))
        })
    }

    /// Folds case, diacritics and ß, then splits on anything that is not a letter.
    static func words(in text: String) -> [String] {
        text.replacingOccurrences(of: "…", with: " ")
            .replacingOccurrences(of: "...", with: " ")
            .replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// Every category whose stems appear in any of the given names. Each name is read on its own,
    /// so words never join across two labels.
    static func categories(_ names: [String?]) -> Set<Category> {
        var found: Set<Category> = []
        for name in names.compactMap({ $0 }) {
            let tokens = words(in: name)
            guard !tokens.isEmpty else { continue }
            for (category, list) in stems where !found.contains(category) {
                if list.contains(where: { matches($0, in: tokens) }) { found.insert(category) }
            }
        }
        return found
    }

    /// True when a label names something that must never be replayed, clicked through a fallback or suggested.
    static func isDestructive(_ label: String) -> Bool {
        !categories([label]).isDisjoint(with: destructiveCategories)
    }

    private static func matches(_ stem: Stem, in tokens: [String]) -> Bool {
        guard !stem.words.isEmpty, stem.words.count <= tokens.count else { return false }
        let last = stem.words.count - 1
        for start in 0...(tokens.count - stem.words.count) {
            let found = stem.words.indices.allSatisfy { offset in
                let token = tokens[start + offset]
                let word = stem.words[offset]
                return offset == last && stem.prefixLast ? token.hasPrefix(word) : token == word
            }
            if found { return true }
        }
        return false
    }
}
