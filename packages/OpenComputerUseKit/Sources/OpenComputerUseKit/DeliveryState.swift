/// Delivery evidence for one action. Raw values are shared by MCP receipts and operation journals.
public enum DeliveryState: String, Codable, Sendable {
    /// The driver refused or stopped the action before sending its input.
    case notSent = "not_sent"
    /// Input may have reached the target. Inspect the target before considering a retry.
    case outcomeUnknown = "outcome_unknown"
    /// The action returned successfully or delivery was acknowledged. Its effect may still need checking.
    case acknowledged = "acknowledged"
    /// The requested result was confirmed by an independent readback or a change-aware check.
    case verified = "verified"

    public enum SafeRetry: String, Codable, Sendable {
        case afterCorrection = "after_correction"
        case reconcileFirst = "reconcile_first"
        case doNotRetry = "do_not_retry"
    }

    /// This is caller guidance. Even an unsent action needs its preconditions corrected before retry.
    public var safeRetry: SafeRetry {
        switch self {
        case .notSent: return .afterCorrection
        case .outcomeUnknown: return .reconcileFirst
        case .acknowledged, .verified: return .doNotRetry
        }
    }

    /// Compact guidance for an action whose reply could not establish delivery.
    public static let reconcileHint = "Inspect the current state before retrying."

    public var metadata: [String: String] {
        var fields = ["delivery_state": rawValue, "safe_retry": safeRetry.rawValue]
        if self == .outcomeUnknown { fields["reconcile"] = Self.reconcileHint }
        return fields
    }
}
