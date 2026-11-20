import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Grant creation: exact payload bytes, signature verification, lifetime and process identity.
final class RelayGrantTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let peer = RelayPeer(pid: 4242, uid: 501, startTime: "1700000000:123456")

    private func issuer() throws -> (RelayGrantIssuer, Curve25519.Signing.PublicKey) {
        let key = Curve25519.Signing.PrivateKey()
        let store = StaticKeyStore(key: key)
        return (try RelayGrantIssuer(store: store), key.publicKey)
    }

    private func split(_ token: String) throws -> (payload: Data, signature: Data) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2, "a grant is exactly two segments joined by a dot")
        return (try XCTUnwrap(Data(relayBase64URL: String(parts[0]))), try XCTUnwrap(Data(relayBase64URL: String(parts[1]))))
    }

    func testPayloadBytesAreSortedJSONWithExactValues() throws {
        let (issuer, _) = try issuer()
        let grant = try issuer.issue(peer: peer, sessionID: "godspeed-4242", now: fixedNow)
        let (payload, _) = try split(grant.token)
        let expected = """
        {"aud":"godspeed-chrome-relay-v1","exp":1800000900,"iat":1800000000,"methods":["getInfo","getTabs",\
        "createTab","navigateTab","getUserTabs","claimUserTab","executeCdp","waitForFileChooser",\
        "setFileChooserFiles","finalizeTabs","turnEnded"],"pid":4242,"sessionId":"godspeed-4242",\
        "startTime":"1700000000:123456","uid":501}
        """
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), expected)
    }

    func testSignatureVerifiesOverExactPayloadBytes() throws {
        let (issuer, publicKey) = try issuer()
        let grant = try issuer.issue(peer: peer, sessionID: "godspeed-4242", now: fixedNow)
        let (payload, signature) = try split(grant.token)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
        var tampered = payload
        tampered[tampered.startIndex] = UInt8(ascii: "[")
        XCTAssertFalse(publicKey.isValidSignature(signature, for: tampered))
    }

    func testTokenSegmentsAreUnpaddedBase64URL() throws {
        let (issuer, _) = try issuer()
        // Several sessions so at least one payload length is not a multiple of three.
        for session in ["a", "godspeed-1", "godspeed-client-review-lane2"] {
            let grant = try issuer.issue(peer: peer, sessionID: session, now: fixedNow)
            XCTAssertFalse(grant.token.contains("="))
            XCTAssertFalse(grant.token.contains("+"))
            XCTAssertFalse(grant.token.contains("/"))
            XCTAssertNoThrow(try split(grant.token))
        }
    }

    func testLifetimeIsAtMostFifteenMinutes() throws {
        let (issuer, _) = try issuer()
        let grant = try issuer.issue(peer: peer, sessionID: "s", now: fixedNow)
        XCTAssertEqual(grant.issuedAt, 1_800_000_000)
        XCTAssertLessThanOrEqual(grant.expiresAt - grant.issuedAt, 900)
        XCTAssertGreaterThan(grant.expiresAt, grant.issuedAt)
        XCTAssertThrowsError(try issuer.issue(peer: peer, sessionID: "s", now: fixedNow, lifetimeSeconds: 901)) { error in
            XCTAssertEqual(error as? RelayGrantError, .invalidLifetime(901))
        }
        XCTAssertThrowsError(try issuer.issue(peer: peer, sessionID: "s", now: fixedNow, lifetimeSeconds: 0))
    }

    func testEmptySessionIsRejected() throws {
        let (issuer, _) = try issuer()
        XCTAssertThrowsError(try issuer.issue(peer: peer, sessionID: "  ", now: fixedNow)) { error in
            XCTAssertEqual(error as? RelayGrantError, .emptySession)
        }
    }

    func testStartTimeMatchesCurrentTestProcess() throws {
        let me = try RelayPeer.process(pid: getpid())
        XCTAssertEqual(me.pid, getpid())
        XCTAssertEqual(me.uid, geteuid())
        let parts = me.startTime.split(separator: ":")
        XCTAssertEqual(parts.count, 2, "startTime is seconds:microseconds")
        let seconds = try XCTUnwrap(Int(parts[0]))
        let microseconds = try XCTUnwrap(Int(parts[1]))
        XCTAssertTrue((0..<1_000_000).contains(microseconds))
        // The process started before now and is not from the distant past.
        let now = Date().timeIntervalSince1970
        XCTAssertLessThanOrEqual(Double(seconds), now)
        XCTAssertGreaterThan(Double(seconds), now - 7 * 24 * 3600)
    }

    func testMissingProcessIsReported() {
        XCTAssertThrowsError(try RelayPeer.process(pid: 0x7FFF_FFF0)) { error in
            XCTAssertEqual(error as? RelayGrantError, .processUnavailable(0x7FFF_FFF0))
        }
    }

    func testGrantDescriptionNeverShowsToken() throws {
        let (issuer, _) = try issuer()
        let grant = try issuer.issue(peer: peer, sessionID: "s", now: fixedNow)
        XCTAssertFalse("\(grant)".contains(grant.token))
        XCTAssertFalse(String(reflecting: grant).contains(grant.token))
        XCTAssertFalse(String(describing: grant).contains(grant.token))
    }

    func testPublicKeyFromIssuerMatchesStoredKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuer = try RelayGrantIssuer(store: StaticKeyStore(key: key))
        XCTAssertEqual(issuer.publicKeyBase64URL(), RelayBase64URL.encode(key.publicKey.rawRepresentation))
    }
}

/// Injected key store for tests: never the Keychain.
struct StaticKeyStore: RelayAuthorityKeyStore {
    let key: Curve25519.Signing.PrivateKey
    func signingKey() throws -> Curve25519.Signing.PrivateKey { key }
}

extension Data {
    /// Decodes unpadded base64url (the inverse of `RelayBase64URL.encode`).
    init?(relayBase64URL text: String) {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        self.init(base64Encoded: standard)
    }
}
