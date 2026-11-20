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

    /// What the cascade decided for one labelled click.
    enum Decision: Equatable {
        /// Click this control. `probability` and `lead` are set only for a model ranking.
        case act(id: String, provenance: Provenance, probability: Double?, lead: Double?)
        /// Never clicked here: the ranked control ids go back to the model to choose from.
        case offer(ids: [String])
        /// Nothing clear enough: the caller goes on to OCR and vision.
        case abstain(String)
    }

    /// Steps 1 to 3 for one label. `choose` ranks the candidates (ids plus "none", each a probability) and is
    /// only called for 2-12 prefiltered candidates. A risky control is never acted on here: it is offered.
    static func resolve(label: String, options: [Option], isRisky: (String) -> Bool = VisionFallback.risky,
                        choose: ([Option]) -> [String: Double]?) -> Decision {
        // Step 1: one exact name, as before. Exact matches are not risk-checked here; the existing click path does that.
        let exact = options.filter { VisionFallback.sameName($0.text, label) }
        if exact.count == 1, let only = exact.first {
            return .act(id: only.id, provenance: .ax, probability: nil, lead: nil)
        }
        // Step 2.
        let candidates = prefilter(label: label, options: options)
        guard candidates.count >= 2 else { return .abstain("no close control") }
        // Step 3.
        guard let probabilities = choose(candidates) else { return .abstain("the local helper gave no ranking") }
        let ranked = candidates.sorted { (probabilities[$0.id] ?? 0) > (probabilities[$1.id] ?? 0) }
        guard let top = ranked.first, let topProbability = probabilities[top.id] else {
            return .abstain("the local helper gave no ranking")
        }
        if (probabilities["none"] ?? 0) >= topProbability { return .abstain("the helper chose none") }
        let next = ranked.dropFirst().map { probabilities[$0.id] ?? 0 }.max() ?? 0
        let lead = topProbability - next
        guard topProbability >= minProbability else { return .abstain("the top choice is below 0.70") }
        guard lead >= minLead else { return .abstain("the top choice does not lead by 0.35") }
        guard !isRisky(top.text) else { return .offer(ids: ranked.map(\.id)) }
        return .act(id: top.id, provenance: .model, probability: topProbability, lead: lead)
    }

    /// Step 5 crop: half the window's width and height, centred on the first vision point and kept inside the window.
    /// Fractions of the window, top left origin. The crop is what the helper sees at about twice the scale.
    static func zoomRect(around point: CGPoint) -> CGRect {
        let size: CGFloat = 0.5
        let x = min(max(point.x - size / 2, 0), 1 - size)
        let y = min(max(point.y - size / 2, 0), 1 - size)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// Step 5. One locate on the zoomed crop around `point`; its answer maps back to window fractions. The
    /// point is accepted only when `verify` (the hit-test name check) confirms it. Nil otherwise: no retry.
    static func secondLook(at point: CGPoint, locate: (CGRect) -> CGPoint?, verify: (CGPoint) -> Bool) -> CGPoint? {
        let rect = zoomRect(around: point)
        guard let inside = locate(rect), (0...1).contains(inside.x), (0...1).contains(inside.y) else { return nil }
        let mapped = CGPoint(x: rect.minX + inside.x * rect.width, y: rect.minY + inside.y * rect.height)
        return verify(mapped) ? mapped : nil
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
