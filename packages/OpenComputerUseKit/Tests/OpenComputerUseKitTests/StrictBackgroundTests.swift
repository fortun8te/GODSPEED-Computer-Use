import AppKit
import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class StrictBackgroundTests: XCTestCase {
    func testStrictBatchRefusesForegroundWithoutDisturbingDesktop() throws {
        struct DesktopState: Equatable {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let keyWindow = UserKeyWindow.capture(excludingPID: 0, spi: .shared)?.windowID
            let pointer = CGEvent(source: nil)?.location
        }
        func hardwareInput() -> [UInt32] {
            let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                       .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            return types.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        }

        let dispatcher = ComputerUseToolDispatcher()
        for _ in 0..<3 {
            let inputBefore = hardwareInput()
            let before = DesktopState()
            let result = dispatcher.callToolAsResult(name: "batch", arguments: [
                "strict_background": true, "foreground": true, "effects": false,
                "steps": [["tool": "clipboard", "action": "read"]],
            ])
            let after = DesktopState()
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.failureCode?.rawValue, "BACKGROUND_UNSUPPORTED")
            // Concurrent physical input can change these values independently of the call.
            guard hardwareInput() == inputBefore else { continue }
            XCTAssertEqual(after, before)
            return
        }
        throw XCTSkip("The desktop received hardware input during all disturbance samples.")
    }

    func testStrictBatchKeepsRestrictionForNestedStepsAndRefusesPointerRoutes() {
        let dispatcher = ComputerUseToolDispatcher()
        let app = "com.example.strict-background-fixture"
        let result = dispatcher.callToolAsResult(name: "batch", arguments: [
            "strict_background": true, "app": app, "effects": false,
            "steps": [["tool": "click", "x": 12, "y": 12, "click_method": "global", "strict_background": false]],
        ])
        XCTAssertEqual(result.batchReceipt?.failureCode, .backgroundUnsupported)
        XCTAssertEqual(result.batchReceipt?.steps.first?.observation, .notSent)
    }

    func testStepCanRequireStrictModeBeforeBatchWouldBorrow() {
        let result = ComputerUseToolDispatcher().callToolAsResult(name: "batch", arguments: [
            "foreground": true, "effects": false,
            "steps": [["tool": "clipboard", "args": ["strict_background": true, "action": "read"]]],
        ])
        XCTAssertEqual(result.failureCode, .backgroundUnsupported)
    }

    func testStrictSettingAndCallOverrideFocusAndPointerPreferences() {
        let flags = GodspeedSettings.mappedVariables(from: ["strict_background": true])
        let env = flags.merging([
            "OPEN_COMPUTER_USE_FOCUS_BORROW": "1",
            "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1",
        ]) { _, new in new }
        XCTAssertTrue(StrictBackground.enabled(environment: env))
        XCTAssertFalse(FocusBorrow.isEnabled(environment: env))
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: env))
        StrictBackground.$requested.withValue(true) {
            XCTAssertFalse(FocusBorrow.isEnabled(environment: ["OPEN_COMPUTER_USE_FOCUS_BORROW": "1"]))
            XCTAssertFalse(globalPointerFallbacksEnabled(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1"]))
        }
    }

    func testStrictBrowserWillNotStartAHelper() {
        let env = ["OPEN_COMPUTER_USE_BROWSER": "1", "OPEN_COMPUTER_USE_OBU_BIN": "/usr/bin/true"]
        ClientScope.with(UUID().uuidString) {
            withBrowserRequestEnvironment(env) {
                let dispatcher = ComputerUseToolDispatcher()
                let result = dispatcher.callToolAsResult(name: "browser", arguments: [
                    "strict_background": true, "action": "read", "tab_id": 12,
                ])
                XCTAssertEqual(result.failureCode, .backgroundUnsupported, result.textContent)
            }
        }
    }
}
