import CryptoKit
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Renewal timing, host error mapping, and the BrowserBridge wiring. The wiring tests start a fake `obu` script
/// that speaks newline-delimited JSON-RPC and records what it received. No real Chrome, OBU or Keychain is used.
final class BrowserBridgeRelayGrantTests: XCTestCase {
    private static let fixedStart = Date(timeIntervalSince1970: 1_800_000_000)
    private let start = fixedStart
    private var previousGrantSetting: String?

    // Grants are opt-in until the authenticated host is installed; these tests cover the enabled path.
    override func setUp() {
        super.setUp()
        previousGrantSetting = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RELAY_GRANT"]
        setenv("OPEN_COMPUTER_USE_RELAY_GRANT", "1", 1)
    }

    override func tearDown() {
        if let previousGrantSetting { setenv("OPEN_COMPUTER_USE_RELAY_GRANT", previousGrantSetting, 1) } else { unsetenv("OPEN_COMPUTER_USE_RELAY_GRANT") }
        super.tearDown()
    }

    /// With grants off (the default before the host is provisioned) the helper starts exactly as before:
    /// no `_meta`, and the key store is never touched.
    func testGrantsOffSendsThePlainInitializeAndNeverReadsTheKey() throws {
        setenv("OPEN_COMPUTER_USE_RELAY_GRANT", "0", 1)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bridge = BrowserBridge(
            sessionID: "godspeed-test", launchEnvironment: fixture.environment,
            relayKeyStore: FileRelayAuthorityKeyStore(url: fixture.keyURL), relayClock: { Self.fixedStart }
        )
        defer { bridge.shutdown() }
        _ = try bridge.callTool("tabs", arguments: [:], timeout: 10)
        let initializes = try lines(fixture.capture).filter { $0["method"] as? String == "initialize" }
        XCTAssertEqual(initializes.count, 1)
        XCTAssertNil((initializes.first?["params"] as? [String: Any])?["_meta"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.keyURL.path), "no key is created or read")
    }

    private func grant(issuedAt: Date) throws -> RelayGrant {
        let issuer = try RelayGrantIssuer(store: StaticKeyStore(key: .init()))
        return try issuer.issue(
            peer: RelayPeer(pid: 99, uid: 501, startTime: "1:2"), sessionID: "godspeed-99", now: issuedAt
        )
    }

    func testRenewalIsDueAtEightyPercentOfLifetime() throws {
        let issued = try grant(issuedAt: start)
        XCTAssertEqual(RelayGrantRenewal.renewalDate(for: issued).timeIntervalSince1970, 1_800_000_720)
        XCTAssertFalse(RelayGrantRenewal.isDue(issued, now: start.addingTimeInterval(719)))
        XCTAssertTrue(RelayGrantRenewal.isDue(issued, now: start.addingTimeInterval(720)))
        XCTAssertTrue(RelayGrantRenewal.isDue(issued, now: start.addingTimeInterval(900)))
    }

    func testRenewedGrantExtendsExpiry() throws {
        let first = try grant(issuedAt: start)
        let renewed = try grant(issuedAt: start.addingTimeInterval(720))
        XCTAssertGreaterThan(renewed.expiresAt, first.expiresAt)
        XCTAssertFalse(RelayGrantRenewal.isDue(renewed, now: start.addingTimeInterval(721)))
    }

    func testHostAuthorizationDenialsMapToKeyInstallError() {
        let denials = [
            "Open Browser Use: relay authentication required before browser requests",
            "Open Browser Use: relay grant is invalid, expired, or belongs to another process",
        ]
        for message in denials {
            let mapped = RelayGrantRenewal.typedError(for: ComputerUseError.message(message))
            XCTAssertEqual(mapped as? RelayGrantError, .helperNeedsRelayKey, message)
            XCTAssertEqual(
                (mapped as? LocalizedError)?.errorDescription,
                "Chrome helper needs the Godspeed relay key; run the installer."
            )
        }
    }

    func testOtherErrorsPassThroughUnchanged() {
        let timeout = ComputerUseError.timedOut("slow", delivery: .notSent)
        let mapped = RelayGrantRenewal.typedError(for: timeout)
        XCTAssertEqual((mapped as? ComputerUseError)?.errorDescription, "slow")
    }

