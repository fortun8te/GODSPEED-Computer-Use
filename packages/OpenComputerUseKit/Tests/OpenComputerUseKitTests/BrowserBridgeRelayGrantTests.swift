import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Renewal timing and host error mapping for the BrowserBridge relay grant.
final class BrowserBridgeRelayGrantTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

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
}
