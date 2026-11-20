import Darwin
import Foundation

/// A durable record of dispatch attempts. The journal never drives execution.
struct OperationJournal: Sendable {
    struct Entry: Codable, Sendable {
        /// `reported` marks an unfinished intent that was already shown to the model after a restart.
        enum Phase: String, Codable, Sendable { case intent, outcome, reported }

        let operationID: UUID
        let requestID: UUID
        let tool: String
        /// The app the operation targeted, if any. Never arguments, labels or reply text.
        let app: String?
        let phase: Phase
        let state: DeliveryState
        let time: Date
    }

    private struct Recording: Sendable {
        let journal: OperationJournal
        let requestID = UUID()
    }

    /// The durability steps taken for each append, in order. Tests observe them through `onFlush`.
    enum Flush: Sendable, Equatable { case fullSync, fsync, directory }

    @TaskLocal private static var recording: Recording?

    static let shared = OperationJournal(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".godspeed/journal", isDirectory: true))

    let directory: URL
    var onFlush: (@Sendable (Flush) -> Void)? = nil
    private var file: URL { directory.appendingPathComponent("operations.jsonl") }

    static func withRecording<T>(_ journal: Self = shared, _ body: () throws -> T) rethrows -> T {
        if recording != nil { return try body() }
        return try $recording.withValue(Recording(journal: journal), operation: body)
    }

    static func recordStep(
        tool: String, arguments: [String: Any], _ body: () throws -> ToolCallResult
    ) throws -> ToolCallResult {
        guard let recording, mustRecord(tool: tool, arguments: arguments) else { return try body() }
        return try recording.journal.record(tool: tool, requestID: recording.requestID, app: appName(arguments), body)
    }

    private static func appName(_ arguments: [String: Any]) -> String? {
        guard let app = arguments["app"] as? String else { return nil }
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    private static func mustRecord(tool: String, arguments: [String: Any]) -> Bool {
        guard ToolDefinitions.isKnown(tool), tool != BatchTool.name, tool != HandoffTool.name else { return false }
        let action = (arguments["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if tool == "browser", let action {
            if action == "batch" { return false }
            if ["peek", "open_many", "read_many"].contains(ComputerUseToolDispatcher.canonicalBrowserAction(action)) {
                return true // The preview creates temporary tabs.
            }
        }
        if tool == "query", let app = arguments["app"] as? String, SettingsPanes.isSettings(app) {
            return SettingsPanes.paneName(in: arguments) != nil
        }
        if tool == "get_app_state", let placement = arguments["window_placement"] as? String {
            return ["agent_display", "restore"].contains(placement.lowercased())
        }
        return !BatchTool.Step(tool: tool, arguments: arguments).isReadOnly
    }

    func record(tool: String, requestID: UUID, app: String? = nil, _ body: () throws -> ToolCallResult) throws -> ToolCallResult {
        let intent: Entry
        do { intent = try begin(tool: tool, requestID: requestID, app: app) }
        catch {
            throw ComputerUseError.notSent("The operation journal could not save the intent. No input was sent.")
        }

        if RequestCancellation.requested {
            try? finish(intent, state: .notSent)
            throw RequestCancellation.Cancelled(deliveryState: .notSent)
        }
        let result: ToolCallResult
        do { result = try body() }
        catch {
            try? finish(intent, state: ToolCallResult.delivery(of: error))
            throw error
        }

        do {
            try finish(intent, state: result.deliveryState)
        } catch {
            throw ComputerUseError.stateUnavailable("The operation journal could not save the outcome. Outcome unknown. Inspect the result before retrying.")
        }
        return result
    }

    func begin(tool: String, requestID: UUID, app: String? = nil) throws -> Entry {
        // Keep the journal free of request payloads, target labels and reply text.
        guard ToolDefinitions.isKnown(tool) else { throw CocoaError(.fileWriteUnknown) }
        let entry = Entry(operationID: UUID(), requestID: requestID, tool: tool, app: app, phase: .intent,
                          state: .outcomeUnknown, time: Date())
        try append(entry)
        return entry
    }

    func finish(_ intent: Entry, state: DeliveryState) throws {
        try append(Entry(operationID: intent.operationID, requestID: intent.requestID, tool: intent.tool,
                         app: intent.app, phase: .outcome, state: state, time: Date()))
    }

    /// Intents with no outcome and no report yet. Recovery never replays them.
    func unfinishedIntents() throws -> [Entry] {
        try recoveredEntries().filter { $0.phase == .intent }
    }

    func markReported(_ entries: [Entry]) throws {
        for entry in entries {
            try append(Entry(operationID: entry.operationID, requestID: entry.requestID, tool: entry.tool,
                             app: entry.app, phase: .reported, state: entry.state, time: Date()))
        }
    }

    /// An intent without an outcome stays unknown. Reading the file has no side effects.
    func recoveredEntries() throws -> [Entry] {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return [] }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try lock(fd, mode: LOCK_SH)
        let data = try handle.readToEnd() ?? Data()
        let decoder = JSONDecoder()
        var entries: [UUID: Entry] = [:]
        for line in data.split(separator: 10) {
            // An interrupted append can leave a partial line. An earlier synced intent still stands.
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) {
                entries[entry.operationID] = entry
            }
        }
        return entries.values.sorted { $0.time < $1.time }
    }

    private func append(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let created = !FileManager.default.fileExists(atPath: file.path)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try lock(fd, mode: LOCK_EX)
        let json = try JSONEncoder().encode(entry)
        // Start on a new line even when the last writer died mid-append.
        try handle.write(contentsOf: Data([10]) + json + Data([10]))
        try flushToDisk(fd)
        // A new file is only durable once its directory entry is durable too.
        if created { try syncDirectory() }
    }

    /// macOS fsync does not flush the drive cache. F_FULLFSYNC does, so fsync is only the fallback.
    private func flushToDisk(_ fd: Int32) throws {
        onFlush?(.fullSync)
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        onFlush?(.fsync)
        while fsync(fd) != 0 {
            if errno != EINTR { throw posixError() }
        }
    }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        onFlush?(.directory)
        while fsync(fd) != 0 {
            if errno != EINTR { throw posixError() }
        }
    }

    private func lock(_ fd: Int32, mode: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw POSIXError(.EACCES)
        }
        while flock(fd, mode) != 0 {
            if errno != EINTR { throw posixError() }
        }
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Tells the model once per process about intents that a crash or restart left unfinished.
final class RestartNoticeState: @unchecked Sendable {
    static let shared = RestartNoticeState(journal: .shared)

