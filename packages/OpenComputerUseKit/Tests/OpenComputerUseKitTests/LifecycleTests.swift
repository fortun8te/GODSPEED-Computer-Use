import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for the app agent's idle exit, its idle-exit setting, and the helper auto-start
/// decision. Nothing here starts a process, opens a socket, or waits on a timer.
final class LifecycleTests: XCTestCase {
    // MARK: - Idle exit

    func testAgentWithNoClientExitsAfterTheLimit() {
        var timer = AgentIdleTimer(idleLimit: 900, now: 1_000)
        XCTAssertFalse(timer.shouldExit(now: 1_899.9))
        XCTAssertTrue(timer.shouldExit(now: 1_900))
    }

    func testExitHappensOnlyOnce() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        XCTAssertTrue(timer.shouldExit(now: 10))
        XCTAssertTrue(timer.isExiting)
        XCTAssertFalse(timer.shouldExit(now: 500))
    }

    func testConnectedClientKeepsAgentAlive() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        XCTAssertTrue(timer.clientConnected())
        XCTAssertFalse(timer.shouldExit(now: 1_000_000))
        XCTAssertEqual(timer.connectedClients, 1)
    }

    func testIdleClockStartsWhenTheLastClientLeaves() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        XCTAssertTrue(timer.clientConnected())
        timer.clientDisconnected(now: 100)
        XCTAssertFalse(timer.shouldExit(now: 109))
        XCTAssertTrue(timer.shouldExit(now: 110))
    }

    func testSecondClientKeepsAgentAliveUntilBothLeave() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        XCTAssertTrue(timer.clientConnected())
        XCTAssertTrue(timer.clientConnected())
        timer.clientDisconnected(now: 50)
        XCTAssertFalse(timer.shouldExit(now: 1_000))
        timer.clientDisconnected(now: 200)
        XCTAssertFalse(timer.shouldExit(now: 209))
        XCTAssertTrue(timer.shouldExit(now: 210))
    }

    func testReconnectingResetsTheIdleClock() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        XCTAssertTrue(timer.clientConnected())
        timer.clientDisconnected(now: 5)
        XCTAssertTrue(timer.clientConnected())
        timer.clientDisconnected(now: 100)
        XCTAssertFalse(timer.shouldExit(now: 105))
        XCTAssertTrue(timer.shouldExit(now: 110))
    }

    func testExitDeadlineDisarmsDuringConnectionsAndRearmsAfterTheLastOne() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        XCTAssertEqual(timer.nextExitDelay(now: 3), 7)
        XCTAssertTrue(timer.clientConnected())
        XCTAssertTrue(timer.clientConnected())
        XCTAssertNil(timer.nextExitDelay(now: 9))
        timer.clientDisconnected(now: 10)
        XCTAssertNil(timer.nextExitDelay(now: 10))
        timer.clientDisconnected(now: 12)
        XCTAssertEqual(timer.nextExitDelay(now: 12), 10)
        XCTAssertEqual(timer.nextExitDelay(now: 22), 0)
        XCTAssertTrue(timer.shouldExit(now: 22))
        XCTAssertNil(timer.nextExitDelay(now: 22))
        XCTAssertNil(AgentIdleTimer(idleLimit: 0, now: 0).nextExitDelay(now: 22))
    }

    func testZeroLimitNeverExits() {
        var timer = AgentIdleTimer(idleLimit: 0, now: 0)
        XCTAssertFalse(timer.shouldExit(now: 1_000_000_000))
        XCTAssertFalse(timer.isExiting)
    }

    func testExitingAgentRefusesNewClients() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        XCTAssertTrue(timer.shouldExit(now: 10))
        XCTAssertFalse(timer.clientConnected())
        XCTAssertEqual(timer.connectedClients, 0)
    }

    func testDisconnectWithoutConnectDoesNotGoNegative() {
        var timer = AgentIdleTimer(idleLimit: 10, now: 0)
        timer.clientDisconnected(now: 3)
        XCTAssertEqual(timer.connectedClients, 0)
        XCTAssertTrue(timer.shouldExit(now: 13))
    }

    // MARK: - Idle-exit setting

    func testIdleExitDefaultsToFifteenMinutes() {
        XCTAssertEqual(AgentIdlePolicy.idleExitSeconds(environment: [:]), 900)
        XCTAssertEqual(AgentIdlePolicy.defaultIdleExitSeconds, 900)
    }

    func testIdleExitReadsTheEnvironmentVariable() {
        let key = AgentIdlePolicy.environmentKey
        XCTAssertEqual(AgentIdlePolicy.idleExitSeconds(environment: [key: "120"]), 120)
        XCTAssertEqual(AgentIdlePolicy.idleExitSeconds(environment: [key: " 2.5 "]), 2.5)
    }

    func testIdleExitZeroMeansNever() {
        XCTAssertEqual(AgentIdlePolicy.idleExitSeconds(environment: [AgentIdlePolicy.environmentKey: "0"]), 0)
    }

    func testIdleExitInvalidValuesFallBackToDefault() {
        let key = AgentIdlePolicy.environmentKey
        for raw in ["", "soon", "-5", "nan", "inf"] {
            XCTAssertEqual(
                AgentIdlePolicy.idleExitSeconds(environment: [key: raw]),
                AgentIdlePolicy.defaultIdleExitSeconds,
                "raw value \(raw)"
            )
        }
    }

    // MARK: - Helper auto-start decision

    func testHelperStartsOnlyWhenDownLocalAndLauncherExists() {
        XCTAssertTrue(HelperAutoStarter.shouldLaunch(loopback: true, healthy: false, launcherExists: true, launchedBefore: false))
    }

    func testHelperNeverStartsWhenHealthy() {
        XCTAssertFalse(HelperAutoStarter.shouldLaunch(loopback: true, healthy: true, launcherExists: true, launchedBefore: false))
    }

    func testHelperNeverStartsForARemoteURL() {
        XCTAssertFalse(HelperAutoStarter.shouldLaunch(loopback: false, healthy: false, launcherExists: true, launchedBefore: false))
    }

    func testHelperNeverStartsWithoutLauncher() {
        XCTAssertFalse(HelperAutoStarter.shouldLaunch(loopback: true, healthy: false, launcherExists: false, launchedBefore: false))
    }

    func testHelperIsLaunchedOncePerProcess() {
        XCTAssertFalse(HelperAutoStarter.shouldLaunch(loopback: true, healthy: false, launcherExists: true, launchedBefore: true))
    }

    func testLoopbackHosts() {
        XCTAssertTrue(HelperAutoStarter.isLoopback(URL(string: "http://127.0.0.1:8765")!))
        XCTAssertTrue(HelperAutoStarter.isLoopback(URL(string: "http://localhost:8765")!))
        XCTAssertFalse(HelperAutoStarter.isLoopback(URL(string: "http://192.168.1.20:8765")!))
        XCTAssertFalse(HelperAutoStarter.isLoopback(URL(string: "https://example.com")!))
    }

    func testHealthCheckCooldown() {
        XCTAssertTrue(HelperAutoStarter.shouldCheck(lastCheck: nil, now: 5, cooldown: 60))
        XCTAssertFalse(HelperAutoStarter.shouldCheck(lastCheck: 100, now: 159, cooldown: 60))
        XCTAssertTrue(HelperAutoStarter.shouldCheck(lastCheck: 100, now: 160, cooldown: 60))
    }
}

