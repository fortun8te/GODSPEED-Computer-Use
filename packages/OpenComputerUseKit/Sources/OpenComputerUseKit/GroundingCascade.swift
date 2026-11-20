import CoreGraphics
import Foundation

/// Cheapest-first target finding for a labelled click that missed an exact accessibility match:
/// (1) exact unique AX name, (2) rule-based prefilter of AX controls to at most 12, (3) the local helper
/// ranks 2-12 of them, act only on a clear winner, (4) OCR and vision as before, (5) one zoomed second look
/// at a vision point. Every step names its provenance (ax, model, ocr, zoom).
enum GroundingCascade {
    enum Provenance: String, Equatable, Sendable {
        case ax, ocr, model, zoom
    }

    struct Option: Equatable, Sendable {
        let id: String
        let text: String
    }

    static let maxCandidates = 12

    /// Dev-calibrated cutoffs for act-on-rank (step 3): the top option needs this probability ...
    static let minProbability = 0.70
    /// ... and this lead over the next option.
    static let minLead = 0.35

    /// Words that name the same control in Dutch and English, both directions. Lower-cased, letters only.
    private static let bilingual: [String: [String]] = [
        "save": ["opslaan", "bewaren"], "cancel": ["annuleren", "afbreken"], "delete": ["verwijderen", "wissen"],
        "remove": ["verwijderen"], "close": ["sluiten"], "open": ["openen"], "done": ["klaar", "gereed"],
        "next": ["volgende", "verder"], "back": ["terug"], "search": ["zoeken"], "settings": ["instellingen"],
        "new": ["nieuw"], "undo": ["ongedaan maken", "ongedaanmaken"], "copy": ["kopieren", "kopiëren"],
        "paste": ["plakken"], "print": ["afdrukken", "printen"], "ok": ["oke", "oké"], "yes": ["ja"], "no": ["nee"],
        "continue": ["doorgaan", "verdergaan"], "add": ["toevoegen"], "edit": ["bewerken"], "help": ["hulp"],
        "share": ["delen"], "select all": ["alles selecteren"], "show": ["tonen"], "hide": ["verbergen"],
    ]

    /// Lower-cased, diacritics folded, letters and digits only: "Ünï-code 1" becomes "unicode1".
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Spellings of `label` that name the same control: LabelSpellings (digits, symbols) and the bilingual table.
    static func spellings(of label: String) -> Set<String> {
        let lower = label.lowercased()
        // LabelSpellings wants lower-cased text without spaces, and keeps symbols such as "+" that normalized() drops.
        var out = Set(LabelSpellings.alternatives(lower.filter { !$0.isWhitespace }).map(normalized))
        for (english, others) in bilingual {
            let words = [english] + others
            if words.contains(where: { normalized($0) == normalized(lower) }) {
                out.formUnion(words.map(normalized))
            }
        }
        out.remove(normalized(label))
        out.remove("")
        return out
    }

    /// Step 2. Rule-based similarity between `label` and each control name, best first, at most `limit`.
    /// A control with no rule-based link to the label is dropped. The result is never a guess; step 3 ranks it.
    static func prefilter(label: String, options: [Option], limit: Int = maxCandidates) -> [Option] {
        let wanted = normalized(label)
        let alternatives = spellings(of: label)
        guard !wanted.isEmpty || !alternatives.isEmpty else { return [] }
        let scored: [(option: Option, score: Double, position: Int)] = options.enumerated().compactMap { position, option in
            let name = normalized(option.text)
            guard !name.isEmpty else { return nil }
            let score: Double
            if name == wanted {
                score = 3
            } else if alternatives.contains(name) {
                score = 2.5
            } else if wanted.count >= 3, name.count >= 3, name.contains(wanted) || wanted.contains(name) {
                score = 1.5
            } else {
                let similarity = 1 - Double(editDistance(wanted, name)) / Double(max(wanted.count, name.count))
                // Typos and near spellings only: at least 60% of the longer text must survive the edit.
                guard similarity >= 0.6 else { return nil }
                score = similarity
            }
            return (option, score, position)
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
            .prefix(limit)
            .map(\.option)
    }

    /// Levenshtein distance over characters. Inputs are short control names.
    static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left), b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
