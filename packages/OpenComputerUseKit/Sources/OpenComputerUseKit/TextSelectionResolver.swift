import Foundation

/// How `select_text` maps a matched text range onto the accessibility selection range.
public enum TextSelectionMode: String, CaseIterable, Sendable {
    case text
    case cursorBefore = "cursor_before"
    case cursorAfter = "cursor_after"
}

/// A resolved accessibility selection target.
///
/// Offsets are UTF-16 code units because `kAXSelectedTextRangeAttribute` carries a `CFRange`
/// whose units follow the backing `CFString`, not Swift `Character` counts.
public struct TextSelectionTarget: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let matchedLocation: Int
    public let matchedLength: Int
    public let selectionMode: TextSelectionMode
}

public enum TextSelectionResolverError: Error, Equatable {
    case emptyText
    case notFound
    case ambiguous(occurrenceCount: Int)
}

public enum TextSelectionResolver {
    public static func resolve(value: String, start: Int, length: Int) throws -> TextSelectionTarget {
        let units = value.utf16
        guard (0...units.count).contains(start), length >= 0, length <= units.count - start else {
            throw ComputerUseError.invalidArguments("The requested UTF-16 range is outside the field.")
        }
        let from = units.index(units.startIndex, offsetBy: start)
        let to = units.index(from, offsetBy: length)
        // Preserve valid UTF-16 even when a caller gives half of a surrogate pair.
        func isBoundary(_ index: String.UTF16View.Index) -> Bool {
            index == units.endIndex || !(0xDC00...0xDFFF).contains(units[index])
        }
        guard isBoundary(from), isBoundary(to) else {
            throw ComputerUseError.invalidArguments("The range splits a UTF-16 surrogate pair.")
        }
        return TextSelectionTarget(location: start, length: length, matchedLocation: start, matchedLength: length, selectionMode: .text)
    }

    /// Resolves `text` inside `value`, optionally disambiguated by the text immediately before
    /// (`prefix`) and after (`suffix`) it, into the range `select_text` should select.
    ///
    /// Every possible placement counts as an occurrence, including overlapping ones, so an
    /// ambiguous target fails closed instead of silently selecting the first match.
    public static func resolve(
        value: String,
        text: String,
        prefix: String?,
        suffix: String?,
        selection mode: TextSelectionMode
    ) throws -> TextSelectionTarget {
        guard !text.isEmpty else {
            throw TextSelectionResolverError.emptyText
        }

        let leading = normalized(prefix)
        let trailing = normalized(suffix)
        let needle = leading + text + trailing
        let haystack = value as NSString
        let (firstOccurrence, occurrenceCount) = occurrences(of: needle, in: haystack)

        guard let first = firstOccurrence else {
            throw TextSelectionResolverError.notFound
        }

        guard occurrenceCount == 1 else {
            throw TextSelectionResolverError.ambiguous(occurrenceCount: occurrenceCount)
        }

        let matchedLocation = first.location + (leading as NSString).length
        let matchedLength = (text as NSString).length

        switch mode {
        case .text:
            return TextSelectionTarget(
                location: matchedLocation,
                length: matchedLength,
                matchedLocation: matchedLocation,
                matchedLength: matchedLength,
                selectionMode: mode
            )
        case .cursorBefore:
            return TextSelectionTarget(
                location: matchedLocation,
                length: 0,
                matchedLocation: matchedLocation,
                matchedLength: matchedLength,
                selectionMode: mode
            )
        case .cursorAfter:
            return TextSelectionTarget(
                location: matchedLocation + matchedLength,
                length: 0,
                matchedLocation: matchedLocation,
                matchedLength: matchedLength,
                selectionMode: mode
            )
        }
    }

    private static func normalized(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return ""
        }

        return value
    }

    private static func occurrences(of needle: String, in haystack: NSString) -> (NSRange?, Int) {
        guard haystack.length > 0, !needle.isEmpty else { return (nil, 0) }
        var first: NSRange?
        var count = 0
        var searchLocation = 0
        while searchLocation < haystack.length {
            let searchRange = NSRange(location: searchLocation, length: haystack.length - searchLocation)
            // Exact code units keep prefix and target lengths aligned with AX.
            // Canonically equivalent spellings can have different UTF-16 lengths.
            let found = haystack.range(of: needle, options: .literal, range: searchRange)
            guard found.location != NSNotFound else { break }
            if first == nil { first = found }
            count += 1
            searchLocation = found.location + 1
        }
        return (first, count)
    }
}
