import CryptoKit
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Key storage and public-key encoding. Never touches the real Keychain: tests use the file store.
final class RelayGrantKeyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-key-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFileStoreCreatesKeyOnceAndReturnsSameKey() throws {
        let store = FileRelayAuthorityKeyStore(url: directory.appendingPathComponent("authority.key"))
        let first = try store.signingKey()
        let second = try store.signingKey()
        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
        XCTAssertEqual(first.rawRepresentation.count, 32)
    }

    func testFileStoreWritesOwnerOnlyPermissions() throws {
        let url = directory.appendingPathComponent("authority.key")
        _ = try FileRelayAuthorityKeyStore(url: url).signingKey()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFileStoreRejectsMalformedKey() throws {
        let url = directory.appendingPathComponent("bad.key")
        try "not-a-key".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FileRelayAuthorityKeyStore(url: url).signingKey()) { error in
            XCTAssertEqual(error as? RelayAuthorityKeyStoreError, .malformedKey)
        }
    }

    func testPublicKeyIsUnpaddedBase64URLOfRawThirtyTwoBytes() throws {
        let store = FileRelayAuthorityKeyStore(url: directory.appendingPathComponent("authority.key"))
        let encoded = try RelayAuthorityPublicKey.base64URL(store: store)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(encoded.count, 43)
        let raw = try XCTUnwrap(Data(base64URL: encoded))
        XCTAssertEqual(raw.count, 32)
        XCTAssertEqual(raw, try store.signingKey().publicKey.rawRepresentation)
    }

    func testBase64URLUsesURLAlphabetWithoutPadding() {
        // 0xFB 0xFF encodes to "+/8=" in standard base64 and "-_8" when unpadded base64url.
        XCTAssertEqual(RelayBase64URL.encode(Data([0xFB, 0xFF])), "-_8")
        XCTAssertEqual(RelayBase64URL.encode(Data([0x01])), "AQ")
        XCTAssertEqual(RelayBase64URL.encode(Data()), "")
    }
}

private extension Data {
    /// Decodes unpadded base64url, the inverse of `RelayBase64URL.encode`.
    init?(base64URL text: String) {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        self.init(base64Encoded: standard)
    }
}
