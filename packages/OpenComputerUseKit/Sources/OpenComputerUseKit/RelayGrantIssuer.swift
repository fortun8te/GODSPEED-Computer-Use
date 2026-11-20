import CryptoKit
import Darwin
import Foundation
import Security

/// Holds the Ed25519 signing key that authorizes Chrome relay clients. The key never leaves the trusted issuer:
/// helpers receive only their own signed grant.
public protocol RelayAuthorityKeyStore: Sendable {
    /// Returns the signing key, creating and storing it the first time.
    func signingKey() throws -> Curve25519.Signing.PrivateKey
}

public enum RelayAuthorityKeyStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    case malformedKey
    case fileUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The Godspeed relay key could not be read or created in the Keychain (status \(status))."
        case .malformedKey:
            return "The stored Godspeed relay key is malformed."
        case .fileUnavailable(let path):
            return "The Godspeed relay key file could not be read or created at \(path)."
        }
    }
}

/// Generic-password item in the login Keychain, this device only, never synced through iCloud.
public struct KeychainRelayAuthorityKeyStore: RelayAuthorityKeyStore {
    public static let service = "com.godspeed.relay-authority"
    public static let account = "ed25519-signing-key"

    public init() {}

    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try readRawKey() {
            return try Self.key(from: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Another process created the key first; use that one.
            guard let data = try readRawKey() else { throw RelayAuthorityKeyStoreError.keychain(status) }
            return try Self.key(from: data)
        }
        guard status == errSecSuccess else { throw RelayAuthorityKeyStoreError.keychain(status) }
        return key
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func readRawKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RelayAuthorityKeyStoreError.keychain(status)
        }
        return data
    }

    fileprivate static func key(from data: Data) throws -> Curve25519.Signing.PrivateKey {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw RelayAuthorityKeyStoreError.malformedKey
        }
        return key
    }
}

/// File-backed store for tests and fixtures. The file holds the raw 32-byte seed as base64 and is created with 0600.
public struct FileRelayAuthorityKeyStore: RelayAuthorityKeyStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
                throw RelayAuthorityKeyStoreError.malformedKey
            }
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        let text = key.rawRepresentation.base64EncodedString() + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw RelayAuthorityKeyStoreError.fileUnavailable(url.path) }
            defer { close(fd) }
            let bytes = Array(text.utf8)
            guard write(fd, bytes, bytes.count) == bytes.count else {
                throw RelayAuthorityKeyStoreError.fileUnavailable(url.path)
            }
        } catch let error as RelayAuthorityKeyStoreError {
            throw error
        } catch {
            throw RelayAuthorityKeyStoreError.fileUnavailable(url.path)
        }
        return key
    }
}

/// Unpadded base64url, as the Go verifier decodes it (`base64.RawURLEncoding`).
public enum RelayBase64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Public half of the relay authority, for the installer to provision `OBU_RELAY_AUTHORITY_KEY`.
public enum RelayAuthorityPublicKey {
    public static func base64URL(store: RelayAuthorityKeyStore = KeychainRelayAuthorityKeyStore()) throws -> String {
        RelayBase64URL.encode(try store.signingKey().publicKey.rawRepresentation)
    }
}

/// Process identity the relay checks on the socket peer: PID, effective UID and kernel start time.
public struct RelayPeer: Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    /// `seconds:microseconds` from `kern.proc.pid` `p_starttime`, the same text the host derives on macOS.
    public let startTime: String

    public init(pid: Int32, uid: UInt32, startTime: String) {
        self.pid = pid
        self.uid = uid
        self.startTime = startTime
    }

    /// Reads a live process through `sysctl(KERN_PROC_PID)`. Throws when the process is gone.
    public static func process(pid: pid_t) throws -> RelayPeer {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            throw RelayGrantError.processUnavailable(pid)
        }
        let start = info.kp_proc.p_starttime
        return RelayPeer(
            pid: pid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            startTime: "\(start.tv_sec):\(start.tv_usec)"
        )
    }
}

