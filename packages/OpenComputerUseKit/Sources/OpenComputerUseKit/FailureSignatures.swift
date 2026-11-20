import Foundation

public struct FailureSignature: Hashable, Codable, Sendable {
    public let appBundleID: String
    public let toolName: String
    public let failureCode: String
    public let targetRole: String
    public let targetLabel: String

    public init(appBundleID: String, toolName: String, failureCode: String, targetRole: String, targetLabel: String, isSecureField: Bool = false) {
        self.appBundleID = appBundleID
        self.toolName = toolName
        self.failureCode = failureCode
        self.targetRole = targetRole
        self.targetLabel = Self.normalize(targetLabel, isSecureField: isSecureField)
    }

    private static func normalize(_ label: String, isSecureField: Bool) -> String {
        guard !isSecureField else { return "" }
        let digits = label.lowercased().map { $0.isNumber ? "#" : String($0) }.joined()
        return digits.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40).description
    }
}

public final class FailureSignatureStore: @unchecked Sendable {
    /// Extra caller-supplied risk check (for example Godspeed's ActionPolicy), used in addition to the built-in word check.
    public typealias RiskPredicate = @Sendable (FailureSignature) -> Bool

    private struct Entry: Codable {
        var successes: Int
        var failures: Int
        var hints: [String: Int]
        var lastSeen: Date
    }
    private let lock = NSLock()
    private var entries: [FailureSignature: Entry] = [:]
    private let capacity = 1_000
    private static let maxHintsPerSignature = 8
    private let extraRisk: RiskPredicate

    public init(extraRisk: @escaping RiskPredicate = { _ in false }) {
        self.extraRisk = extraRisk
    }

    public func record(_ sig: FailureSignature, recovery: String?, succeeded: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        // Send, pay and delete-type steps are never learned from, not even as failures.
        guard !isRisky(sig) else { return }
        var entry = entries[sig] ?? Entry(successes: 0, failures: 0, hints: [:], lastSeen: now)
        entry.lastSeen = now
        if succeeded {
            entry.successes += 1
            if let recovery, !recovery.isEmpty {
                if entry.hints[recovery] == nil {
                    Self.evictWeakestHints(&entry.hints, keeping: Self.maxHintsPerSignature - 1)
                }
                entry.hints[recovery, default: 0] += 1
            }
        } else { entry.failures += 1 }
        entries[sig] = entry
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key { entries.removeValue(forKey: oldest) }
    }

    public func suggestion(for sig: FailureSignature) -> (hint: String, confidence: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard !isRisky(sig), let entry = entries[sig], entry.successes >= 2, entry.successes > entry.failures,
              let hint = entry.hints.max(by: { $0.value < $1.value })?.key else { return nil }
        return (hint, Double(entry.successes) / Double(entry.successes + entry.failures))
    }

    public func save(to url: URL) throws {
        lock.lock(); let snapshot = entries; lock.unlock()
        let rows = snapshot.map { Row(signature: $0.key, entry: $0.value) }
        try JSONEncoder().encode(rows).write(to: url, options: .atomic)
    }

    public func load(from url: URL) throws {
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        let loaded = Dictionary(rows.suffix(capacity).map { ($0.signature, $0.entry) }, uniquingKeysWith: { _, newer in newer })
            .mapValues { entry -> Entry in
                var trimmed = entry
                Self.evictWeakestHints(&trimmed.hints, keeping: Self.maxHintsPerSignature)
                return trimmed
            }
        lock.lock(); defer { lock.unlock() }
        entries = loaded
    }

    private struct Row: Codable { let signature: FailureSignature; let entry: Entry }

