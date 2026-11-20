import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class ActionHardeningTests: XCTestCase {
    func testScrollChunksStopAtTheFirstStalledPosition() throws {
        let chunks = try XCTUnwrap(ScrollChunks(["unit": "points", "step_size": 30, "max_steps": 12]))
        var attempts = 0
        let outcome = try chunks.run(visible: { XCTFail("Unexpected lookup"); return false }, advance: {
            attempts += 1
            return attempts < 3
        })
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(outcome.chunks, 2)
        XCTAssertEqual(outcome.stop, .stalled)
    }

    func testScrollChecksVisibilityBeforeInputAndAfterEachChunk() throws {
        let chunks = try XCTUnwrap(ScrollChunks(["until_visible": "Last item"]))
        var moves = 0
        let found = try chunks.run(visible: { moves == 2 }, advance: { moves += 1; return true })
        XCTAssertEqual(found.chunks, 2)
        XCTAssertEqual(found.stop, .visible)
        let already = try chunks.run(visible: { true }, advance: { XCTFail("Already visible"); return false })
        XCTAssertEqual(already.chunks, 0)
        let missing = try chunks.run(visible: { false }, advance: { false })
        XCTAssertThrowsError(try missing.reply(label: chunks.untilVisible))
    }

    func testScrollArgumentBoundsAndLegacyPageParsing() throws {
        XCTAssertNil(try ScrollChunks(["pages": 0.5]))
        for invalid: [String: Any] in [
            ["unit": "lines", "step_size": true], ["unit": "points", "step_size": 0],
            ["unit": "pages", "step_size": 2], ["max_steps": 21], ["until_visible": ""],
            ["unit": "points", "pages": 1]
        ] {
            XCTAssertThrowsError(try ScrollChunks(invalid))
        }
        let tool = ComputerUseToolDispatcher()
        let result = tool.callToolAsResult(name: "scroll", arguments: [
            "app": "Missing", "direction": "down", "element_index": "1", "unit": "points", "max_steps": 21
        ])
        XCTAssertTrue(result.textContent.contains("max_steps"))
    }

    func testScrollEventsUseTheSpecifiedAxisAndUnits() throws {
        let lines = try BackgroundDragDispatcher.scrollEvent(direction: "down", unit: .lines, size: 3)
        XCTAssertEqual(lines.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertEqual(lines.getIntegerValueField(.scrollWheelEventDeltaAxis2), 0)
        let points = try BackgroundDragDispatcher.scrollEvent(direction: "left", unit: .points, size: 45)
        XCTAssertEqual(points.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 45)
        XCTAssertEqual(points.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
    }

    func testScrollIntoViewRoutesOnEitherSurfaceAndUnsupportedIsTyped() throws {
        let steps = try BatchTool.parseSteps([
            ["tool": "scroll_into_view", "label": "End"],
            ["tool": "scroll_into_view", "web": true, "label": "End"],
        ], defaultApp: "Fixture")
        XCTAssertEqual(steps.map(\.tool), ["scroll_into_view", "browser"])
        XCTAssertEqual(steps[1].arguments["action"] as? String, "scroll_into_view")
        let error = ComputerUseError.backgroundUnsupported("Test refusal")
        XCTAssertEqual(TrajectoryLog.failureCode(error: error, message: error.localizedDescription), .backgroundUnsupported)
    }
}