final class ClientScopeTests: XCTestCase {
    func testEachClientHasItsOwnMemoriesAndBrowserSession() {
        let a = ClientScope.with("agent-a") { () -> (ObjectIdentifier, String) in
            RecentAppMemory.shared.remember("Messages")
            return (ObjectIdentifier(BatchObservationMemory.shared), BrowserBridge.shared.sessionID)
        }
        let b = ClientScope.with("agent-b") { () -> (ObjectIdentifier, String, String?) in
            (ObjectIdentifier(BatchObservationMemory.shared), BrowserBridge.shared.sessionID, RecentAppMemory.shared.current)
        }
        XCTAssertNotEqual(a.0, b.0)
        XCTAssertNotEqual(a.1, b.1)
        XCTAssertTrue(a.1.hasSuffix("-agent-a"))
        XCTAssertNil(b.2, "agent b must not inherit agent a's last app")
        XCTAssertEqual(ClientScope.with("agent-a") { RecentAppMemory.shared.current }, "Messages")
        XCTAssertEqual(ClientScope.current, "main")
    }

    func testScopeNamesAreSanitizedAndNest() {
        XCTAssertEqual(ClientScope.sanitized("p123"), "p123")
        XCTAssertNotEqual(ClientScope.sanitized("../x y"), ClientScope.sanitized("xy"))
        XCTAssertNotEqual(ClientScope.sanitized("main"), ClientScope.sanitized(nil))
        let longPrefix = String(repeating: "a", count: 40)
        XCTAssertNotEqual(ClientScope.sanitized(longPrefix + "1"), ClientScope.sanitized(longPrefix + "2"))
        XCTAssertEqual(ClientScope.sanitized(nil), "main")
        ClientScope.with("outer") {
            ClientScope.with("inner") { XCTAssertEqual(ClientScope.current, "inner") }
            XCTAssertEqual(ClientScope.current, "outer")
        }
    }

