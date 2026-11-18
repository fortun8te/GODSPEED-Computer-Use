import Foundation

/// Compact "what changed" summaries for repeated accessibility reads.
///
/// After an action, GODSPEED can send only the lines of an app's state text that changed
/// instead of the whole window again. Matching ignores element indexes (they are renumbered
/// on every read) and indentation, so a tree that only shifted or renumbered reads as "no changes".
///
/// The diff is a pure function over two strings: no accessibility calls, no I/O, no shared state.
///
/// Output shape (for weak models, so keep it flat):
///
///     Changes since your last read (2 of 1204 lines; indexes below are current):
///     + \t\t\t7 text field To = sam@x.com (w:str)
///     - text field To = a@x.com (w:str)
///     Unchanged: 1201 lines. Ask get_app_state for the full window if needed.
public enum AXStateDiff {
    /// Returned when the two states match line for line after index and indentation are ignored.
    public static let noChangesMessage = "No changes since your last read."

    /// Removed lines are shown up to this many per run; the rest collapse into one summary line.
    public static let maxRemovedRunLength = 8

    /// Summarises how `current` differs from `previous`.
    ///
    /// - Returns: `nil` when the caller should send the full state instead, which is the case when
    ///   `previous` is empty, or when more than `maxChangedFraction` of the lines changed. Returns
    ///   `noChangesMessage` when nothing changed. Otherwise returns the header, one `+` line per
    ///   added or changed line (current text, current index), one `-` line per removed line
    ///   (old text without its stale index), and an unchanged-count footer.
    ///
    /// The fraction is `changedLines / max(previousLineCount, currentLineCount)`, where a changed
    /// line is one added or removed line. A one-value edit in a 1,200-line tree is 2 / 1,200.
    ///
    /// Complexity is O((N + M) · D), where D is the number of changed lines. The search stops as
    /// soon as D passes the threshold, so a near-total rewrite returns early without finishing the
    /// full edit script.
    ///
    /// With `matchIndexes` (element numbers are stable across reads) the number is part of a line's identity:
    /// a new element that looks like an old one is a change, and a removed line keeps its number so the model
    /// sees which number is gone. Without it, indexes are ignored (they may be renumbered on every read).
    public static func diff(previous: String, current: String, maxChangedFraction: Double = 0.5,
                            matchIndexes: Bool = false) -> String? {
        guard !previous.isEmpty else { return nil }

        let oldLines = previous.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let total = max(oldLines.count, newLines.count)

        // Intern each line's matching key so the diff compares Ints, not strings.
        var keyIDs: [String: Int] = [:]
        func key(_ line: String) -> Int {
            let text = matchIndexes ? indentationStripped(line) : strippedContent(of: line)
            if let existing = keyIDs[text] { return existing }
            let id = keyIDs.count
            keyIDs[text] = id
            return id
        }
        let oldKeys = oldLines.map(key)
        let newKeys = newLines.map(key)

        let fraction = min(max(maxChangedFraction, 0), 1)
        let limit = Int((Double(total) * fraction).rounded(.down))
        guard let steps = editScript(old: oldKeys, new: newKeys, maxEdits: limit) else { return nil }

        var changed = 0
        var unchanged = 0
        var body: [String] = []
        var position = 0
        while position < steps.count {
            if case .equal = steps[position] {
                unchanged += 1
                position += 1
                continue
            }
            // A run of non-equal steps forms one hunk: its removals print before its additions.
            var removedIndexes: [Int] = []
            var addedIndexes: [Int] = []
            while position < steps.count, !isEqual(steps[position]) {
                switch steps[position] {
                case .equal: break
                case .delete(let index): removedIndexes.append(index)
                case .insert(let index): addedIndexes.append(index)
                }
                position += 1
            }
            changed += removedIndexes.count + addedIndexes.count
            for index in removedIndexes.prefix(maxRemovedRunLength) {
                body.append("- " + (matchIndexes ? indentationStripped(oldLines[index]) : strippedContent(of: oldLines[index])))
            }
            let hiddenRemovals = removedIndexes.count - maxRemovedRunLength
            if hiddenRemovals > 0 {
                body.append("- (\(hiddenRemovals) more lines removed)")
            }
            for index in addedIndexes {
                body.append("+ " + newLines[index])
            }
        }

        guard changed > 0 else { return noChangesMessage }

        var output = ["Changes since your last read (\(changed) of \(total) lines; indexes below are current):"]
        output.append(contentsOf: body)
        output.append("Unchanged: \(unchanged) lines. Ask get_app_state for the full window if needed.")
        return output.joined(separator: "\n")
    }

