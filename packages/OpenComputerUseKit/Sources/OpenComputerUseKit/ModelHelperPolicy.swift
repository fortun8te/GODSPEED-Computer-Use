import Foundation

/// One switch for optional model inference. Deterministic AX, OCR, recipes and
/// local verification remain available when helpers are disabled.
enum ModelHelperPolicy {
    static let environmentKey = "OPEN_COMPUTER_USE_MODEL_HELPERS"

    static var isEnabled: Bool { isEnabled(environment: GodspeedSettings.environment) }

    /// Preserve existing configurations unless the caller explicitly opts out.
    static func isEnabled(environment: [String: String]) -> Bool {
        let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["0", "false", "off", "no"].contains(value ?? "")
    }
}
