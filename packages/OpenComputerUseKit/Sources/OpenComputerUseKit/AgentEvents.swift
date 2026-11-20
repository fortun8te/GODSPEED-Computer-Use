import Foundation

/// Chrome events the Open Browser Use extension reports on a reply: popups, downloads, closed tabs.
/// The text is untrusted page-side data. It is parsed, cleaned and shortened here, and it never
/// changes what a browser call does.
enum AgentEvent: Equatable {
    case popup(tabID: Int, openerTabID: Int?, url: String?)
    case download(status: DownloadStatus, filename: String?)
    case tabClosed(tabID: Int)
    case dropped(count: Int)

    enum DownloadStatus: String, Equatable {
        case inProgress = "in_progress"
        case complete
        case interrupted
    }
}

/// Parses the optional `agentEvents` field and renders a few short lines for the browser reply.
enum AgentEvents {
    static let environmentKey = "OPEN_COMPUTER_USE_AGENT_EVENTS"
    /// Events kept between browser replies. Older ones are dropped first.
    static let pendingLimit = 50
    /// Events read from one reply. Anything beyond this is ignored.
    static let readLimit = 50
    /// Lines written into a browser reply. The rest are counted in one "more" line.
    static let lineLimit = 5
    static let memoryLimit = 16
    static let textLimit = 80

    /// Events waiting for the next browser reply, and the popups seen recently.
    private final class Inbox: @unchecked Sendable {
        let lock = NSLock()
        var pending: [AgentEvent] = []
        /// Popup tab ids with the tab that opened them. Used only so a later `tabClosed` forgets a popup.
        var popups: [(tabID: Int, openerTabID: Int?)] = []
    }
    private static let inbox = Inbox()

    static var enabled: Bool {
        guard let value = BrowserRequestContext.environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    /// Reads the envelope field, or the MCP `structuredContent` copy when the envelope has none.
    /// Anything malformed is ignored.
    static func receive(_ message: [String: Any]) {
        guard enabled else { return }
        let raw = message["agentEvents"]
            ?? (message["result"] as? [String: Any]).flatMap { ($0["structuredContent"] as? [String: Any])?["agentEvents"] }
        let events = parse(raw)
        guard !events.isEmpty else { return }
        inbox.lock.lock()
        defer { inbox.lock.unlock() }
        for event in events {
            switch event {
            case let .popup(tabID, opener, _):
                inbox.popups.removeAll { $0.tabID == tabID }
                inbox.popups.append((tabID, opener))
                if inbox.popups.count > memoryLimit { inbox.popups.removeFirst(inbox.popups.count - memoryLimit) }
            case let .tabClosed(tabID):
                inbox.popups.removeAll { $0.tabID == tabID }
            default:
                break
            }
        }
        inbox.pending.append(contentsOf: events)
        if inbox.pending.count > pendingLimit { inbox.pending.removeFirst(inbox.pending.count - pendingLimit) }
    }

    /// Returns the reply with any queued event lines appended as text. The queue is emptied.
    static func attach(_ result: ToolCallResult) -> ToolCallResult {
        inbox.lock.lock()
        let events = inbox.pending
        inbox.pending = []
        inbox.lock.unlock()
        let lines = render(events)
        guard !lines.isEmpty else { return result }
        return result.appendingText(lines)
    }

    /// Tab ids of popups seen and not yet closed, oldest first.
    static func rememberedPopupTabs() -> [Int] {
        inbox.lock.lock()
        defer { inbox.lock.unlock() }
        return inbox.popups.map(\.tabID)
    }

    static func resetForTesting() {
        inbox.lock.lock()
        defer { inbox.lock.unlock() }
        inbox.pending = []
        inbox.popups = []
    }

    // MARK: Parsing

    static func parse(_ raw: Any?) -> [AgentEvent] {
        guard let entries = raw as? [Any] else { return [] }
        return entries.prefix(readLimit).compactMap { entry in
            guard let object = entry as? [String: Any], let kind = object["kind"] as? String else { return nil }
            switch kind {
            case "popup":
                guard let tabID = integer(object["tabId"]) else { return nil }
                return .popup(tabID: tabID, openerTabID: integer(object["openerTabId"]), url: object["url"] as? String)
            case "download":
                guard let status = (object["status"] as? String).flatMap(AgentEvent.DownloadStatus.init(rawValue:)) else {
                    return nil
                }
                return .download(status: status, filename: object["filename"] as? String)
            case "tabClosed":
                guard let tabID = integer(object["tabId"]) else { return nil }
                return .tabClosed(tabID: tabID)
            case "dropped":
                guard let count = integer(object["count"]), count > 0 else { return nil }
                return .dropped(count: count)
            default:
                return nil
            }
        }
    }

    /// A non-negative whole number. Booleans and fractions are rejected.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= 0, double <= 1_000_000_000 else { return nil }
        return Int(double)
    }

    // MARK: Rendering

    static func render(_ events: [AgentEvent]) -> [String] {
        guard !events.isEmpty else { return [] }
        var lines = events.prefix(lineLimit).map(line(for:))
        let hidden = events.count - lineLimit
        if hidden > 0 { lines.append("\(hidden) more events not shown") }
        return lines
    }

    static func line(for event: AgentEvent) -> String {
        switch event {
        case let .popup(tabID, opener, url):
            var text = "Popup opened: tab \(tabID)"
            if let opener { text += " (from tab \(opener))" }
            if let short = shortURL(url) { text += " \(short)" }
            return text
        case let .download(status, filename):
            let name = shortFilename(filename) ?? "file"
            switch status {
            case .inProgress: return "Download started: \(name)"
            case .complete: return "Download complete: \(name)"
            case .interrupted: return "Download failed: \(name) (interrupted)"
            }
        case let .tabClosed(tabID):
            return "Tab \(tabID) closed"
        case let .dropped(count):
            return "Browser dropped \(count) agent \(count == 1 ? "event" : "events")"
        }
    }

    /// host and path only, http(s) only. Query strings and fragments are dropped.
    static func shortURL(_ raw: String?) -> String? {
        guard let raw, let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { return nil }
        let path = parts.path == "/" ? "" : parts.path
        return clip(clean(host + path))
    }

    /// The last path component only, so no directories leak into the reply.
    static func shortFilename(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let name = clip(clean(base))
        return name.isEmpty ? nil : name
    }

    /// Replaces control, format, and line/paragraph separator characters with spaces, then collapses runs of spaces.
    static func clean(_ text: String) -> String {
        let replaced = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return " "
            default: return scalar
            }
        }))
        return replaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func clip(_ text: String) -> String {
        guard text.count > textLimit else { return text }
        return String(text.prefix(textLimit - 1)) + "…"
    }
}

extension ToolCallResult {
    /// The same reply with extra text appended as its own content items.
    func appendingText(_ lines: [String]) -> ToolCallResult {
        ToolCallResult(
            content: content + lines.map { ToolResultContentItem.text($0) },
            isError: isError,
            batchReceipt: batchReceipt,
            failureCode: failureCode,
            browserObservationURL: browserObservationURL,
            browserContinuationTabID: browserContinuationTabID,
            browserPreviewPages: browserPreviewPages,
            browserFullObservationText: browserFullObservationText,
            browserEvidenceScope: browserEvidenceScope,
            deliveryState: deliveryState
        )
    }
}
