import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

final class StaleHealingContextTests: XCTestCase {
    private let app = TargetedAppIdentity(pid: 42, bundleIdentifier: "test.editor", launchedAt: Date(timeIntervalSince1970: 100))
    private let nodes = [SmartSteps.Node(index: 12, role: "AXButton", subrole: nil, name: "Save", frame: nil)]

    private func recover(from original: NativeWindowObservation?, to current: NativeWindowObservation?) -> StaleHealing.Outcome {
        StaleHealing.recover(index: "3", role: "button", label: "Save", observedWindow: original,
                             currentWindow: current, nodes: nodes)
    }

    func testUniqueRedrawnControlCanRecoverInsideOriginalWindow() {
        let window = NativeWindowObservation(id: 7, app: app)
        XCTAssertEqual(recover(from: window, to: window),
                       .use(index: 12, note: "(element 3 was redrawn; used 12 \"Save\")"))
    }

    func testIdenticalControlInAnotherDocumentCannotRecover() {
        let original = NativeWindowObservation(id: 7, app: app)
        guard case .refuse = recover(from: original, to: NativeWindowObservation(id: 8, app: app)) else {
            return XCTFail("a matching label cannot authorize a different window")
        }
    }

    func testProcessRestartCannotReuseTheSameWindowAndControlIdentity() {
        let original = NativeWindowObservation(id: 7, app: app)
        for replacement in [
            TargetedAppIdentity(pid: 43, bundleIdentifier: "test.editor", launchedAt: app.launchedAt),
            TargetedAppIdentity(pid: 42, bundleIdentifier: "test.editor", launchedAt: Date(timeIntervalSince1970: 200)),
            TargetedAppIdentity(pid: 42, bundleIdentifier: "another.editor", launchedAt: app.launchedAt),
        ] {
            guard case .refuse = recover(from: original, to: NativeWindowObservation(id: 7, app: replacement)) else {
                return XCTFail("recovery must preserve application identity")
            }
        }
    }

    func testMissingObservationRefusesInsteadOfGuessing() {
        let window = NativeWindowObservation(id: 7, app: app)
        for (before, after) in [(nil, window), (window, nil), (nil, nil)] as [(NativeWindowObservation?, NativeWindowObservation?)] {
            guard case .refuse = recover(from: before, to: after) else {
                return XCTFail("both window identities are required")
            }
        }
    }
}
