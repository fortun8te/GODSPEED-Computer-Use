import Foundation

/// A stopped batch keeps pending step structure and delivery receipts for 24 hours.
/// Typed values are replaced with slots that the caller fills on resume.
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
        var observation: String? = nil
        var verification: String? = nil
        var tabID: String? = nil
        var failureCode: String? = nil
        var durationMs: Double? = nil
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
        /// Steps that ran or may have run, including completed reads and waits.
        let sent: [Sent]
        /// The initial concrete window, including for batches without an explicit pin.
        var originalWindowID: UInt32? = nil
        var requiresFreshSteps: Bool? = nil
        var strictBackground: Bool? = nil
        var backgroundOnly: Bool? = nil

        var slotNames: [String] { pending.flatMap { $0.slots.values }.sorted() }
    }

    /// Builds a checkpoint using the original target and step numbers.
    static func record(steps: [BatchTool.Step], receipt: TrajectoryLog.BatchReceipt, goal: String, doneWhen: Any?,
                       app: String?, windowID: UInt32?, processID: Int32?, now: Date = Date(),
                       originalWindowID: UInt32? = nil, browserTabs: [Int: Int] = [:],
                       requiresFreshSteps: Bool = false, continuing prior: Record? = nil) -> Record? {
        guard prior == nil || prior?.pending.count == steps.count else { return nil }
        var pending: [Stored] = []
        var sent = prior?.sent ?? []
        for (index, step) in steps.enumerated() {
            let number = prior?.pending[index].number ?? index + 1
            if index < receipt.steps.count, receipt.steps[index].deliveryState != .notSent {
                let result = receipt.steps[index]
                let state: DeliveryState = result.observation == .outcomeUnknown ? .outcomeUnknown : result.deliveryState
                let tab = step.tool == "browser"
                    ? browserTabs[index].map { String($0) } ?? step.arguments["tab_id"].map { String(describing: $0) }
                    : nil
                sent.append(Sent(number: number, tool: step.tool, state: state,
                                 observation: result.observation?.rawValue,
                                 verification: result.verification?.rawValue,
                                 tabID: tab, failureCode: result.failureCode?.rawValue, durationMs: result.durationMs))
                continue
            }
            guard let stored = stored(step, number: number, batchWindowID: windowID) else { return nil }
            pending.append(stored)
        }
        guard !pending.isEmpty || (receipt.stop != nil && !sent.isEmpty) else { return nil }
        let doneData = doneWhen.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
        return Record(id: UUID().uuidString, createdAt: now, expiresAt: now.addingTimeInterval(lifetime),
                      app: prior == nil ? app : prior?.app, goal: prior?.goal ?? goal, doneWhen: prior?.doneWhen ?? doneData,
                      windowID: prior == nil ? windowID : prior?.windowID,
                      processID: prior == nil ? processID : prior?.processID,
                      total: prior?.total ?? steps.count, pending: pending, sent: sent.sorted { $0.number < $1.number },
                      originalWindowID: prior == nil ? originalWindowID : prior?.originalWindowID,
                      requiresFreshSteps: prior?.requiresFreshSteps ?? requiresFreshSteps,
                      strictBackground: StrictBackground.enabled(), backgroundOnly: backgroundOnlyMode())
    }

    static func stored(_ step: BatchTool.Step, number: Int, batchWindowID: UInt32?) -> Stored? {
        // Browser continuations require a fresh driver/tab inspection. Keep only
        // the operation number and explicit tab, never URLs or browser payloads.
        var arguments = step.tool == "browser"
            ? step.arguments.filter { $0.key == "tab_id" } : step.arguments
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
        guard !record.pending.contains(where: { $0.tool == "browser" }) else {
            throw ComputerUseError.notSent("Inspect the browser tab and send the remaining steps explicitly.")
        }
        if record.requiresFreshSteps == true {
            throw ComputerUseError.notSent("Read the recipe target and send the remaining steps explicitly.")
        }
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
            let normalized = ArgumentNormalizer.normalize(tool: stored.tool, arguments: object, lastApp: record.app)
            if BatchTool.usesPositionalTargets([.init(tool: stored.tool, arguments: object)])
                || BatchTool.usesPositionalTargets([.init(tool: stored.tool, arguments: normalized)]) {
                throw ComputerUseError.notSent("Resume step \(stored.number) uses a target tied to an old snapshot. Read the target and send the remaining steps with fresh targets.")
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
        let window = record.windowID ?? record.originalWindowID
        guard let processID = record.processID, processID == liveProcessID,
              let window, window == liveWindowID else {
            if let windowID = window { throw ComputerUseError.windowChanged(windowID) }
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

    /// Claim after preflight. Moving the token keeps its receipts while preventing another run.
    static func claim(_ id: String) throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ComputerUseError.invalidArguments("RESUME_NOT_FOUND. The resume token is invalid.")
        }
        do {
            let source = directory.appendingPathComponent(uuid.uuidString + ".json")
            let claimed = directory.appendingPathComponent(uuid.uuidString + ".claimed.json")
            try FileManager.default.moveItem(at: source, to: claimed)
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

    /// Resolves the process and requested or current window from the same app descriptor.
    static func liveState(app: String?, windowID: UInt32?) -> (processID: Int32?, windowID: UInt32?) {
        guard let app, let descriptor = try? AppDiscovery.resolveRunning(app) else { return (nil, nil) }
        let window = (try? SnapshotBuilder.resolveTargetWindow(for: descriptor, windowID: windowID))?.windowID
        return (descriptor.pid, window)
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
        let pending = ranges(record.pending.map(\.number))
        var lines = [record.pending.isEmpty
            ? "Batch checkpoint \(record.id)."
            : "Resume \(record.id): steps \(pending) of \(record.total) did not run."]
        if record.sent.contains(where: { $0.state == .outcomeUnknown }) {
            lines.append("Inspect the uncertain step before sending any remaining actions.")
        } else if record.pending.contains(where: { $0.tool == "browser" }) || record.sent.contains(where: { $0.tool == "browser" }) {
            lines.append("Inspect the browser tab and send the remaining steps explicitly.")
        } else if !record.pending.isEmpty, record.requiresFreshSteps == true || record.app == nil || record.processID == nil
                    || (record.windowID ?? record.originalWindowID) == nil {
            lines.append("Read the target and send the remaining steps explicitly.")
        } else if !record.pending.isEmpty {
            lines.append("Send batch with resume \"\(record.id)\" to continue if the original target still matches (valid 24 hours).")
        }
        if !record.sent.isEmpty {
            let named = record.sent.prefix(5).map { sent in
                let detail = sent.state == .outcomeUnknown ? "outcome unknown" : sent.verification ?? sent.observation ?? sent.state.rawValue
                let tab = sent.tabID.map { " on tab \($0)" } ?? ""
                return "step \(sent.number) \(sent.tool) (\(detail))\(tab)"
            }
            let more = record.sent.count > 5 ? " and \(record.sent.count - 5) more" : ""
            lines.append("Saved receipts: \(named.joined(separator: ", "))\(more). Inspect the current state before deciding what to do next.")
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