    /// Removes the least successful hints (ties broken by text) until at most `limit` remain.
    private static func evictWeakestHints(_ hints: inout [String: Int], keeping limit: Int) {
        while hints.count > limit, let weakest = hints.min(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key {
            hints.removeValue(forKey: weakest)
        }
    }

    private func isRisky(_ sig: FailureSignature) -> Bool {
        if Self.containsRiskyWord(toolName: sig.toolName, label: sig.targetLabel) { return true }
        return extraRisk(sig)
    }

    /// Risky tool names and labels are the destructive classes of RiskLexicon, the same list ActionPolicy uses.
    static func containsRiskyWord(toolName: String, label: String) -> Bool {
        !RiskLexicon.categories([toolName, label]).isDisjoint(with: RiskLexicon.destructiveCategories)
    }
}

/// Follows recovery hints for failed native steps. At most one hint is pending: the next step decides whether it worked.
/// A failed step that has a qualifying hint names it on one extra line. The next successful step credits that hint;
/// a failed next step cancels the credit.
final class FailureHintTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let store: FailureSignatureStore
    private let save: @Sendable () -> Void
    private var pending: (signature: FailureSignature, hint: String)?

    init(store: FailureSignatureStore, save: @escaping @Sendable () -> Void) {
        self.store = store
        self.save = save
    }

    /// Records a failed step and returns the error to reply with, with the hint line when one qualifies.
    func recordFailure(_ sig: FailureSignature, error: ComputerUseError) -> ComputerUseError {
        lock.lock()
        pending = nil
        store.record(sig, recovery: nil, succeeded: false)
        let hint = store.suggestion(for: sig)?.hint
        pending = hint.map { (signature: sig, hint: $0) }
        lock.unlock()
        save()
        guard let hint else { return error }
        return error.annotated(with: "Hint: \(hint).")
    }

    /// Records a successful step. If it followed a hinted failure, the hint worked.
    func recordSuccess() {
        lock.lock()
        let followed = pending
        pending = nil
        if let followed { store.record(followed.signature, recovery: followed.hint, succeeded: true) }
        lock.unlock()
        if followed != nil { save() }
    }
}

extension ComputerUseError {
    /// The same error with one more line. The case and its delivery state are kept, so what was sent is still reported.
    /// Cases that carry no text are returned unchanged.
    func annotated(with line: String) -> ComputerUseError {
        switch self {
        case .message(let text): return .message(text + "\n" + line)
        case .invalidArguments(let text): return .invalidArguments(text + "\n" + line)
        case .appNotFound(let text): return .appNotFound(text + "\n" + line)
        case .permissionDenied(let text): return .permissionDenied(text + "\n" + line)
        case .stateUnavailable(let text): return .stateUnavailable(text + "\n" + line)
        case .notSent(let text): return .notSent(text + "\n" + line)
        case .targetNotFound(let text): return .targetNotFound(text + "\n" + line)
        case .ambiguousTarget(let text): return .ambiguousTarget(text + "\n" + line)
        case .staleTarget(let text): return .staleTarget(text + "\n" + line)
        case .elementGone(let text): return .elementGone(text + "\n" + line)
        case .timedOut(let text, let delivery): return .timedOut(text + "\n" + line, delivery: delivery)
        case .acknowledged(let text): return .acknowledged(text + "\n" + line)
        case .backgroundUnsupported(let text): return .backgroundUnsupported(text + "\n" + line)
        case .approvalRequired(let text): return .approvalRequired(text + "\n" + line)
        case .actionDenied(let text): return .actionDenied(text + "\n" + line)
        case .unsupportedTool, .staleRef, .windowChanged: return self
        }
    }
}

extension FailureSignature {
    /// The signature of a failed call. The target is the label, or the menu path, that the call named. Element numbers
    /// carry no name here, so a call that names nothing gets an empty label.
    static func forStep(tool: String, arguments: [String: Any], error: ComputerUseError, appBundleID: String) -> FailureSignature {
        let label = (arguments["label"] as? String)
            ?? (arguments["path"] as? String)
            ?? (arguments["path"] as? [String])?.joined(separator: " > ")
            ?? ""
        return FailureSignature(
            appBundleID: appBundleID, toolName: tool, failureCode: String(describing: TrajectoryLog.failureCode(error: error)),
            targetRole: "", targetLabel: label
        )
    }
}
