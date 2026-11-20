import Darwin
import Foundation

/// A durable record of dispatch attempts. The journal never drives execution.
struct OperationJournal: Sendable {
    // MERGE: switch to L2 DeliveryState
    enum State: String, Codable, Sendable {
        case notSent = "not_sent"
        case outcomeUnknown = "outcome_unknown"
        case acknowledged
        case verified
    }

    struct Entry: Codable, Sendable {
        enum Phase: String, Codable, Sendable { case intent, outcome }

        let operationID: UUID
        let requestID: UUID
        let tool: String
        let phase: Phase
        let state: State
        let time: Date
    }

    private struct Recording: Sendable {
        let journal: OperationJournal
        let requestID = UUID()
    }

    @TaskLocal private static var recording: Recording?

    static let shared = OperationJournal(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".godspeed/journal", isDirectory: true))

    let directory: URL
    private var file: URL { directory.appendingPathComponent("operations.jsonl") }

    static func withRecording<T>(_ journal: Self = shared, _ body: () throws -> T) rethrows -> T {
        if recording != nil { return try body() }
        return try $recording.withValue(Recording(journal: journal), operation: body)
    }

    static func recordStep(
        tool: String, arguments: [String: Any], _ body: () throws -> ToolCallResult
    ) throws -> ToolCallResult {
        guard let recording, mustRecord(tool: tool, arguments: arguments) else { return try body() }
        return try recording.journal.record(tool: tool, requestID: recording.requestID, body)
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

    func record(tool: String, requestID: UUID, _ body: () throws -> ToolCallResult) throws -> ToolCallResult {
        let intent: Entry
        do { intent = try begin(tool: tool, requestID: requestID) }
        catch {
            throw ComputerUseError.stateUnavailable("The operation journal could not save the intent. No input was sent.")
        }

        if RequestCancellation.requested {
            try? finish(intent, state: .notSent)
            throw RequestCancellation.Cancelled()
        }
        let result: ToolCallResult
        do { result = try body() }
        catch {
            try? finish(intent, state: .outcomeUnknown)
            throw error
        }

        do {
            let state: State = result.isError || RequestCancellation.requested ? .outcomeUnknown : .acknowledged
            try finish(intent, state: state)
        } catch {
            throw ComputerUseError.stateUnavailable("The operation journal could not save the outcome. Outcome unknown. Inspect the result before retrying.")
        }
        return result
    }

    func begin(tool: String, requestID: UUID) throws -> Entry {
        // Keep the journal free of request payloads, target labels and reply text.
        guard ToolDefinitions.isKnown(tool) else { throw CocoaError(.fileWriteUnknown) }
        let entry = Entry(operationID: UUID(), requestID: requestID, tool: tool, phase: .intent,
                          state: .outcomeUnknown, time: Date())
        try append(entry)
        return entry
    }

    func finish(_ intent: Entry, state: State) throws {
        try append(Entry(operationID: intent.operationID, requestID: intent.requestID, tool: intent.tool,
                         phase: .outcome, state: state, time: Date()))
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
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try lock(fd, mode: LOCK_EX)
        let json = try JSONEncoder().encode(entry)
        // Start on a new line even when the last writer died mid-append.
        try handle.write(contentsOf: Data([10]) + json + Data([10]))
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

/// Enables the local write-ahead journal for a production CLI call.
public func withOperationJournal<T>(_ body: () throws -> T) rethrows -> T {
    try OperationJournal.withRecording { try body() }
}
