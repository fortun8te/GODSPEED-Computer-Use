import Foundation

/// Local tool telemetry. Default rows contain outcomes and timing without UI text or arguments.
/// Set OPEN_COMPUTER_USE_TRAJECTORY_CONTENT=1 only for an approved fixture or reviewed recording.
/// Screenshots are never written here. OPEN_COMPUTER_USE_TRAJECTORY_LOG=0 disables the log.
final class TrajectoryLog: @unchecked Sendable {
    static let enabledVariable = "OPEN_COMPUTER_USE_TRAJECTORY_LOG"
    static let contentVariable = "OPEN_COMPUTER_USE_TRAJECTORY_CONTENT"
    /// Opt-in diagnostic detail. Error text may mention an app, filename, or control.
    static let failureDetailVariable = "OPEN_COMPUTER_USE_TRAJECTORY_FAILURES"
    static let failureTextLimit = 700
    static let runIDVariable = "OPEN_COMPUTER_USE_RUN_ID"
    static let resultTextLimit = 6_000
    static let defaultMaxBytes: UInt64 = 20 * 1024 * 1024
    /// Whole-folder cap: when the folder passes it, the oldest session files are deleted first.
    static let defaultDirectoryMaxBytes: UInt64 = 400 * 1024 * 1024
    static let disabledValues = ["0", "false", "no", "off"]
    static let redactedValue = "[redacted]"

