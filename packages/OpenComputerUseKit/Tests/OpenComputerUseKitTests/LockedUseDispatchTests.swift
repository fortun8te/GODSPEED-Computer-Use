import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class LockedUseDispatchTests: XCTestCase {
    private enum Revoked: Error { case lease }

    func testStatusIdentifiesUnpackagedLockedUse() {
        // SwiftPM's test host has no embedded Locked Use component package.
        let diagnostics = LockedUseDiagnostics.current()
        XCTAssertNil(diagnostics.bundledPluginVersion)
        XCTAssertFalse(diagnostics.available)
        XCTAssertEqual(diagnostics.stage, "not-packaged")
        XCTAssertTrue(diagnostics.blockers.contains { $0.contains("Godspeed build") })
        XCTAssertFalse(diagnostics.blockers.contains { $0.contains("locked-use enable") })
    }

    func testSerializedBrowserTransportRejectsLockedAndUnavailableSessions() throws {
        for state in [LockedUseSession.State.locked, .unavailable] {
            let unavailable = LockedUseSession(state: state, userID: nil, auditSessionID: nil)
            try withBrowserRequestEnvironment(["OPEN_COMPUTER_USE_BROWSER": "1"]) {
                try BrowserRequestContext.withDesktopValidation(session: { unavailable }) {
                    XCTAssertEqual(BrowserRequestContext.environment["OPEN_COMPUTER_USE_BROWSER"], "1")
                    XCTAssertThrowsError(try BrowserRequestContext.validateCurrent()) { error in
                        guard let driverError = error as? ComputerUseError, case .stateUnavailable = driverError else {
                            return XCTFail("Expected desktop unavailability, received \(error)")
                        }
                    }
                }
            }
        }
        XCTAssertNil(BrowserRequestContext.current)
    }

    func testParallelBrowserTransportRetainsItsOwnValidator() throws {
        try withBrowserRequestEnvironment([:], validate: { throw Revoked.lease }) {
            try BrowserRequestContext.withDesktopValidation(session: {
                XCTFail("Parallel checks own session admission")
                return LockedUseSession(state: .locked, userID: nil, auditSessionID: nil)
            }) {
                XCTAssertThrowsError(try BrowserRequestContext.validateCurrent()) { error in
                    XCTAssertTrue(error is Revoked)
                }
            }
        }
    }

    func testColdHandshakeBudgetDoesNotExtendActionOrGuardDeadlines() {
        XCTAssertEqual(LockedUseIPCEndpoint.agent.timeout(operation: .begin, firstReply: true), 8)
        XCTAssertEqual(LockedUseIPCEndpoint.observer.timeout(operation: .status, firstReply: true), 8)
        XCTAssertEqual(LockedUseIPCEndpoint.guardian.timeout(operation: .guardianHello, firstReply: true), 8)
        for endpoint in [LockedUseIPCEndpoint.agent, .guardian, .plugin, .admin] {
            for operation in [LockedUseIPCMessage.Operation.action, .guardianReport, .watchdogReport, .pluginConsume] {
                XCTAssertEqual(endpoint.timeout(operation: operation, firstReply: true), 2)
            }
        }
        XCTAssertEqual(LockedUseIPCEndpoint.agent.timeout(operation: .begin, firstReply: false), 2)
        XCTAssertEqual(LockedUseIPCEndpoint.plugin.timeout(operation: .pluginClaim, firstReply: true), 2)
    }

    func testLeasedCapturePolicyIsClearedOnThrow() {
        XCTAssertFalse(LockedUseActionScope.requiresScreenCaptureKit)
        XCTAssertThrowsError(try LockedUseActionScope.withValidator({}, body: {
            XCTAssertTrue(LockedUseActionScope.requiresScreenCaptureKit)
            throw Revoked.lease
        }))
        XCTAssertFalse(LockedUseActionScope.requiresScreenCaptureKit)
    }

    func testRevokedLeaseStopsInputAndQueryBeforeResolvingTarget() throws {
        guard LockedUseSession.current().state == .unlocked else {
            throw XCTSkip("Requires a completed unlocked console session; no input is emitted")
        }
        // These targets deliberately do not exist. A revoked lease must be
        // reported before capability, process or window checks can run.
        let click = SkyClickTarget(screenPoint: .zero, windowPoint: .zero,
                                   windowBounds: .zero, windowID: 0, pid: -1)
        let keyboard = SkyKeyboardTarget(windowID: 0, pid: -1)
        let actions: [() throws -> Void] = [
            { try SkyClickDispatcher.click(target: click, clickCount: 1) },
            { try SkyKeyboardDispatcher.typeText(target: keyboard, text: "probe") },
            { try SkyKeyboardDispatcher.pressKey(target: keyboard, key: "cmd+a") },
            { _ = try ComputerUseService().query(app: "NoSuchRevokedLeaseApp", text: "Send") },
            { _ = try ComputerUseService().pressMenu(app: "NoSuchRevokedLeaseApp", path: "File > Save") }
        ]
        for action in actions {
            try LockedUseActionScope.withValidator({ throw Revoked.lease }, body: {
                XCTAssertThrowsError(try action()) { error in
                    XCTAssertTrue(error is Revoked)
                }
            })
        }
    }
}
