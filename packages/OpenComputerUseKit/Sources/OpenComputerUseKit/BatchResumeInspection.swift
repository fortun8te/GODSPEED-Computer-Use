import Foundation

extension BatchResume {
    /// A bounded local progress capsule for hosts that discarded their earlier
    /// conversation. It deliberately contains no saved action arguments,
    /// typed payloads, completion values, screenshots or inferred live state.
    static func inspection(of record: Record) throws -> ToolCallResult {
        func short(_ text: String, limit: Int) -> String {
            let flattened = text.components(separatedBy: .controlCharacters).joined(separator: " ")
            return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
        }
        let uncertain = record.sent.filter { $0.state == .outcomeUnknown }.map(\.number)
        let structuralSteps = try? pendingStructure(of: record)
        let canBind = structuralSteps.map {
            (try? BatchTool.binding($0, to: record.targetWindowID, app: record.app)) != nil
        } ?? false
        let replayEligible = canBind && uncertain.isEmpty && !record.pending.isEmpty
            && record.app?.isEmpty == false && record.app != "browser" && record.processID != nil
            && record.targetWindowID != nil && record.processLaunchDate != nil
            && record.requiresFreshSteps != true && record.doneWhen == nil
            && !record.pending.contains { $0.tool == "browser" }
            && !record.sent.contains { $0.tool == "browser" }
        let nextAction: String
        let guidance: String
        if !uncertain.isEmpty {
            nextAction = "inspect_uncertain_delivery"
            guidance = "Read the app to establish what happened before sending explicit remaining steps. Do not replay uncertain actions."
        } else if record.pending.isEmpty {
            nextAction = "verify_current_state"
            guidance = "No saved step remains. Read the app and check the requested outcome; dispatched does not mean completed."
        } else if replayEligible {
            nextAction = "resume_with_fresh_values"
            guidance = "Send batch with resume and the required values. Resume rechecks the original process lifetime and window before any action."
        } else {
            nextAction = "read_target_and_send_fresh_steps"
            guidance = "Read the target and send only the remaining work explicitly; this saved plan is not eligible for automatic native continuation."
        }
        var target: [String: Any] = [:]
        target["app"] = record.app.map { short($0, limit: 80) }
        target["window_id"] = record.targetWindowID
        target["process_id"] = record.processID
        var summary: [String: Any] = [
            "checkpoint": record.id,
            "source": "saved_checkpoint_not_live_state",
            "actions_sent": 0,
            "token_consumed": false,
            "expires_at": ISO8601DateFormatter().string(from: record.expiresAt),
            "target": target,
            "progress": [
                "total_steps": record.total,
                "dispatched_steps": record.sent.map(\.number),
                "verified_delivery_steps": record.sent.filter { $0.state == .verified }.map(\.number),
                "uncertain_steps": uncertain,
                "pending_steps": record.pending.map(\.number),
            ],
            "pending_tools": record.pending.prefix(BatchTool.maxSteps).map {
                ["step": $0.number, "tool": short($0.tool, limit: 40)] as [String: Any]
            },
            "required_values": record.slotNames,
            "next_action": nextAction,
            "guidance": guidance,
        ]
        // A legacy goal can repeat values that older writers kept in the
        // checkpoint. Continuing an old record must not bless that text.
        if record.privacyVersion == 1, structuralSteps != nil, record.doneWhen == nil, !record.goal.isEmpty {
            summary["goal"] = short(record.goal, limit: 240)
        }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        return .text(String(decoding: data, as: UTF8.self), deliveryState: .notSent)
    }
}