    private let lock = NSLock()
    private let journal: OperationJournal
    private var pending: [OperationJournal.Entry]?
    private var delivered = false

    init(journal: OperationJournal) { self.journal = journal }

    /// The notice text for the next tool reply, or nil. Entries are marked reported when text is returned.
    func claim() -> String? {
        lock.withLock {
            guard !delivered else { return nil }
            if pending == nil {
                // A read failure leaves the notice for a later reply.
                guard let found = try? journal.unfinishedIntents() else { return nil }
                pending = found
            }
            guard let entries = pending, !entries.isEmpty else {
                delivered = true
                return nil
            }
            delivered = true
            // Even when the mark fails, the model hears about these once. The next start may repeat it.
            try? journal.markReported(entries)
            let names = entries.map { entry in entry.app.map { "\(entry.tool) in \($0)" } ?? entry.tool }
            let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
            return "After a restart: \(shown) may or may not have happened. Read the app before repeating it."
        }
    }
}

/// Adds the restart notice to the first tool reply of this process.
public enum OperationRestartNotice {
    public static func attach(to envelope: [String: Any], requestLine: String) -> [String: Any] {
        attach(to: envelope, requestLine: requestLine, state: .shared)
    }

    static func attach(to envelope: [String: Any], requestLine: String, state: RestartNoticeState) -> [String: Any] {
        guard let request = try? JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any] else { return envelope }
        // Pipelined MCP lines arrive wrapped as {"kind":"mcp","line":...}.
        let rpcText = request["kind"] as? String == "mcp" ? request["line"] as? String : requestLine
        guard let rpcText, let call = try? JSONSerialization.jsonObject(with: Data(rpcText.utf8)) as? [String: Any],
              call["method"] as? String == "tools/call",
              let line = envelope["response"] as? String,
              var rpc = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              var result = rpc["result"] as? [String: Any],
              var content = result["content"] as? [[String: Any]],
              let text = state.claim()
        else { return envelope }
        content.append(["type": "text", "text": text])
        result["content"] = content
        rpc["result"] = result
        guard let data = try? JSONSerialization.data(withJSONObject: rpc, options: [.withoutEscapingSlashes]),
              let rewritten = String(data: data, encoding: .utf8) else { return envelope }
        var output = envelope
        output["response"] = rewritten
        return output
    }
}

/// Enables the local write-ahead journal for a production CLI call.
public func withOperationJournal<T>(_ body: () throws -> T) rethrows -> T {
    try OperationJournal.withRecording { try body() }
}