    /// A line without indentation or trailing whitespace; its element number stays.
    static func indentationStripped(_ line: String) -> String {
        String(Substring(line).drop(while: { $0 == " " || $0 == "\t" })).trimmingCharacters(in: .whitespaces)
    }

    /// The part of a state line used for matching: no leading tabs or spaces, no leading element
    /// index, no trailing whitespace. `"\t\t12 button Send"` becomes `"button Send"`. Header and
    /// heading lines without an index (`"App=..."`, `"# heading"`) come back unchanged.
    public static func strippedContent(of line: String) -> String {
        var body = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        // An index only counts when a space follows it, so "2024 Notes" is not read as index 2024.
        if !digits.isEmpty, body.dropFirst(digits.count).first == " " {
            body = body.dropFirst(digits.count).drop(while: { $0 == " " })
        }
        return String(body).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Line diff

    private enum Step {
        case equal
        case delete(Int)   // index into the old lines
        case insert(Int)   // index into the new lines
    }

    private static func isEqual(_ step: Step) -> Bool {
        if case .equal = step { return true }
        return false
    }

    /// Myers' O(ND) shortest edit script over interned line keys, with common prefix and suffix
    /// trimmed first (most of a tree is unchanged, so this does most of the work). Returns `nil`
    /// when more than `maxEdits` lines differ.
    private static func editScript(old: [Int], new: [Int], maxEdits: Int) -> [Step]? {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        let middleOld = Array(old[prefix..<(old.count - suffix)])
        let middleNew = Array(new[prefix..<(new.count - suffix)])
        guard let middle = myers(middleOld, middleNew, maxEdits: maxEdits) else { return nil }

        var steps = [Step](repeating: .equal, count: prefix)
        for step in middle {
            switch step {
            case .equal: steps.append(.equal)
            case .delete(let index): steps.append(.delete(index + prefix))
            case .insert(let index): steps.append(.insert(index + prefix))
            }
        }
        steps.append(contentsOf: repeatElement(Step.equal, count: suffix))
        return steps
    }

    private static func myers(_ a: [Int], _ b: [Int], maxEdits: Int) -> [Step]? {
        let n = a.count
        let m = b.count
        let limit = min(maxEdits, n + m)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        // trace[d] holds the furthest-reaching x for diagonals -d...d after d edits, stored as a slice.
        var trace: [[Int]] = []
        var finalD: Int?

        search: for d in 0...limit {
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]          // step down: an insertion from b
                } else {
                    x = v[offset + k - 1] + 1      // step right: a deletion from a
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    finalD = d
                    break search
                }
            }
            trace.append(Array(v[(offset - d)...(offset + d)]))
        }

        guard let D = finalD else { return nil }

        // Walk back from the end point to (0, 0), one edit at a time.
        var steps: [Step] = []
        var x = n
        var y = m
        var d = D
        while d > 0 {
            let previous = trace[d - 1]
            func previousX(_ diagonal: Int) -> Int { previous[diagonal + d - 1] }
            let k = x - y
            let cameDown = k == -d || (k != d && previousX(k - 1) < previousX(k + 1))
            let prevK = cameDown ? k + 1 : k - 1
            let prevX = previousX(prevK)
            let prevY = prevX - prevK
            // Where the edit lands; the snake between it and (x, y) is all matches.
            let midX = cameDown ? prevX : prevX + 1
            let midY = cameDown ? prevY + 1 : prevY
            while x > midX, y > midY {
                x -= 1
                y -= 1
                steps.append(.equal)
            }
            steps.append(cameDown ? .insert(prevY) : .delete(prevX))
            x = prevX
            y = prevY
            d -= 1
        }
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            steps.append(.equal)
        }
        return steps.reversed()
    }
}
