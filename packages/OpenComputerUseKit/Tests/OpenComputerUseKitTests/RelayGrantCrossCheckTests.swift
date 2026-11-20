import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Cross-check: a grant made here must pass the Go verifier in the browser repo. A small Go test is added with
/// `go test -overlay`, so the browser repo is never modified. Skips cleanly when go or the repo is missing, and
/// stays offline (GOPROXY=off).
final class RelayGrantCrossCheckTests: XCTestCase {
    private static let goTest = """
    package host

    import (
    	"crypto/ed25519"
    	"encoding/base64"
    	"encoding/json"
    	"os"
    	"testing"
    	"time"
    )

    func TestGodspeedSwiftRelayGrant(t *testing.T) {
    	path := os.Getenv("RELAY_FIXTURE")
    	if path == "" {
    		t.Skip("RELAY_FIXTURE not set")
    	}
    	raw, err := os.ReadFile(path)
    	if err != nil {
    		t.Fatal(err)
    	}
    	var fixture struct {
    		Token     string `json:"token"`
    		PublicKey string `json:"publicKey"`
    		PID       int    `json:"pid"`
    		UID       uint32 `json:"uid"`
    		StartTime string `json:"startTime"`
    		Now       int64  `json:"now"`
    	}
    	if err := json.Unmarshal(raw, &fixture); err != nil {
    		t.Fatal(err)
    	}
    	key, err := base64.RawURLEncoding.DecodeString(fixture.PublicKey)
    	if err != nil {
    		t.Fatal(err)
    	}
    	peer := peerIdentity{PID: fixture.PID, UID: fixture.UID, StartTime: fixture.StartTime}
    	now := time.Unix(fixture.Now, 0)
    	if _, err := verifyGrant(ed25519.PublicKey(key), fixture.Token, peer, now); err != nil {
    		t.Fatalf("swift grant rejected: %v", err)
    	}
    	other := peer
    	other.PID++
    	if _, err := verifyGrant(ed25519.PublicKey(key), fixture.Token, other, now); err == nil {
    		t.Fatal("swift grant accepted for another pid")
    	}
    	tampered := []byte(fixture.Token)
    	tampered[len(tampered)-1] ^= 1
    	if _, err := verifyGrant(ed25519.PublicKey(key), string(tampered), peer, now); err == nil {
    		t.Fatal("tampered swift grant accepted")
    	}
    }
    """

    func testGoVerifierAcceptsSwiftGrant() throws {
        let environment = ProcessInfo.processInfo.environment
        // The sibling godspeed-browser checkout by default; GODSPEED_BROWSER_REPO points elsewhere.
        let sibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("godspeed-browser").path
        let repo = URL(fileURLWithPath: environment["GODSPEED_BROWSER_REPO"] ?? sibling)
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("internal/host/auth.go").path) else {
            throw XCTSkip("browser repo not found")
        }
        guard let go = Self.goExecutable(environment: environment) else {
            throw XCTSkip("go is not installed")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-go-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let key = Curve25519.Signing.PrivateKey()
        let issuer = try RelayGrantIssuer(store: StaticKeyStore(key: key))
        let peer = try RelayPeer.process(pid: getpid())
        let grant = try issuer.issue(peer: peer, sessionID: "godspeed-cross-check")
        let fixture: [String: Any] = [
            "token": grant.token,
            "publicKey": issuer.publicKeyBase64URL(),
            "pid": Int(peer.pid),
            "uid": Int(peer.uid),
            "startTime": peer.startTime,
            "now": grant.issuedAt,
        ]
        let fixtureURL = scratch.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: fixture).write(to: fixtureURL)

        let testFile = scratch.appendingPathComponent("zz_swift_relay_test.go")
        try Self.goTest.write(to: testFile, atomically: true, encoding: .utf8)
        let overlayURL = scratch.appendingPathComponent("overlay.json")
        let target = repo.appendingPathComponent("internal/host/zz_swift_relay_test.go").path
        let overlay: [String: Any] = ["Replace": [target: testFile.path]]
        try JSONSerialization.data(withJSONObject: overlay).write(to: overlayURL)

        let process = Process()
        process.executableURL = go
        process.arguments = ["test", "-overlay", overlayURL.path, "-count=1", "-run", "TestGodspeedSwiftRelayGrant", "./internal/host"]
        process.currentDirectoryURL = repo
        var env = environment
        env["RELAY_FIXTURE"] = fixtureURL.path
        env["GOPROXY"] = "off"
        env["GOFLAGS"] = "-mod=readonly"
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if text.contains("cannot find module") || text.contains("missing go.sum") || text.contains("GOPROXY") {
            throw XCTSkip("go module dependencies are not available offline")
        }
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("ok") || text.contains("PASS"), text)
    }

    private static func goExecutable(environment: [String: String]) -> URL? {
        let home = NSHomeDirectory()
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = fromPath + ["/usr/local/go/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/homebrew/bin", "\(home)/go/bin"]
        for directory in candidates {
            let path = (directory as NSString).appendingPathComponent("go")
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
