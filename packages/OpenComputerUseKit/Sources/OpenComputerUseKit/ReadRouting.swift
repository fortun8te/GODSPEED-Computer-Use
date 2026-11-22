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
        let key = windowID == nil ? learningKey(for: app) : nil
        let arm = key.map { queryArm(app: $0, risky: isRiskyLookup(text) || isRiskyLookup(role), learning: learning) }
            ?? "targeted_query"
        let clock = ProcessInfo.processInfo
        let started = clock.systemUptime
        func fullTree(_ window: CGWindowID?) throws -> [String: Any] {
            try service.fullTreeQuery(app: app, text: text, role: role, exact: exact,
                                      limit: limit, maxNodes: maxNodes, windowID: window)
        }
        func targeted(_ window: CGWindowID?) throws -> [String: Any] {
            try service.query(app: app, text: text, role: role, exact: exact,
                              limit: limit, maxNodes: maxNodes, windowID: window)
        }
        let useFullTree = arm == "full_tree_read"
        let matches = try (useFullTree ? fullTree(windowID) : targeted(windowID))
        let primaryEnded = clock.systemUptime
        let recovered = fallbackAfterEmptyQuery(matches, source: useFullTree ? "targeted_fallback" : "full_tree_fallback",
                                                alternate: useFullTree ? targeted : fullTree)
        if let key {
            let count = (matches["matches"] as? [Any])?.count ?? 0
            let recoveredCount = (recovered["matches"] as? [Any])?.count ?? 0
            let fallback = count == 0 && recoveredCount > 0
                ? (arm: useFullTree ? "targeted_query" : "full_tree_read",
                   latencyMs: (clock.systemUptime - primaryEnded) * 1_000)
                : nil
            recordQuery(app: key, arm: arm, matches: count, latencyMs: (primaryEnded - started) * 1_000,
                        fallback: fallback, learning: learning)
        }
        return recovered
    }

    static func fallbackAfterEmptyQuery(_ matches: [String: Any], source: String,
                                        alternate: (CGWindowID) throws -> [String: Any]) -> [String: Any] {
        guard let candidates = matches["matches"] as? [Any], candidates.isEmpty,
              let observed = matches["window_id"] as? Int, observed > 0,
              let window = CGWindowID(exactly: observed),
              (BrowserCallBudget.activeRemaining ?? .infinity) > 0.3,
              !RequestCancellation.requested,
              var recovered = try? alternate(window),
              recovered["window_id"] as? Int == observed,
              let recoveredCandidates = recovered["matches"] as? [Any],
              !recoveredCandidates.isEmpty || (
                  matches["truncated"] as? Bool == true && recovered["truncated"] as? Bool == false
              ) else { return matches }
        recovered["source"] = source
        return recovered
    }

    /// An empty result is only a miss when the other route found the control in the same window.
    static func recordQuery(app: String, arm: String, matches: Int, latencyMs: Double,
                            fallback: (arm: String, latencyMs: Double)? = nil, learning: AdaptiveLearning = .shared) {
        guard matches > 0 || fallback != nil else { return }
        learning.routes.record(app: app, action: queryAction, arm: arm, verified: matches > 0, latencyMs: latencyMs)
        if let fallback {
            learning.routes.record(app: app, action: queryAction, arm: fallback.arm,
                                   verified: true, latencyMs: fallback.latencyMs)
        }
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
    func fullTreeQuery(app query: String, text: String?, role: String?, exact: Bool, limit: Int, maxNodes: Int, windowID: CGWindowID?) throws -> [String: Any] {
        try requireUsableComputerUseSession()
        let app = try AppDiscovery.resolveRunning(query)
        let snapshot = try SnapshotBuilder.build(for: app,
            treeLimits: AccessibilityTreeLimits.defaults.replacing(maxNodeCount: min(5000, max(1, maxNodes))),
            recoveryPolicy: .readOnly, observation: .init(includeScreenshot: false), windowID: windowID)
        if let windowID, snapshot.observedWindowID != windowID { throw ComputerUseError.windowChanged(windowID) }
        rememberSnapshot(snapshot, for: query)
        let criteria = TargetedAX.Criteria(text: text, exact: exact, role: role,
                                          limit: min(100, max(1, limit)), maxNodes: min(5000, max(1, maxNodes)))
        let found = snapshot.elements.values.sorted { $0.index < $1.index }.filter {
            targetedRecordMatches(criteria, role: $0.role, title: $0.title,
                                  description: $0.identity?.name, value: $0.value ?? $0.identity?.value, identifier: $0.identifier)
        }
        let matches: [[String: Any]] = found.prefix(criteria.limit).map { record in
            var dict: [String: Any] = ["index": record.index]
            if let role = record.role, !role.isEmpty { dict["role"] = role }
            if let title = record.title ?? record.identity?.name, !title.isEmpty { dict["title"] = title }
            if let value = record.value, !value.isEmpty { dict["value"] = value }
            if let identifier = record.identifier, !identifier.isEmpty { dict["identifier"] = identifier }
            if let frame = record.localFrame {
                dict["bounds"] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height]
            }
            if !record.prettyActions.isEmpty { dict["actions"] = record.prettyActions }
            return dict
        }
        let treeTruncated = !DoneCheck.supportsAbsenceCheck(snapshot.treeLines.joined(separator: "\n"))
        let stopReason = treeTruncated ? "tree_limit" : (found.count > criteria.limit ? "limit" : "complete")
        return ["matches": matches, "truncated": stopReason != "complete",
                "stop_reason": stopReason, "window_id": snapshot.observedWindowID.map { Int($0) } ?? 0,
                "max_nodes": criteria.maxNodes, "limit": criteria.limit]
    }
}
