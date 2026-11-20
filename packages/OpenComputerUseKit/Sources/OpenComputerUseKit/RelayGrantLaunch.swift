import Darwin
import Foundation

/// Connects a started Chrome helper to its relay grant. The grant goes only into the private MCP `initialize`
/// request (`params._meta.godspeedRelayGrant`); callers keep it in memory.
enum RelayGrantLaunch {
    /// Signs a grant for the child process. A missing or unreadable relay key becomes the operator's fix.
    static func issue(keyStore: RelayAuthorityKeyStore, pid: pid_t, sessionID: String, now: Date) throws -> RelayGrant {
        do {
            let issuer = try RelayGrantIssuer(store: keyStore)
            return try issuer.issue(peer: RelayPeer.process(pid: pid), sessionID: sessionID, now: now)
        } catch is RelayAuthorityKeyStoreError {
            throw RelayGrantError.helperNeedsRelayKey
        }
    }

    /// MCP `initialize` parameters for a helper: the protocol and client identity, plus the grant in `_meta`.
    static func initializeParams(grant: RelayGrant) -> [String: Any] {
        [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "godspeed", "version": openComputerUseVersion],
            "_meta": ["godspeedRelayGrant": grant.token],
        ]
    }
}