public enum RelayGrantError: Error, LocalizedError, Equatable {
    case processUnavailable(pid_t)
    case invalidLifetime(Int64)
    case emptySession
    /// The host rejected the helper's grant: the relay authority key is missing or does not match.
    case helperNeedsRelayKey

    public var errorDescription: String? {
        switch self {
        case .helperNeedsRelayKey:
            return "Chrome helper needs the Godspeed relay key; run the installer."
        case .processUnavailable(let pid):
            return "Chrome helper process \(pid) is not running, so no relay grant can be issued."
        case .invalidLifetime(let seconds):
            return "A relay grant lasts at most \(RelayGrantIssuer.maximumLifetimeSeconds) seconds; \(seconds) was requested."
        case .emptySession:
            return "A relay grant needs the helper's session id."
        }
    }
}

/// A signed grant as the helper sends it: `base64url(payload).base64url(signature)`.
public struct RelayGrant: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String
    public let issuedAt: Int64
    public let expiresAt: Int64

    /// Never print the token: it is a bearer credential for the relay.
    public var description: String {
        "RelayGrant(iat: \(issuedAt), exp: \(expiresAt), token: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// The JSON the Go verifier reads (`internal/host/auth.go`). Keys are written sorted; the Go side decodes by name.
struct RelayGrantPayload: Encodable, Equatable {
    let aud: String
    let pid: Int32
    let uid: UInt32
    let startTime: String
    let sessionId: String
    let methods: [String]
    let iat: Int64
    let exp: Int64
}

/// Signs grants for helpers. The signing key stays in this process; helpers only receive their own grant.
public struct RelayGrantIssuer {
    public static let audience = "godspeed-chrome-relay-v1"
    public static let maximumLifetimeSeconds: Int64 = 900
    /// Browser RPC methods the bridge reaches through OBU: tabs, open/navigate, user tabs and claim, CDP,
    /// file chooser, tab cleanup, turn end and `getInfo` for profile selection. Clipboard and user history are
    /// not used by the bridge (clipboard is private and local), so they are not granted.
    public static let bridgeMethods = [
        "getInfo", "getTabs", "createTab", "navigateTab", "getUserTabs", "claimUserTab", "executeCdp",
        "waitForFileChooser", "setFileChooserFiles", "finalizeTabs", "turnEnded", "clickTarget",
    ]

    private let key: Curve25519.Signing.PrivateKey

    public init(store: RelayAuthorityKeyStore) throws {
        key = try store.signingKey()
    }

    public func publicKeyBase64URL() -> String {
        RelayBase64URL.encode(key.publicKey.rawRepresentation)
    }

    public func issue(
        peer: RelayPeer,
        sessionID: String,
        methods: [String] = RelayGrantIssuer.bridgeMethods,
        now: Date = Date(),
        lifetimeSeconds: Int64 = RelayGrantIssuer.maximumLifetimeSeconds
    ) throws -> RelayGrant {
        guard lifetimeSeconds > 0, lifetimeSeconds <= Self.maximumLifetimeSeconds else {
            throw RelayGrantError.invalidLifetime(lifetimeSeconds)
        }
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayGrantError.emptySession
        }
        let issuedAt = Int64(now.timeIntervalSince1970.rounded(.down))
        let payload = RelayGrantPayload(
            aud: Self.audience, pid: peer.pid, uid: peer.uid, startTime: peer.startTime,
            sessionId: sessionID, methods: methods, iat: issuedAt, exp: issuedAt + lifetimeSeconds
        )
        let encoder = JSONEncoder()
        // Sorted keys make the signed bytes deterministic across OS releases (Swift does not promise key order).
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(payload)
        let signature = try key.signature(for: bytes)
        return RelayGrant(
            token: RelayBase64URL.encode(bytes) + "." + RelayBase64URL.encode(signature),
            issuedAt: issuedAt,
            expiresAt: issuedAt + lifetimeSeconds
        )
    }
}
