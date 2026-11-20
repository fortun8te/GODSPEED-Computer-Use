import CoreGraphics
import Foundation

/// Learned routes for read-only calls (AdaptiveLearning). A query only reads and a settle wait only waits, so nothing
/// here acts on an app. Rewards come from verified outcomes only (a lookup that returned a match, a settle the app
/// confirmed), risky lookups never explore, and a pinned window keeps the direct route.
enum ReadRouting {
    static let queryAction = "query"
    static let settleArm = "settle"

    /// True when a lookup names something that acts on data (send, pay, delete). Such lookups never explore.
    static func isRiskyLookup(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return RiskLexicon.isDestructive(text)
    }

    /// The learning key for an app: its bundle id and version when it is running, else the name the caller used.
    static func learningKey(for app: String) -> String {
        (try? AppDiscovery.resolveRunning(app)).map(AdaptiveLearning.appKey(for:)) ?? app
    }

    /// Which way to answer a lookup: the targeted search (the default) or a read of the full tree.
    static func queryArm(app: String, risky: Bool, learning: AdaptiveLearning = .shared) -> String {
        var rng = SystemRandomNumberGenerator()
        return learning.routes.choose(app: app, action: queryAction, arms: AdaptiveLearning.queryArms,
                                      riskyAction: risky, rng: &rng)
    }

    /// Runs a query by the arm the bandit picks. A pinned window keeps the direct targeted route, unlearned.
    static func query(
        service: ComputerUseService, app: String, text: String?, role: String?, exact: Bool,
        limit: Int, maxNodes: Int, windowID: CGWindowID?, learning: AdaptiveLearning = .shared
    ) throws -> [String: Any] {
        guard windowID == nil else {
            return try service.query(app: app, text: text, role: role, exact: exact, limit: limit, maxNodes: maxNodes, windowID: windowID)
        }
        let key = learningKey(for: app)
        let arm = queryArm(app: key, risky: isRiskyLookup(text) || isRiskyLookup(role), learning: learning)
        let started = Date()
        let matches: [String: Any]
        if arm == "full_tree_read" {
            matches = try service.fullTreeQuery(app: app, text: text, role: role, exact: exact, limit: limit, maxNodes: maxNodes)
        } else {
            matches = try service.query(app: app, text: text, role: role, exact: exact, limit: limit, maxNodes: maxNodes, windowID: nil)
        }
        let count = (matches["matches"] as? [Any])?.count ?? 0
        recordQuery(app: key, arm: arm, matches: count, latencyMs: Date().timeIntervalSince(started) * 1000, learning: learning)
        return matches
    }

    /// One query outcome. A lookup that returned at least one match is verified; an empty one is not.
    static func recordQuery(app: String, arm: String, matches: Int, latencyMs: Double, learning: AdaptiveLearning = .shared) {
        learning.routes.record(app: app, action: queryAction, arm: arm, verified: matches > 0, latencyMs: latencyMs)
        learning.saveRoutes()
    }

    /// The settle wait for a read. Nil when the caller asked for no wait or the read is pinned to a window (no settle there).
    /// The wait is the caller's cap or the tuned wait, whichever is shorter. `tuned` is set only when the tuned wait was
    /// used, so only that wait is learned from.
    static func settlePlan(requested: Int?, app: String, windowID: CGWindowID?, learning: AdaptiveLearning = .shared)
        -> (wait: Int?, tuned: Int?) {
        guard let requested, windowID == nil else { return (nil, nil) }
        let tuned = learning.settle.value(app: learningKey(for: app))
        return requested >= tuned ? (tuned, tuned) : (requested, nil)
    }

    /// The app's own settle note: "Settled:" is verified, "Not settled:" is not, anything else is not learned from.
    static func settleVerified(_ result: ToolCallResult) -> Bool? {
        for item in result.content {
            guard let text = item.dictionary["text"] as? String else { continue }
            if text.hasPrefix("Settled:") { return true }
            if text.hasPrefix("Not settled:") { return false }
        }
        return nil
    }

    /// Records a settle outcome for the tuned wait, when one was used and the app reported a verdict.
    static func recordSettle(_ tuned: Int?, result: ToolCallResult, startedAt: Date, app: String, learning: AdaptiveLearning = .shared) {
        guard let tuned, let verified = settleVerified(result) else { return }
        learning.settle.record(app: learningKey(for: app), value: tuned, verified: verified,
                               latencyMs: Date().timeIntervalSince(startedAt) * 1000)
        learning.saveSettle()
    }
}

extension ComputerUseService {
    /// The full-tree lookup arm: the same filter as the targeted search, applied to the current read of the app's window.
    /// Read-only (no activation). Its numbers are the state's element numbers, usable by every element action.
    func fullTreeQuery(app query: String, text: String?, role: String?, exact: Bool, limit: Int, maxNodes: Int) throws -> [String: Any] {
        try requireUsableComputerUseSession()
        let snapshot = try currentSnapshot(for: query, needScreenshot: false, recoveryPolicy: .readOnly)
        let criteria = TargetedAX.Criteria(text: text, exact: exact, role: role,
                                          limit: min(100, max(1, limit)), maxNodes: min(5000, max(1, maxNodes)))
        let found = snapshot.elements.values.sorted { $0.index < $1.index }.filter {
            targetedRecordMatches(criteria, role: $0.role, title: $0.title, description: nil, value: $0.value)
        }
        let matches: [[String: Any]] = found.prefix(criteria.limit).map { record in
            var dict: [String: Any] = ["index": record.index]
            if let role = record.role, !role.isEmpty { dict["role"] = role }
            if let title = record.title, !title.isEmpty { dict["title"] = title }
            if let value = record.value, !value.isEmpty { dict["value"] = value }
            if let identifier = record.identifier, !identifier.isEmpty { dict["identifier"] = identifier }
            if let frame = record.localFrame {
                dict["bounds"] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height]
            }
            if !record.prettyActions.isEmpty { dict["actions"] = record.prettyActions }
            return dict
        }
        return ["matches": matches, "truncated": found.count > criteria.limit,
                "stop_reason": "complete", "window_id": snapshot.targetWindowID.map { Int($0) } ?? 0,
                "max_nodes": criteria.maxNodes, "limit": criteria.limit]
    }
}