    func testOtherActiveClientsAreSeen() {
        ClientScope.with("busy-one") {}
        XCTAssertTrue(ClientScope.with("busy-two") { ClientScope.othersActive() })
        XCTAssertFalse(ClientScope.othersActive(than: "busy-one", within: 0))
    }
}

final class BrowserDuplicateLabelTests: XCTestCase {
    private func node(_ index: Int, _ role: String, _ name: String, backend: Int, parent: Int = 0) -> BrowserNode {
        BrowserNode(index: index, role: role, name: name, value: "", backendNodeID: backend, inFrame: false, parentControl: parent)
    }

    func testSeveralDifferentElementsWithOneLabelAreListedNotGuessed() {
        let nodes = [
            node(1, "link", "Shoes", backend: 1),
            node(2, "button", "Add to cart", backend: 2),
            node(3, "link", "Hat", backend: 3),
            node(4, "button", "Add to cart", backend: 4),
        ]
        XCTAssertThrowsError(try BrowserPage.pickFuzzy(nodes, label: "Add to cart")) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("2 button") && text.contains("4 button"), text)
        }
        XCTAssertNil(BrowserPage.pickNamed(nodes, wanted: BrowserPage.normalize("Add to cart")))
        XCTAssertEqual(try BrowserPage.pickFuzzy(nodes, label: "Hat")?.index, 3)
    }

    func testAButtonInsideALinkWithTheSameLabelIsOneTarget() throws {
        let nodes = [
            node(1, "link", "Buy now", backend: 1),
            node(2, "button", "Buy now", backend: 2, parent: 1),
        ]
        XCTAssertEqual(try BrowserPage.pickFuzzy(nodes, label: "Buy now")?.index, 1)
        XCTAssertEqual(BrowserPage.outermost(nodes, all: nodes).map(\.index), [1])
    }

    func testParseRecordsTheEnclosingControl() {
        func ax(_ id: String, parent: String?, role: String, name: String, backend: Int) -> [String: Any] {
            var node: [String: Any] = ["nodeId": id, "role": ["value": role], "name": ["value": name], "backendDOMNodeId": backend]
            if let parent { node["parentId"] = parent }
            return node
        }
        let raw = [
            ax("1", parent: nil, role: "RootWebArea", name: "Shop", backend: 1),
            ax("2", parent: "1", role: "link", name: "Buy now", backend: 2),
            ax("3", parent: "2", role: "generic", name: "", backend: 3),
            ax("4", parent: "3", role: "button", name: "Buy now", backend: 4),
            ax("5", parent: "1", role: "button", name: "Buy now", backend: 5),
        ]
        let controls = BrowserPage.parseAX(raw).controls
        XCTAssertEqual(controls.map(\.parentControl), [0, 1, 0])
        XCTAssertThrowsError(try BrowserPage.pickFuzzy(controls, label: "Buy now"))
    }
}

final class BrowserRepeatSafetyTests: XCTestCase {
    func testOnlyHarmlessCommandsAreSentAgainAfterALinkDrop() {
        XCTAssertTrue(BrowserPage.isRepeatSafe("Accessibility.getFullAXTree", [:]))
        XCTAssertTrue(BrowserPage.isRepeatSafe("Input.dispatchMouseEvent", ["type": "mouseMoved"]))
        XCTAssertFalse(BrowserPage.isRepeatSafe("Input.dispatchMouseEvent", ["type": "mousePressed"]))
        XCTAssertFalse(BrowserPage.isRepeatSafe("Input.insertText", ["text": "x"]))
        XCTAssertFalse(BrowserPage.isRepeatSafe("Input.dispatchKeyEvent", ["type": "keyDown"]))
        XCTAssertTrue(BrowserPage.isRepeatSafe("Runtime.evaluate", ["expression": "[location.href, document.title]"]))
        XCTAssertFalse(BrowserPage.isRepeatSafe("Runtime.callFunctionOn", ["functionDeclaration": "function(i){this.selectedIndex=i;}"]))
    }
}
