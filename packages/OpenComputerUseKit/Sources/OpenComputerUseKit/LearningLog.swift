import Darwin
import Foundation

/// Local training-data log. Rows are appended as JSONL, one file per UTC day, and scrubbed before they
/// reach disk. Nothing is sent anywhere. Clipboard content is never read, so it is never stored.
/// OPEN_COMPUTER_USE_LEARNING_LOG=0 turns the log off. OPEN_COMPUTER_USE_LEARNING_LOG_IMAGES=0 skips PNG saves.
final class LearningLog: @unchecked Sendable {
    @TaskLocal static var episodeID: String?
    @TaskLocal static var decisionID: String?
    @TaskLocal static var suppliedValues: [String] = []

    static let enabledVariable = "OPEN_COMPUTER_USE_LEARNING_LOG"
    static let imagesVariable = "OPEN_COMPUTER_USE_LEARNING_LOG_IMAGES"
    static let runIDVariable = "OPEN_COMPUTER_USE_RUN_ID"
    static let disabledValues = ["0", "false", "no", "off"]
    /// Whole-folder cap. When the folder passes it, the oldest files are deleted first.
    static let defaultMaxBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".godspeed/learning", isDirectory: true)
    }

    /// The log the driver's hooks write to. Tests inject their own instance instead, and under XCTest this one
    /// is always off, so no test can write into the real ~/.godspeed folder.
    static let shared = LearningLog(enabled: isEnabled(environment: ProcessInfo.processInfo.environment) && NSClassFromString("XCTestCase") == nil)

    static func isEnabled(environment: [String: String]) -> Bool {
        !disabledValues.contains(flag(environment[enabledVariable]))
    }

    static func imagesEnabled(environment: [String: String]) -> Bool {
        !disabledValues.contains(flag(environment[imagesVariable]))
    }

    private static func flag(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    let directory: URL
    let maxBytes: UInt64
    let isEnabled: Bool
    let imagesEnabled: Bool
    let runID: String
    private let clock: () -> Date
    private let lock = NSLock()

    init(
        directory: URL = LearningLog.defaultDirectory,
        maxBytes: UInt64 = LearningLog.defaultMaxBytes,
        enabled: Bool = LearningLog.isEnabled(environment: ProcessInfo.processInfo.environment),
        imagesEnabled: Bool = LearningLog.imagesEnabled(environment: ProcessInfo.processInfo.environment),
        runID: String? = ProcessInfo.processInfo.environment[LearningLog.runIDVariable],
        clock: @escaping () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        isEnabled = enabled
        self.imagesEnabled = imagesEnabled
        self.runID = runID ?? UUID().uuidString.lowercased()
        self.clock = clock
    }

    /// Scrubs one row and appends it as a JSON line. Returns false when the log is off or the write fails.
    @discardableResult
    func append<Row: Encodable>(_ row: Row) -> Bool {
        guard isEnabled, let data = try? JSONEncoder().encode(row),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        // Timestamps and ids are added after scrubbing so they are never redacted.
        var scrubbed = LearningScrubber.scrub(object)
        if scrubbed["ts"] == nil { scrubbed["ts"] = Self.timestamp(now) }
        if scrubbed["run_id"] == nil { scrubbed["run_id"] = runID }
        if let episodeID = Self.episodeID { scrubbed["episode_id"] = episodeID }
        if let decisionID = Self.decisionID { scrubbed["decision_id"] = decisionID }
        guard let line = try? JSONSerialization.data(
            withJSONObject: scrubbed, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return false }
        let url = directory.appendingPathComponent("learning-\(Self.format(now, "yyyy-MM-dd")).jsonl")
        // Row write and cap eviction share one cross-process lock, so no other process can interleave with either.
        return locked { () -> Bool in
            guard write(line + Data("\n".utf8), to: url) else { return false }
            enforceCap(keeping: url.lastPathComponent)
            return true
        }
    }

    /// Saves a PNG beside the JSONL. Returns the file name for a locate row, or nil when images are off.
    func saveImage(_ png: Data) -> String? {
        guard isEnabled, imagesEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let name = "learning-\(Self.format(now, "yyyy-MM-dd-HHmmss-SSS"))-\(UUID().uuidString.lowercased().prefix(8)).png"
        return locked { () -> String? in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(name)
                try png.write(to: url, options: .atomic)
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            } catch {
                return nil
            }
            enforceCap(keeping: name)
            return name
        }
    }

    /// Runs `body` while holding an exclusive flock on the folder's lock file. Separate processes (the app agent
    /// and a stdio MCP process) then never interleave a row write with a cap eviction. If the lock file cannot be
    /// opened, `body` still runs: O_APPEND keeps each row whole, and a log must never block an action.
    private func locked<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent(".learning.lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    /// Appends the whole line with one O_APPEND write loop, so the bytes land at the current end of the file.
    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Deletes the oldest learning files until the folder fits the cap. The file just written is kept.
    /// Callers hold the cross-process lock, so no other writer can add a file while this sums sizes.
    private func enforceCap(keeping name: String) {
        let files = learningFiles()
        var total = files.reduce(UInt64(0)) { $0 + $1.size }
        for file in files where total > maxBytes && file.name != name {
            do {
                try FileManager.default.removeItem(at: file.url)
                total -= file.size
            } catch {
                continue
            }
        }
    }

    /// Learning files, oldest first. Names start with the UTC date, so sorting by name sorts by time.
    private func learningFiles() -> [(name: String, url: URL, size: UInt64)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("learning-") }
            .map { url -> (name: String, url: URL, size: UInt64) in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (name: url.lastPathComponent, url: url, size: UInt64(max(size, 0)))
            }
            .sorted { $0.name < $1.name }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct LearningOption: Codable {
    var id: String
    var text: String
}

/// Text inputs for replaying a chooser request from a scrubbed local capture.
struct LearningChooserContext: Codable {
    let goal: String
    let done_when: String
    let history: String
    let image_supplied: Bool
}

/// A decide or choose call. The outcome is what the model returned, not a label.
struct LearningDecisionRow: Codable {
    var kind = "decide"
    var ts: String?
    var run_id: String?
    var app: String?
    var view: String?
    var options: [LearningOption]?
    var probabilities: [String: Double]?
    var outcome: String?
    var latency_ms: Double?
    var model: String?
    /// The model's own answer for decide (act, look_again, done, stuck) and its confidence.
    var label: String?
    var confidence: Double?
    var chooser_context: LearningChooserContext?
}

/// The disposition of one chooser invocation, kept separate from the model's scores.
struct LearningChoiceOutcomeRow: Codable {
    var kind = "choice_outcome"
    let disposition: String
    var selected_option_id: String?
    var delivery_state: String?
    var readback: String?
}

/// A grounding call: where the model pointed in a crop.
struct LearningLocateRow: Codable {
    var kind = "locate"
    var ts: String?
    var run_id: String?
    var app: String?
    var query: String?
    var crop_width: Double?
    var crop_height: Double?
    var point: [Double]?
    var box: [Double]?
    var confidence: Double?
    var verified: Bool?
    var image: String?
    /// "ocr" when text recognition found the point, "model" when the grounding model did.
    var evidence: String?
}

/// One action step and what was observed after it.
struct LearningStepRow: Codable {
    var kind = "step"
    var ts: String?
    var run_id: String?
    var app: String?
    var tool: String?
    var target_role: String?
    var target_label: String?
    var delivery_state: String?
    var failure_code: String?
    var verification: String?
    var done_when: String?
    var before: String?
    var after: String?
    /// Step number within the batch.
    var n: Int?
    /// The window the batch started in, the same identity recipes use (see LearningWindow).
    var window: LearningWindow?
}

/// The end of a goal, with its final outcome.
struct LearningEpisodeRow: Codable {
    var kind = "episode"
    var ts: String?
    var run_id: String?
    var app: String?
    var goal: String?
    var outcome: String?
    /// The batch's done_when in its JSON form (see LearningDoneWhen). Absent when the batch had none.
    var done_when: [[String: String]]?
    /// The done_when result: verified, weak or unmet. Absent when no check ran.
    var done: String?
    var window: LearningWindow?
}

/// Window identity for a recipe: the app's bundle id and the window title line. The pid and window number are left out,
/// so the same window keeps its identity across runs. Element numbers are never part of it.
struct LearningWindow: Codable, Equatable {
    var app: String
    var title: String

    init(_ window: BatchRecipes.Window) {
        // The process header reads "App=<bundle id> (pid N)". Only the bundle id is kept.
        var bundle = window.process
        if bundle.hasPrefix("App=") { bundle.removeFirst(4) }
        if let range = bundle.range(of: " (pid ") { bundle = String(bundle[..<range.lowerBound]) }
        app = bundle
        title = window.titleLine
    }

    init?(state: String?) {
        guard let window = BatchRecipes.Window(state: state) else { return nil }
        self.init(window)
    }
}

/// done_when conditions in the same JSON form the tool accepts. A field value is redacted when its label names a
/// secure or code field, so the condition keeps its label but never its value.
enum LearningDoneWhen {
    static func rows(_ conditions: [DoneCheck.Condition]) -> [[String: String]]? {
        guard !conditions.isEmpty else { return nil }
        return conditions.map { condition in
            var arguments = condition.arguments
            if let label = arguments["field"], arguments["equals"] != nil, isSensitive(label) {
                arguments["equals"] = LearningScrubber.redacted
            }
            return arguments
        }
    }

    private static func isSensitive(_ label: String) -> Bool {
        let lower = label.lowercased()
        return LearningScrubber.marksSecureField([label]) || LearningScrubber.codeMarkers.contains { lower.contains($0) }
    }
}

/// Removes secrets and private values from a JSON row. Works on the encoded object, so every row type is covered.
enum LearningScrubber {
    static let redacted = "[redacted]"
    static let textLimit = 6_000
    static let secureMarkers = ["password", "passcode", "wachtwoord", "secure"]
    static let codeMarkers = ["code", "otp", "2fa", "verification"]
    static let labelKeys: Set<String> = ["role", "subrole", "label", "target_role", "target_label"]
    /// Keys we write ourselves or that hold file names and ids. They are never scrubbed.
    static let exemptKeys: Set<String> = ["ts", "run_id", "app", "image", "kind"]
    static let keyPattern = regex(#"\b(?:sk-|ghp_|xox|AKIA)[A-Za-z0-9_\-]{8,}"#)
    static let tokenPattern = regex(#"[A-Za-z0-9_\-]{24,}"#)
    static let cardPattern = regex(#"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#)

    /// Scrubs every string in an encoded row. Secure fields lose their label and values.
    /// Code and verification fields keep their label but lose their values.
    static func scrub(_ object: [String: Any]) -> [String: Any] {
        let secure = object.contains { key, value in
            labelKeys.contains(key) && isMarked(value as? String, secureMarkers)
        }
        let codeLabel = object.contains { key, value in
            labelKeys.contains(key) && isMarked(value as? String, codeMarkers)
        }
        var output: [String: Any] = [:]
        for (key, value) in object {
            if exemptKeys.contains(key) {
                output[key] = value
            } else if secure && ["label", "target_label", "value", "before", "after"].contains(key) {
                continue
            } else if codeLabel && ["value", "before", "after"].contains(key) && value is String {
                output[key] = redacted
            } else if ["view", "before", "after"].contains(key), let state = value as? String {
                output[key] = scrubText(TrajectoryLog.redactSecureLines(state))
            } else {
                output[key] = scrubValue(value)
            }
        }
        return output
    }

    private static func scrubValue(_ value: Any) -> Any {
        if let text = value as? String { return scrubText(text) }
        if let object = value as? [String: Any] { return scrub(object) }
        if let list = value as? [Any] { return list.map(scrubValue) }
        return value
    }

    static func scrubText(_ text: String) -> String {
        let scrubbed = LearningLog.suppliedValues.sorted { $0.utf16.count > $1.utf16.count }
            .reduce(text) { result, supplied in
                result.replacingOccurrences(of: supplied, with: redacted)
            }
        return clean(scrubbed)
    }

    /// Redacts API keys, card numbers that pass Luhn and long mixed tokens, then clips to the limit.
    static func clean(_ input: String) -> String {
        var text = replacing(input, keyPattern) { _ in true }
        text = replacing(text, cardPattern) { found in
            let digits = found.filter { $0.isASCII && $0.isNumber }
            return (13...19).contains(digits.count) && isLuhn(digits)
        }
        text = replacing(text, tokenPattern) { found in
            found.contains { $0.isLetter } && found.contains { $0.isNumber }
        }
        return String(text.prefix(textLimit))
    }

    /// Words that name a password or secure field in English and Dutch. Matching is loose on purpose: a false
    /// match only costs one crop image.
    static let secureImageMarkers = secureMarkers

    /// True when any of these texts (window text, a label, a subrole) names a secure field. Such views keep their
    /// rows but never their crop images.
    static func marksSecureField(_ texts: [String]) -> Bool {
        texts.contains { text in
            let lower = text.lowercased()
            return secureImageMarkers.contains { lower.contains($0) }
        }
    }

    static func isLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard let number = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                let doubled = number * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += number
            }
        }
        return sum % 10 == 0
    }

    private static func isMarked(_ value: String?, _ markers: [String]) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return markers.contains { value.contains($0) }
    }

    private static func replacing(_ text: String, _ pattern: NSRegularExpression, when shouldRedact: (String) -> Bool) -> String {
        let source = text as NSString
        var result = text
        // Walk matches from the end so earlier ranges stay valid.
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed()
        where shouldRedact(source.substring(with: match.range)) {
            result = (result as NSString).replacingCharacters(in: match.range, with: redacted)
        }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, so a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }
}