    // MARK: Wiring through a fake helper

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func set(_ date: Date) { lock.withLock { value = date } }
    }

    private struct Fixture {
        let directory: URL
        let obu: URL
        let capture: URL
        let keyURL: URL
        var environment: [String: String]
    }

    /// Fake `obu mcp`: records its argv and environment once per start, logs every received line, and answers
    /// `initialize` and `tools/call`. With FAKE_OBU_DENY=1 it refuses `initialize` like a host denial.
    private static let fakeOBU = """
    #!/usr/bin/env python3
    import json, os, sys
    capture = os.environ["FAKE_OBU_CAPTURE"]
    with open(capture + ".argv", "w") as f:
        json.dump({"argv": sys.argv, "env": dict(os.environ), "pid": os.getpid()}, f)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        with open(capture, "a") as f:
            f.write(line + "\\n")
        if "id" not in message:
            continue
        if message.get("method") == "initialize" and os.environ.get("FAKE_OBU_DENY") == "1":
            reply = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32602,
                     "message": "relay grant is invalid, expired, or belongs to another process"}}
        elif message.get("method") == "initialize":
            reply = {"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": "2025-03-26",
                     "capabilities": {}, "serverInfo": {"name": "fake", "version": "0"}}}
        else:
            reply = {"jsonrpc": "2.0", "id": message["id"], "result": {"content": [{"type": "text", "text": "ok"}]}}
        sys.stdout.write(json.dumps(reply) + "\\n")
        sys.stdout.flush()
    """

    private func makeFixture(deny: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let obu = directory.appendingPathComponent("obu")
        try Self.fakeOBU.write(to: obu, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: obu.path)
        let capture = directory.appendingPathComponent("capture.log")
        var environment = [
            "OPEN_COMPUTER_USE_OBU_BIN": obu.path,
            "FAKE_OBU_CAPTURE": capture.path,
        ]
        if deny { environment["FAKE_OBU_DENY"] = "1" }
        return Fixture(
            directory: directory, obu: obu, capture: capture,
            keyURL: directory.appendingPathComponent("authority.key"), environment: environment
        )
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    private func initializeGrants(_ fixture: Fixture) throws -> [String] {
        try lines(fixture.capture).compactMap { message in
            guard message["method"] as? String == "initialize" else { return nil }
            let params = try XCTUnwrap(message["params"] as? [String: Any])
            let meta = try XCTUnwrap(params["_meta"] as? [String: Any])
            return try XCTUnwrap(meta["godspeedRelayGrant"] as? String)
        }
    }

    private func startedProcess(_ fixture: Fixture) throws -> (pid: Int, argv: String, env: String) {
        let json = try String(contentsOf: fixture.capture.appendingPathExtension("argv"), encoding: .utf8)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let pid = try XCTUnwrap(record["pid"] as? Int)
        let argv = try XCTUnwrap(record["argv"] as? [String]).joined(separator: " ")
        let env = try XCTUnwrap(record["env"] as? [String: String]).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return (pid, argv, env)
    }

    func testGrantTravelsOnlyInInitializeMetaAndVerifies() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = FileRelayAuthorityKeyStore(url: fixture.keyURL)
        let bridge = BrowserBridge(
            sessionID: "godspeed-test", launchEnvironment: fixture.environment,
            relayKeyStore: store, relayClock: { Self.fixedStart }
        )
        defer { bridge.shutdown() }
        _ = try bridge.callTool("tabs", arguments: [:], timeout: 10)

        let grants = try initializeGrants(fixture)
        XCTAssertEqual(grants.count, 1)
        let token = try XCTUnwrap(grants.first)
        let child = try startedProcess(fixture)
        XCTAssertFalse(child.argv.contains(token))
        XCTAssertFalse(child.env.contains(token))
        XCTAssertFalse(child.env.contains("godspeedRelayGrant"))

        // The grant verifies against the authority public key, for this child's identity and session.
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 2)
        let payload = try XCTUnwrap(Data(relayBase64URL: parts[0]))
        let signature = try XCTUnwrap(Data(relayBase64URL: parts[1]))
        XCTAssertTrue(try store.signingKey().publicKey.isValidSignature(signature, for: payload))
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(claims["pid"] as? Int, child.pid)
        XCTAssertEqual(claims["sessionId"] as? String, "godspeed-test")
        XCTAssertEqual(claims["aud"] as? String, "godspeed-chrome-relay-v1")
        XCTAssertEqual(claims["startTime"] as? String, try RelayPeer.process(pid: pid_t(child.pid)).startTime)
    }

    func testRenewalSendsFreshInitializeOnSamePipesBeforeExpiry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = Clock(start)
        let bridge = BrowserBridge(
            sessionID: "godspeed-test", launchEnvironment: fixture.environment,
            relayKeyStore: FileRelayAuthorityKeyStore(url: fixture.keyURL), relayClock: { clock.now }
        )
        defer { bridge.shutdown() }
        _ = try bridge.callTool("tabs", arguments: [:], timeout: 10)
        let firstChild = try startedProcess(fixture).pid

        clock.set(start.addingTimeInterval(719))
        _ = try bridge.callTool("tabs", arguments: [:], timeout: 10)
        XCTAssertEqual(try initializeGrants(fixture).count, 1, "no renewal before 80% of the lifetime")

        clock.set(start.addingTimeInterval(720))
        _ = try bridge.callTool("tabs", arguments: [:], timeout: 10)
        let grants = try initializeGrants(fixture)
        XCTAssertEqual(grants.count, 2)
        XCTAssertNotEqual(grants[0], grants[1])
        XCTAssertEqual(try startedProcess(fixture).pid, firstChild, "renewal reuses the same helper process")
    }

    func testHostDenialOfInitializeSurfacesKeyInstallError() throws {
        let fixture = try makeFixture(deny: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bridge = BrowserBridge(
            sessionID: "godspeed-test", launchEnvironment: fixture.environment,
            relayKeyStore: FileRelayAuthorityKeyStore(url: fixture.keyURL), relayClock: { Self.fixedStart }
        )
        defer { bridge.shutdown() }
        XCTAssertThrowsError(try bridge.callTool("tabs", arguments: [:], timeout: 10)) { error in
            XCTAssertEqual(error as? RelayGrantError, .helperNeedsRelayKey)
        }
    }

    func testMissingRelayKeySurfacesInstallErrorAndSendsNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bridge = BrowserBridge(
            sessionID: "godspeed-test", launchEnvironment: fixture.environment,
            relayKeyStore: FailingKeyStore(), relayClock: { Self.fixedStart }
        )
        defer { bridge.shutdown() }
        XCTAssertThrowsError(try bridge.callTool("tabs", arguments: [:], timeout: 10)) { error in
            XCTAssertEqual(error as? RelayGrantError, .helperNeedsRelayKey)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capture.path))
    }
}

private struct FailingKeyStore: RelayAuthorityKeyStore {
    func signingKey() throws -> Curve25519.Signing.PrivateKey {
        throw RelayAuthorityKeyStoreError.keychain(-25300)
    }
}
