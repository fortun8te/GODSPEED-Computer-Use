import Foundation

/// Resumable batches. A batch that stops keeps the steps it did not send for 24 hours, so `batch` with
/// `resume` can run them after a fresh read. Only step structure is stored: typed text is replaced by a slot
/// name, and the caller supplies its value again through `values`. Steps that ran are listed, never replayed.
enum BatchResume {
    static let lifetime: TimeInterval = 24 * 60 * 60

    /// Tests point the store at a temporary folder. Production uses the journal folder.
    @TaskLocal static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".godspeed/journal/resume", isDirectory: true)
    }

    /// Argument keys whose value may be typed text or a secret. Each becomes a slot the caller supplies again.
    static let slotKeys: [String] = ["text", "value"]

    struct Stored: Codable, Sendable {
        let number: Int
        let tool: String
        /// JSON of the step's arguments, without window_id and without slot values.
        let arguments: Data
        /// Argument key to the slot name that holds its value on resume.
        let slots: [String: String]
    }

    struct Sent: Codable, Sendable {
        let number: Int
        let tool: String
        let state: DeliveryState
    }

    struct Record: Codable, Sendable {
        let id: String
        let createdAt: Date
        let expiresAt: Date
        let app: String?
        let goal: String
        /// JSON of the done_when argument, if the batch had one.
        let doneWhen: Data?
        let windowID: UInt32?
        let processID: Int32?
        let total: Int
        /// Steps that did not run: never attempted, or refused before any input was sent.
        let pending: [Stored]
        /// Mutating steps that ran. Never resumed automatically; the reply names them.
        let sent: [Sent]
        var strictBackground: Bool? = nil
        var backgroundOnly: Bool? = nil

        var slotNames: [String] { pending.flatMap { $0.slots.values }.sorted() }
    }

    /// The record for a stopped batch, or nil when every step ran or a step cannot be stored as JSON.
    static func record(steps: [BatchTool.Step], receipt: TrajectoryLog.BatchReceipt, goal: String, doneWhen: Any?,
                       app: String?, windowID: UInt32?, processID: Int32?, now: Date = Date(),
                       continuing prior: Record? = nil) -> Record? {
        guard prior == nil || prior?.pending.count == steps.count else { return nil }
        var pending: [Stored] = []
        var sent = prior?.sent ?? []
        for (index, step) in steps.enumerated() {
            let number = prior?.pending[index].number ?? index + 1
            if index < receipt.steps.count, receipt.steps[index].deliveryState != .notSent {
                let state = receipt.steps[index].deliveryState
                if !step.isReadOnly { sent.append(Sent(number: number, tool: step.tool, state: state)) }
                continue
            }
            // Resume preflight is a native window read. Browser steps need their own tab/driver binding.
            guard step.tool != "browser",
                  let stored = stored(step, number: number, batchWindowID: windowID) else { return nil }
            pending.append(stored)
        }
        guard !pending.isEmpty else { return nil }
        let doneData = doneWhen.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
        return Record(id: UUID().uuidString, createdAt: now, expiresAt: now.addingTimeInterval(lifetime),
                      app: app, goal: goal, doneWhen: doneData, windowID: windowID, processID: processID,
                      total: prior?.total ?? steps.count, pending: pending, sent: sent.sorted { $0.number < $1.number },
                      strictBackground: StrictBackground.enabled(), backgroundOnly: backgroundOnlyMode())
    }

    static func stored(_ step: BatchTool.Step, number: Int, batchWindowID: UInt32?) -> Stored? {
        var arguments = step.arguments
        if step.tool != HandoffTool.name, let batchWindowID,
           (try? validatedQueryWindowID(arguments["window_id"])) == batchWindowID {
            arguments.removeValue(forKey: "window_id")
        }
        var slots: [String: String] = [:]
        let privateKeys = step.tool == HandoffTool.name
            ? slotKeys + ["values", "expected_values", "done_when"] : slotKeys
        for key in privateKeys where arguments[key] != nil {
            arguments.removeValue(forKey: key)
            slots[key] = "step-\(number)-\(key)"
        }
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else { return nil }
        return Stored(number: number, tool: step.tool, arguments: data, slots: slots)
    }

    /// Steps ready to run again: arguments decoded, slot values filled from `values`. Throws when a slot is missing.
    static func steps(of record: Record, values: [String: Any]) throws -> [BatchTool.Step] {
        let missing = record.pending.flatMap { step in
            step.slots.compactMap { key, slot -> String? in
                let value = values[slot]
                let valid: Bool
                switch key {
                case "values", "done_when": valid = value is [String: Any] || value is [Any]
                case "expected_values": valid = value is [String: String]
                default: valid = value is String
                }
                return valid ? nil : slot
            }
        }.sorted()
        guard missing.isEmpty else {
            throw ComputerUseError.invalidArguments("Provide these values again to resume: \(missing.joined(separator: ", ")).")
        }
        return try record.pending.map { stored in
            guard let object = try JSONSerialization.jsonObject(with: stored.arguments) as? [String: Any] else {
                throw ComputerUseError.invalidArguments("The saved resume step \(stored.number) is unreadable. Send the steps again.")
            }
            var arguments = object
            for (key, slot) in stored.slots { arguments[key] = values[slot] }
            return BatchTool.Step(tool: stored.tool, arguments: arguments)
        }
    }

    /// Refuses an expired token, or one whose app process or pinned window is no longer the same.
    static func check(_ record: Record, now: Date, liveProcessID: Int32?, liveWindowID: UInt32?) throws {
        guard now < record.expiresAt else {
            throw ComputerUseError.invalidArguments("RESUME_EXPIRED. The resume token is older than 24 hours. Read the app and send the remaining steps again.")
        }
        guard record.processID == liveProcessID, record.windowID == nil || record.windowID == liveWindowID else {
            if let windowID = record.windowID { throw ComputerUseError.windowChanged(windowID) }
            throw ComputerUseError.invalidArguments("WINDOW_CHANGED. The app changed since the batch stopped. Read it again and send the remaining steps.")
        }
    }

    /// Writes the record under its id. Expired records are removed on the way.
    static func save(_ record: Record, now: Date = Date()) throws {
        let folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        prune(folder, now: now)
        let url = folder.appendingPathComponent(record.id + ".json")
        try JSONEncoder().encode(record).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads a token without using it. An expired token is removed on the way.
    static func load(_ id: String, now: Date = Date()) throws -> Record {
        guard UUID(uuidString: id) != nil else {
            throw ComputerUseError.invalidArguments("RESUME_NOT_FOUND. \"\(id)\" is not a resume token from a stopped batch.")
        }
        let url = directory.appendingPathComponent(id.uppercased() + ".json")
        guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data) else {
            throw ComputerUseError.invalidArguments("RESUME_NOT_FOUND. No stopped batch has the token \(id), or it was already resumed. Send the steps again.")
        }
        guard now < record.expiresAt else {
            discard(id)
            throw ComputerUseError.invalidArguments("RESUME_EXPIRED. The resume token is older than 24 hours. Read the app and send the remaining steps again.")
        }
        return record
    }

    /// Ends a token once its steps have started, so the same steps never run twice.
    static func discard(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uppercased() + ".json"))
    }

    /// Claim after preflight. Only one process can remove the stored token and run its steps.
    static func claim(_ id: String) throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ComputerUseError.invalidArguments("RESUME_NOT_FOUND. The resume token is invalid.")
        }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(uuid.uuidString + ".json"))
        } catch {
            throw ComputerUseError.notSent("The resume token could not be claimed. It may already be running or expired. Read the app before continuing.")
        }
    }

    /// Reads and uses a token in one step.
    static func consume(_ id: String, now: Date = Date()) throws -> Record {
        let record = try load(id, now: now)
        try claim(id)
        return record
    }

    /// The live process and pinned window for an app, to compare with a stored record.
    static func liveState(app: String?, windowID: UInt32?) -> (processID: Int32?, windowID: UInt32?) {
        guard let app, let descriptor = try? AppDiscovery.resolveRunning(app) else { return (nil, nil) }
        let window = windowID.flatMap { id in
            (try? SnapshotBuilder.resolveTargetWindow(for: descriptor, windowID: id))?.windowID
        }
        return (descriptor.pid, window.map { UInt32($0) })
    }

    private static func prune(_ folder: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data), now >= record.expiresAt else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Reply lines: the token, the steps it will run, the steps not repeated, and any values to supply.
    static func replyLines(for record: Record) -> [String] {
        var lines = ["Resume \(record.id): steps \(ranges(record.pending.map(\.number))) of \(record.total) did not run. "
            + "Send batch with resume \"\(record.id)\" to run them (valid 24 hours)."]
        if !record.sent.isEmpty {
            let named = record.sent.prefix(5).map { sent in
                "step \(sent.number) \(sent.tool)" + (sent.state == .outcomeUnknown ? " (outcome unknown)" : "")
            }
            let more = record.sent.count > 5 ? " and \(record.sent.count - 5) more" : ""
            lines.append("Not repeated, already sent: \(named.joined(separator: ", "))\(more). Send them again only if still needed.")
        }
        if !record.slotNames.isEmpty {
            lines.append("Provide values for \(record.slotNames.joined(separator: ", ")) when resuming.")
        }
        return lines
    }

    /// "6-10" for a run of consecutive numbers, "2, 5-6" for gaps.
    static func ranges(_ numbers: [Int]) -> String {
        var parts: [String] = []
        var start: Int?
        var last: Int?
        for number in numbers {
            if let current = last, number == current + 1 { last = number; continue }
            if let s = start, let l = last { parts.append(s == l ? "\(s)" : "\(s)-\(l)") }
            start = number
            last = number
        }
        if let s = start, let l = last { parts.append(s == l ? "\(s)" : "\(s)-\(l)") }
        return parts.joined(separator: ", ")
    }
}
