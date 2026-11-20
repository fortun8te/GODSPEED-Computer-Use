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
