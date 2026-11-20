import Foundation

/// When a helper's grant must be replaced: at 80% of its lifetime, leaving a 20% margin before the relay rejects it.
public enum RelayGrantRenewal {
    public static let renewalFraction = 0.8

    public static func renewalDate(for grant: RelayGrant) -> Date {
        let lifetime = Double(grant.expiresAt - grant.issuedAt)
        return Date(timeIntervalSince1970: Double(grant.issuedAt) + renewalFraction * lifetime)
    }

    public static func isDue(_ grant: RelayGrant, now: Date) -> Bool {
        now >= renewalDate(for: grant)
    }

    /// Host authorization denials become the operator's fix: install the relay key with the installer.
    /// Other errors pass through unchanged, so transport and timeout behaviour stays as it was.
    public static func typedError(for error: Error) -> Error {
        let text = ((error as? LocalizedError)?.errorDescription ?? String(describing: error)).lowercased()
        if text.contains("relay authentication") || text.contains("relay grant is invalid") {
            return RelayGrantError.helperNeedsRelayKey
        }
        return error
    }
}