    /// Words that mark a password or secure field, matched case-insensitively.
    static let secureFieldMarkers = ["password", "passcode", "secure"]
    /// Argument keys that name the target element. A secure marker in one of these marks the whole call.
    static let targetKeys: Set<String> = [
        "label", "labels", "role", "element_role", "subrole", "name", "title", "placeholder", "description", "identifier",
    ]
    /// Argument keys that carry typed or filled text, which is dropped for a secure target.
    static let valueKeys: Set<String> = [
        "text", "value", "content", "input", "string", "new_value", "newValue", "to", "message", "body", "fill", "phrase",
    ]

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".godspeed/trajectories", isDirectory: true)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        let value = environment[enabledVariable]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !disabledValues.contains(value)
    }

    let isEnabled: Bool
    private let capturesContent: Bool
    private let capturesFailures: Bool
    private let driverVersion: String?
    let sessionID: String
    let runID: String?
    let directory: URL

    private let fileURL: URL
    private let maxBytes: UInt64
    private let directoryMaxBytes: UInt64
    private let queue = DispatchQueue(label: "dev.godspeed.trajectory-log", qos: .utility)
    private let formatter: ISO8601DateFormatter

    // Only touched on `queue`.
    private var prepared = false
    private var bytesWritten: UInt64 = 0
    private var sequence: UInt64 = 0
    private var stopped = false
    private var callsSinceSessionEnd = false

    init(
        environment: [String: String],
        directory: URL = TrajectoryLog.defaultDirectory,
        maxBytes: UInt64 = TrajectoryLog.defaultMaxBytes,
        directoryMaxBytes: UInt64 = TrajectoryLog.defaultDirectoryMaxBytes
    ) {
        isEnabled = Self.isEnabled(environment: environment)
        driverVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        capturesContent = ["1", "true", "yes", "on"].contains(
            environment[Self.contentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
        capturesFailures = ["1", "true", "yes", "on"].contains(
            environment[Self.failureDetailVariable]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
        let run = environment[Self.runIDVariable].map(Self.safeFileComponent).flatMap { $0.isEmpty ? nil : $0 }
        runID = run
        // The run groups workers. Each connection owns its stream and byte budget.
        sessionID = UUID().uuidString.lowercased()
        self.directory = directory
        fileURL = directory.appendingPathComponent(sessionID + ".jsonl")
        self.maxBytes = maxBytes
        self.directoryMaxBytes = directoryMaxBytes
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Records one top-level tool call that returned a result. Argument values for secure targets and
    /// secure lines in the result text are redacted; the screenshot bytes are never stored.
    func recordToolCall(name: String, arguments: [String: Any], result: ToolCallResult, startedAt: Date, admissionMs: Double? = nil) {
        guard isEnabled else { return }
        let screenshotReturned = result.content.contains { $0.dictionary["type"] as? String == "image" }
        let primary = result.primaryText ?? ""
        let output = capturesContent && name != "clipboard" ? result.textContent : ""
        let redacted = Self.redactSecureLines(output)
        let (text, truncated) = Self.limit(redacted)
        // Unlabelled typing can target a secure field. Keep the full payload out of its trace.
        let safeArguments = name == "clipboard" ? [:] : (capturesContent && Self.focusesSecureField(output)
            ? Self.redactTypedValues(arguments) : arguments)
        let receipts = capturesContent && name == BatchTool.name
            ? result.primaryText.flatMap { Self.parseReceipts(Self.redactSecureLines($0)) } : nil
        submitCall(
            name: name,
            arguments: safeArguments,
            isError: result.isError,
            resultText: text,
            resultTruncated: truncated,
            replyTextBytes: result.content.reduce(0) { total, item in
                total + ((item.dictionary["text"] as? String)?.utf8.count ?? 0)
            },
            screenshotReturned: screenshotReturned,
            startedAt: startedAt,
            admissionMs: admissionMs,
            receipts: receipts,
            batchReceipt: result.batchReceipt,
            failureText: result.isError ? primary : nil,
            failureCode: result.isError
                ? result.batchReceipt?.failureCode ?? result.failureCode ?? .toolError : nil,
            visionUsed: primary.hasPrefix("No accessibility element is labelled ") && primary.contains("found it on screen and clicked at")
        )
    }

    /// Records one top-level tool call that threw instead of returning a result.
    func recordFailedToolCall(name: String, arguments: [String: Any], error: Error, startedAt: Date, admissionMs: Double? = nil) {
        guard isEnabled else { return }
        let isError = true
        let message = (error as? ComputerUseError)?.errorDescription
            ?? (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        let (text, truncated) = capturesContent ? Self.limit(Self.redactSecureLines(message)) : ("", false)
        submitCall(
            name: name,
            arguments: name == "clipboard" ? [:] : arguments,
            isError: isError,
            resultText: text,
            resultTruncated: truncated,
            screenshotReturned: false,
            startedAt: startedAt,
            admissionMs: admissionMs,
            failureText: message,
            failureCode: Self.failureCode(error: error)
        )
    }

    func recordAdmissionTimeout(name: String, admissionMs: Double) {
        guard isEnabled else { return }
        submitCall(
            name: name, arguments: [:], isError: true, resultText: "", resultTruncated: false,
            screenshotReturned: false, startedAt: Date(), admissionMs: admissionMs,
            admissionTimedOut: true, failureCode: .timeout
        )
    }

    /// Writes the `session_end` marker if calls were recorded since the last one. Waits for the queue, so
    /// the marker is on disk before the process exits.
    func sessionEnded() {
        guard isEnabled else { return }
        queue.sync {
            guard callsSinceSessionEnd, !stopped else { return }
            callsSinceSessionEnd = false
            _ = appendLine(["event": "session_end", "session_id": sessionID, "run_id": runIDValue], timestamp: Date())
        }
    }

    /// Waits until every record queued so far has been written.
    func flush() {
        queue.sync {}
    }

    // MARK: - Record construction

    private var runIDValue: Any {
        runID.map { $0 as Any } ?? NSNull()
    }

    private func submitCall(
        name: String,
        arguments: [String: Any],
        isError: Bool,
        resultText: String,
        resultTruncated: Bool,
        replyTextBytes: Int? = nil,
        screenshotReturned: Bool,
        startedAt: Date,
        admissionMs: Double? = nil,
        admissionTimedOut: Bool = false,
        receipts: Receipts? = nil,
        batchReceipt: BatchReceipt? = nil,
        failureText: String? = nil,
        failureCode: FailureCode? = nil,
        visionUsed: Bool = false
    ) {
        let duration = (Date().timeIntervalSince(startedAt) * 1000 * 10).rounded() / 10
        var object: [String: Any] = [
            "event": "tool_call",
            "schema_version": 3,
            "capture_mode": capturesContent ? "content" : "metadata",
            "session_id": sessionID,
            "run_id": runIDValue,
            "tool": ToolDefinitions.isKnown(name) ? name : "unknown",
            "is_error": isError,
            "vision_click": visionUsed,
            "screenshot_returned": screenshotReturned,
            "duration_ms": duration,
        ]
        object["driver_build"] = driverVersion
        object["reply_text_bytes"] = replyTextBytes
        if let admissionMs, admissionMs.isFinite, admissionMs >= 0 {
            object["admission_ms"] = (admissionMs * 10).rounded() / 10
        }
        if admissionTimedOut { object["admission_timed_out"] = true }
        object["failure_code"] = failureCode?.rawValue
        if let batchReceipt {
            object["batch_steps"] = batchReceipt.steps.count
            object["batch_failed"] = isError
            object["decision_hint"] = batchReceipt.decisionHint
            object["batch_step_receipts"] = batchReceipt.steps.enumerated().map { offset, step in
                step.metadata(number: offset + 1)
            }
            object["batch_stop_code"] = batchReceipt.stop?.rawValue
            object["batch_recovery"] = batchReceipt.recovery
            object["batch_not_run"] = batchReceipt.totalSteps - batchReceipt.steps.count
            object["batch_observation"] = batchReceipt.observation.rawValue
            object["batch_done_check"] = batchReceipt.doneCheck.rawValue
        }
        if capturesFailures, !capturesContent, isError, name != "clipboard" {
            object["failure_detail"] = Self.sanitize(Self.failureDetail(text: failureText ?? "", arguments: arguments))
        }
        if capturesContent {
            object["arguments"] = Self.sanitize(arguments)
            object["result_text"] = resultText
            object["result_truncated"] = resultTruncated
            if let receipts {
                if !receipts.steps.isEmpty { object["steps"] = receipts.steps }
                if let check = receipts.check { object["check"] = check }
            }
        }
        let pending = PendingRecord(timestamp: startedAt, object: object)
        queue.async {
            if self.appendLine(pending.object, timestamp: pending.timestamp) {
                self.callsSinceSessionEnd = true
            }
        }
    }

    // MARK: - Writing (queue only)

    /// Appends one line, or stops logging with a single note when the session would pass the size cap.
    private func appendLine(_ object: [String: Any], timestamp: Date) -> Bool {
        guard !stopped, prepareIfNeeded() else { return false }
        var body = object
        body["timestamp"] = formatter.string(from: timestamp)
        sequence += 1
        body["sequence"] = sequence
        guard let line = Self.encodeLine(body) else { return false }
        if bytesWritten + UInt64(line.count) > maxBytes {
            stopped = true
            let note: [String: Any] = [
                "event": "log_capped",
                "session_id": sessionID,
                "run_id": runIDValue,
                "max_bytes": maxBytes,
                "sequence": sequence,
                "timestamp": formatter.string(from: Date()),
            ]
            if let noteLine = Self.encodeLine(note) {
                _ = appendData(noteLine)
            }
            return false
        }
        guard appendData(line) else {
            // A partial write may have left a broken line. Never append over it.
            stopped = true
            return false
        }
        bytesWritten += UInt64(line.count)
        return true
    }

    /// Creates the folder (0700) and reads the existing file size once, so the cap counts the whole session.
    private func prepareIfNeeded() -> Bool {
        if prepared { return true }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return false
        }
        pruneFolder()
        bytesWritten = ((try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        prepared = true
        return true
    }

    /// Deletes the oldest session files (never this session's) while the folder is over its cap.
    private func pruneFolder() {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        var files: [(url: URL, size: UInt64, date: Date)] = urls.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, UInt64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(UInt64(0)) { $0 + $1.size }
        guard total > directoryMaxBytes else { return }
        files.sort { $0.date < $1.date }
        for file in files where total > directoryMaxBytes {
            if file.url.lastPathComponent == fileURL.lastPathComponent { continue }
            if (try? fileManager.removeItem(at: file.url)) != nil { total -= min(total, file.size) }
        }
    }

    private func appendData(_ data: Data) -> Bool {
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static func encodeLine(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }

    // MARK: - Redaction and limits

    /// Whether the state text shows a focused password or secure field.
    static func focusesSecureField(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let lowered = line.lowercased()
            return lowered.contains("focus") && secureFieldMarkers.contains { lowered.contains($0) }
        }
    }

    /// Every typed or filled value in `value` (also inside batch steps and fill fields) replaced.
    static func redactTypedValues(_ value: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, entry) in value {
            if valueKeys.contains(key), entry is String || entry is NSNumber {
                output[key] = redactedValue
            } else if let nested = entry as? [String: Any] {
                output[key] = key == "fields" ? nested.mapValues { _ in redactedValue } : redactTypedValues(nested)
            } else if let list = entry as? [Any] {
                output[key] = list.map { ($0 as? [String: Any]).map(redactTypedValues) ?? $0 }
            } else {
                output[key] = entry
            }
        }
        return output
    }

    /// Replaces the typed or filled values of any call aimed at a password or secure field.
    static func sanitize(_ value: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        let secureTarget = value.contains { key, entry in targetKeys.contains(key) && containsSecureMarker(entry) }
        for (key, entry) in value {
            // A key that names a secure field (a `fields` map entry, say) hides its value.
            if containsSecureMarker(key), !(entry is [String: Any]), !(entry is [Any]) {
                output[key] = redactedValue
            } else if secureTarget, valueKeys.contains(key) {
                output[key] = redactedValue
            } else {
                output[key] = sanitizeValue(entry)
            }
        }
        return output
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return sanitize(dictionary) }
        if let array = value as? [Any] { return array.map(sanitizeValue) }
        return value
    }

    private static func containsSecureMarker(_ value: Any) -> Bool {
        if let text = value as? String {
            let lowered = text.lowercased()
            return secureFieldMarkers.contains { lowered.contains($0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsSecureMarker($0) }
        }
        return false
    }

    /// Result lines about a secure field keep their name but lose the value shown after ` Value: ` or ` = `.
    /// Argument keys whose values describe the call, not the user's content; kept in failure detail.
    static let shapeKeys: Set<String> = [
        "tool", "action", "role", "element_role", "subrole", "key", "key_method", "click_method", "mouse_button", "button",
        "direction", "selection", "app", "window_id", "element_index", "index", "remember", "include_screenshot",
    ]

    /// What a failure needs to be understood later, without the user's content: the first lines of Godspeed's own
    /// message with every quoted label masked and every value from the call blanked, and the arguments reduced to
    /// their shape (descriptive keys kept, every other string replaced by its length).
    static func failureDetail(text: String, arguments: [String: Any]) -> [String: Any] {
        var message = redactSecureLines(text)
        for value in stringValues(in: arguments) where value.count >= 3 {
            message = message.replacingOccurrences(of: value, with: "…")
        }
        message = maskQuoted(message)
        // The reply often continues with the app's state; the reason is in its first lines.
        let head = message.split(separator: "\n", omittingEmptySubsequences: true).prefix(4).joined(separator: " | ")
        let limited = head.count > failureTextLimit ? String(head.prefix(failureTextLimit)) + "…" : head
        return ["message": limited, "arguments": shapeOnly(arguments)]
    }

    /// Quoted text in a message is usually a label from the screen: "…" and '…' keep the sentence readable.
    static func maskQuoted(_ text: String) -> String {
        var output = text
        for pattern in [#""[^"\n]{1,200}""#, #"“[^”\n]{1,200}”"#, #"(?<![\w])'[^'\n]{1,200}'(?![\w])"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let quote = pattern.hasPrefix("“") ? "“…”" : (pattern.contains("'") ? "'…'" : "\"…\"")
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: quote)
        }
        return output
    }

    private static func stringValues(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(stringValues(in:)) }
        if let list = value as? [Any] { return list.flatMap(stringValues(in:)) }
        return []
    }

    /// Arguments reduced to their shape: descriptive keys keep short values, other strings become their length.
    static func shapeOnly(_ value: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, item) in value {
            if let nested = item as? [String: Any] {
                output[key] = shapeOnly(nested)
            } else if let list = item as? [Any] {
                output[key] = list.prefix(20).map { element -> Any in
                    if let dictionary = element as? [String: Any] { return shapeOnly(dictionary) }
                    if let text = element as? String { return "<\(text.count) chars>" }
                    return element
                }
            } else if let text = item as? String {
                output[key] = shapeKeys.contains(key) && !valueKeys.contains(key) ? String(text.prefix(60)) : "<\(text.count) chars>"
            } else {
                output[key] = item
            }
        }
        return output
    }

    static func redactSecureLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { substring -> String in
            let line = String(substring)
            let lowered = line.lowercased()
            guard secureFieldMarkers.contains(where: { lowered.contains($0) }) else { return line }
            for separator in [" Value: ", " = "] {
                if let range = line.range(of: separator) {
                    return String(line[..<range.upperBound]) + redactedValue
                }
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Receipts

    enum FailureCode: String {
        case unsupportedTool = "unsupported_tool"
        case invalidArguments = "invalid_arguments"
        case appNotFound = "app_not_found"
        case permissionDenied = "permission_denied"
        case stateUnavailable = "state_unavailable"
        case staleState = "stale_state"
        case timeout
        case cancelled
        case recipeVerification = "recipe_verification"
        case toolError = "tool_error"
        case internalError = "internal_error"
    }

    static func failureCode(error: Error) -> FailureCode {
        guard let error = error as? ComputerUseError else {
            return error is CancellationError ? .cancelled : .internalError
        }
        switch error {
        case .unsupportedTool: return .unsupportedTool
        case .invalidArguments, .targetNotFound, .ambiguousTarget: return .invalidArguments
        case .appNotFound: return .appNotFound
        case .permissionDenied: return .permissionDenied
        case .stateUnavailable: return .stateUnavailable
        case .staleTarget, .elementGone: return .staleState
        case .timedOut: return .timeout
        case .message, .notSent, .acknowledged: return .toolError
        }
    }

    struct BatchReceipt {
        enum Stop: String {
            case stepFailure = "step_failure"
            case timeBudget = "time_budget"
            case windowChanged = "window_changed"
            case recipeVerification = "recipe_verification"
        }

        enum Observation: String {
            case returned
            case failed
            case unavailable
        }

        enum DoneCheck: String {
            case notRequested = "not_requested"
            case skipped
            case verified
            case weakEvidence = "weak_evidence"
            case unmet
        }

        struct Step {
            var failureCode: FailureCode?
            var observation: BatchEffects.Receipt?
            var durationMs: Double? = nil
            var deliveryState: DeliveryState = .acknowledged

            func metadata(number: Int) -> [String: Any] {
                var fields: [String: Any] = ["n": number, "status": failureCode == nil ? "ok" : "failed"]
                fields["duration_ms"] = durationMs
                fields["failure_code"] = failureCode?.rawValue
                fields["observation"] = observation?.rawValue.replacingOccurrences(of: " ", with: "_")
                for (key, value) in deliveryState.metadata { fields[key] = value }
                return fields
            }
        }

        let totalSteps: Int
        var steps: [Step] = []
        var stop: Stop?
        var observation: Observation = .unavailable
        var decisionHint = false
        var doneCheck: DoneCheck = .notRequested

        var deliveryState: DeliveryState {
            if steps.contains(where: { $0.deliveryState == .outcomeUnknown }) { return .outcomeUnknown }
            if doneCheck == .verified, stop == nil { return .verified }
            return steps.contains { [.acknowledged, .verified].contains($0.deliveryState) } ? .acknowledged : .notSent
        }

        /// Recovery uses expanded step numbers, which can differ from the caller's input array.
        var recovery: [String: Any]? {
            if stop == .timeBudget || stop == .windowChanged {
                guard steps.count < totalSteps else { return nil }
                return ["action": "refresh_then_continue", "step": steps.count + 1]
            }
            if stop != nil, let last = steps.last, last.failureCode != nil {
                let action: String
                switch last.deliveryState.safeRetry {
                case .afterCorrection: action = "fix_then_continue"
                case .reconcileFirst: action = "inspect_before_retry"
                case .doNotRetry: action = "inspect_result"
                }
                return ["action": action, "step": steps.count]
            }
            if stop != nil || doneCheck == .unmet || doneCheck == .weakEvidence || observation == .failed {
                return ["action": "inspect_result"]
            }
            return nil
        }

        var failureCode: FailureCode? {
            stop == .recipeVerification ? .recipeVerification : steps.last?.failureCode
        }
    }

    struct Receipts {
        /// Each step: `n`, `step`, `result`, and `effects` (the indented effect lines under it, if any).
        var steps: [[String: Any]]
        var check: String?
    }

    /// Reads a batch reply: lines like `2. click "Save": ok` with indented `effect:` / `new:` / `gone:` /
    /// `windows:` / `no visible change` lines under them, and an optional `Check:` hint. Nil for other replies.
    static func parseReceipts(_ text: String) -> Receipts? {
        var steps: [[String: Any]] = []
        var check: String?
        for substring in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(substring)
            if line.hasPrefix("Check:") {
                check = String(line.prefix(300))
            } else if let step = parseStepLine(line) {
                steps.append(step)
            } else if line.hasPrefix(" "), !steps.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard isEffectLine(trimmed) else { continue }
                var last = steps[steps.count - 1]
                var effects = last["effects"] as? [String] ?? []
                if effects.count < 12 { effects.append(String(trimmed.prefix(200))) }
                last["effects"] = effects
                steps[steps.count - 1] = last
            } else if line.hasPrefix("Steps "), line.contains("not run"), !steps.isEmpty {
                steps[steps.count - 1]["not_run"] = String(line.prefix(200))
            }
        }
        guard !steps.isEmpty || check != nil else { return nil }
        return Receipts(steps: steps, check: check)
    }

    private static func parseStepLine(_ line: String) -> [String: Any]? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex,
              let number = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") else { return nil }
        let rest = String(line[line.index(dot, offsetBy: 2)...])
        // The result starts after the last `: ok` / `: FAILED` marker, so step text may contain colons.
        var split: Range<String.Index>?
        for marker in [": ok", ": FAILED"] {
            if let range = rest.range(of: marker, options: .backwards), range.lowerBound > (split?.lowerBound ?? rest.startIndex) {
                split = range
            }
        }
        guard let split else { return nil }
        let step = String(rest[..<split.lowerBound])
        let result = String(rest[rest.index(split.lowerBound, offsetBy: 2)...])
        return ["n": number, "step": String(step.prefix(300)), "result": String(result.prefix(300))]
    }

    private static func isEffectLine(_ line: String) -> Bool {
        ["effect:", "new:", "gone:", "windows:", "no visible change", "screen changed a lot", "window changed", "dialog"]
            .contains { line.hasPrefix($0) }
    }

    private static func limit(_ text: String) -> (String, Bool) {
        guard text.count > resultTextLimit else { return (text, false) }
        return (String(text.prefix(resultTextLimit)), true)
    }

    /// A benchmark's run id becomes part of a file name, so only letters, digits, dots, dashes and underscores survive.
    static func safeFileComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = String(trimmed.prefix(120).map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character)) ? character : "_"
        })
        if result.hasPrefix(".") {
            result = "_" + result.dropFirst()
        }
        return result
    }
}

/// A record built on the call path and encoded on the queue. Its contents are JSON-compatible values.
private struct PendingRecord: @unchecked Sendable {
    let timestamp: Date
    let object: [String: Any]
}
