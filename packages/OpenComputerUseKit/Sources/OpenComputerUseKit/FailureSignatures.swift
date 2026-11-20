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
