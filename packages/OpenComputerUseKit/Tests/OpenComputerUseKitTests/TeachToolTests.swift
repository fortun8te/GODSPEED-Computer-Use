import Foundation
import XCTest
@testable import OpenComputerUseKit

/// The `teach` tool as the dispatcher exposes it. No accessibility or event APIs run: the source is refused.
final class TeachToolTests: XCTestCase {
    private var folder: URL!
    private var dispatcher: ComputerUseToolDispatcher!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("teach-tool-\(UUID().uuidString)")
        let teach = TeachMode(
            store: BatchRecipes(fileURL: folder.appendingPathComponent("recipes.json")),
            makeSource: { nil },
            resolveApp: { _ in TeachMode.AppTarget(pid: 1, name: "Mail") },
            readWindow: { _ in nil },
            now: { Date() },
            scheduleTimer: false
        )
        dispatcher = ComputerUseToolDispatcher(
            service: ComputerUseService(),
            actionPolicyURL: folder.appendingPathComponent("policy.json"),
            recipeStore: BatchRecipes(fileURL: folder.appendingPathComponent("recipes.json")),
            teach: teach
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testTeachIsListedWithItsActionsAndAUseDescription() throws {
        let tool = try XCTUnwrap(ToolDefinitions.all.first { $0.name == "teach" })
        XCTAssertTrue(tool.description.hasPrefix("Use "), tool.description)
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        XCTAssertEqual(action?["enum"] as? [String], ["start", "stop", "status"])
    }

    func testStatusWithoutRecordingSaysItIsOff() throws {
        let result = try dispatcher.callTool(name: "teach", arguments: ["action": "status"])
        XCTAssertEqual(result.textContent, "Recording is off.")
    }

    func testStopWithoutRecordingSaysItIsNotOn() throws {
        let result = try dispatcher.callTool(name: "teach", arguments: ["action": "stop"])
        XCTAssertTrue(result.textContent.hasPrefix("Recording is not on."), result.textContent)
    }

    func testStartNeedsAnAppAndAGoal() {
        XCTAssertThrowsError(try dispatcher.callTool(name: "teach", arguments: ["action": "start", "app": "Mail"]))
        XCTAssertThrowsError(try dispatcher.callTool(name: "teach", arguments: ["action": "start", "goal": "Email Sam"]))
    }

    func testStartWithoutAWatchableSourceIsRefused() {
        XCTAssertThrowsError(try dispatcher.callTool(name: "teach", arguments: ["action": "start", "app": "Mail", "goal": "Email Sam"]))
    }

    func testUnknownActionIsRefused() {
        XCTAssertThrowsError(try dispatcher.callTool(name: "teach", arguments: ["action": "replay"]))
    }
}
