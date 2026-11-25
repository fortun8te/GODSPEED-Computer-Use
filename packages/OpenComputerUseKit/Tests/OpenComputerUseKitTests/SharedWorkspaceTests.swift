import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class SharedWorkspaceTests: XCTestCase {
    private final class Probe {
        var idle: TimeInterval = 0
        var threshold: TimeInterval = 4
        var target: pid_t? = 200
        var foreground: pid_t = 200
        var window: CGWindowID? = 10
        var failForeground = false
        var idleReads = 0
        var targetReads = 0
        var foregroundReads = 0
        var windowReads = 0
        var onForegroundRead: ((Int) -> Void)?
        var observation: SharedWorkspace.Observation {
            SharedWorkspace.Observation(
                secondsSinceUserInput: { self.idleReads += 1; return self.idle },
                idleThreshold: { self.threshold },
                targetPID: { _ in self.targetReads += 1; return self.target },
                foregroundPID: {
                    self.foregroundReads += 1
                    self.onForegroundRead?(self.foregroundReads)
                    if self.failForeground { throw ComputerUseError.stateUnavailable("Cannot read foreground") }
                    return self.foreground
                },
                focusedWindowID: { _ in self.windowReads += 1; return self.window }
            )
        }
    }

    private func check(_ probe: Probe, tool: String = "type_text", arguments: [String: Any] = [:],
                       pin: CGWindowID? = nil, background: Bool = true) throws {
        try SharedWorkspace.requireAvailable(tool: tool,
            arguments: ["app": "test-app"].merging(arguments) { _, value in value },
            backgroundOnly: background, pinnedWindowID: pin, observation: probe.observation)
    }

    func testActiveUserRefusesOverlappingNativeMutationsAsUnsent() {
        for tool in ["click", "type_text", "set_value", "press_key", "press_menu", "scroll", "drag", "save_as"] {
            let probe = Probe()
            XCTAssertThrowsError(try check(probe, tool: tool)) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent, tool)
                XCTAssertEqual(ToolCallResult.failure(error).failureCode, .backgroundUnsupported, tool)
            }
        }
    }

    func testOtherAppsContinueWithoutReadingTheirFocusedWindows() throws {
        let probe = Probe()
        probe.foreground = 100
        try check(probe)
        XCTAssertEqual(probe.foregroundReads, 1)
        XCTAssertEqual(probe.windowReads, 0)
    }

    func testProvenDifferentPinnedWindowCanContinueInTheSameApp() throws {
        let probe = Probe()
        try check(probe, pin: 20)
        XCTAssertEqual(probe.foregroundReads, 2)
        XCTAssertEqual(probe.windowReads, 2)
    }

    func testSameUnknownOrUnenforcedWindowCannotBypassOverlap() {
        let same = Probe()
        XCTAssertThrowsError(try check(same, pin: 10))
        let unknown = Probe()
        unknown.window = nil
        XCTAssertThrowsError(try check(unknown, pin: 20))
        let rawArgument = Probe()
        XCTAssertThrowsError(try check(rawArgument, arguments: ["window_id": 20]))
        let appWide = Probe()
        XCTAssertThrowsError(try check(appWide, tool: "press_menu", pin: 20))
    }

    func testWindowSwitchOntoPinnedTargetDuringForegroundRecheckRefuses() {
        let probe = Probe()
        probe.onForegroundRead = { count in if count == 2 { probe.window = 20 } }
        XCTAssertThrowsError(try check(probe, pin: 20)) { error in
            XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent)
        }
        XCTAssertEqual(probe.windowReads, 2)
    }

    func testUserSwitchToAnotherAppDuringWindowReadAllowsBackgroundWork() throws {
        let probe = Probe()
        probe.onForegroundRead = { count in if count == 2 { probe.foreground = 100 } }
        try check(probe, pin: 20)
        XCTAssertEqual(probe.windowReads, 1)
    }

    func testUnknownForegroundRefusesInsteadOfAssumingTheTargetIsBackground() {
        for fail in [false, true] {
            let probe = Probe()
            probe.foreground = 0
            probe.failForeground = fail
            XCTAssertThrowsError(try check(probe)) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent)
            }
        }
    }

    func testIdleAndExplicitForegroundWorkKeepTheirExistingBehavior() throws {
        let idle = Probe()
        idle.idle = idle.threshold
        try check(idle)
        XCTAssertEqual(idle.targetReads, 0)
        let foreground = Probe()
        try check(foreground, background: false)
        XCTAssertEqual(foreground.idleReads, 0)
        let benchmark = Probe()
        benchmark.threshold = 0
        try check(benchmark)
        XCTAssertEqual(benchmark.foregroundReads, 0)
    }

    func testReadsBrowserContainersAndPrivateClipboardNeverObserveTheDesktop() throws {
        for tool in ["query", "get_app_state", "wait_for", "list_apps", "browser", "clipboard", BatchTool.name, HandoffTool.name] {
            let probe = Probe()
            try check(probe, tool: tool, arguments: ["action": "write"])
            XCTAssertEqual(probe.idleReads, 0, tool)
        }
        let copy = Probe()
        try check(copy, tool: "press_key", arguments: ["key": "cmd+c"])
        XCTAssertEqual(copy.idleReads, 0)
        for key in ["cmd+x", "cmd+v"] {
            XCTAssertThrowsError(try check(Probe(), tool: "press_key", arguments: ["key": key]))
        }
    }

    func testUnresolvedAppKeepsTheExistingResolutionPath() throws {
        let probe = Probe()
        probe.target = nil
        try check(probe)
        XCTAssertEqual(probe.foregroundReads, 0)
    }

    func testDispatcherRefusesBeforeLabelHealingOrNativeAction() {
        let probe = Probe()
        let dispatcher = ComputerUseToolDispatcher(actionPolicyURL: absentPolicyURL(), workspaceObservation: probe.observation)
        let result = RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_BACKGROUND_ONLY": "1"]) {
            dispatcher.callToolAsResult(name: "click", arguments: ["app": "test-app", "label": "A missing button"])
        }
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.failureCode, .backgroundUnsupported)
        XCTAssertEqual(result.deliveryState, .notSent)
        XCTAssertEqual(probe.foregroundReads, 1)
        XCTAssertTrue(result.textContent.contains("user is active"))
    }

    func testDispatcherKeepsPrivateClipboardIndependentOfUserActivity() {
        let probe = Probe()
        let dispatcher = ComputerUseToolDispatcher(actionPolicyURL: absentPolicyURL(), workspaceObservation: probe.observation)
        ClientScope.with(UUID().uuidString) {
            RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_BACKGROUND_ONLY": "1"]) {
                let write = dispatcher.callToolAsResult(name: "clipboard", arguments: ["action": "write", "text": "private text"])
                let read = dispatcher.callToolAsResult(name: "clipboard", arguments: ["action": "read"])
                XCTAssertFalse(write.isError)
                XCTAssertEqual(read.textContent, "private text")
            }
        }
        XCTAssertEqual(probe.idleReads, 0)
    }

    private func absentPolicyURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shared-workspace-\(UUID().uuidString).json")
    }
}
