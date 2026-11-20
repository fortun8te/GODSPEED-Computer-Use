import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class ActionHardeningTests: XCTestCase {
    func testClickPlacementUsesAnInsetEdgeAndRejectsOutOfBoundsOffsets() throws {
        let frame = CGRect(x: 100, y: 50, width: 80, height: 6)
        XCTAssertEqual(try ClickPlacement(["anchor": "right", "offset_x": -3]).point(in: frame), CGPoint(x: 176, y: 53))
        XCTAssertThrowsError(try ClickPlacement(["offset_x": true]))
        XCTAssertThrowsError(try ClickPlacement(["anchor": "right", "offset_x": 4]).point(in: frame))
        XCTAssertTrue(ActionOptions.usesStrictRoute("click", ["modifiers": ["shift"]]))
    }

    func testBrowserDragHoldAndStepsRemainInOneButtonSequence() throws {
        var events: [String] = []
        var pauses: [TimeInterval] = []
        try BrowserPage.deliverDrag(from: .zero, to: CGPoint(x: 24, y: 12), steps: 3, hold: 0.3,
                                    pause: { pauses.append($0) }) { type, _, buttons, _ in
            events.append("\(type):\(buttons)")
        }
        XCTAssertEqual(events, ["mouseMoved:0", "mousePressed:1", "mouseMoved:1", "mouseMoved:1", "mouseMoved:1", "mouseReleased:0"])
        XCTAssertEqual(pauses, [0.3])
        XCTAssertThrowsError(try DragOptions(["drag_steps": 31]))
        XCTAssertThrowsError(try DragOptions(["files": ["/tmp/file.txt"]]))
        XCTAssertThrowsError(try DragOptions.validateEndpoint(index: "1", x: 20, y: 30, name: "destination"))
        let native = try BatchTool.parseSteps([["tool": "drag", "from_label": "Card", "to_label": "List"]], defaultApp: "Fixture")
        XCTAssertEqual(native.first?.tool, "drag")
        let web = try BatchTool.parseSteps([["tool": "drag", "web": true, "label": "Card", "to_label": "List"]], defaultApp: "Fixture")
        XCTAssertEqual(web.first?.tool, "browser")
    }

    func testControlWaitUsesAnExplicitValueAndNeverConfirmsAnUnreadableAbsence() throws {
        let changed = try XCTUnwrap(ControlWait(["label": "Volume", "condition": "value_changed", "from_value": "20"]))
        XCTAssertEqual(try changed.run { .value(42, "22") }, "Volume changed value.")

        let gone = try XCTUnwrap(ControlWait(["label": "Loading", "condition": "disappears", "timeout": 1]))
        var time: TimeInterval = 0
        var probes = 0
        XCTAssertThrowsError(try gone.run(now: { time }, pause: { time += $0 }) { () -> ControlWait.Sample<Int> in
            probes += 1
            return .unreadable
        })
        XCTAssertEqual(time, 1)
        XCTAssertGreaterThan(probes, 0)
        XCTAssertLessThan(probes, 10)
        XCTAssertEqual(try gone.run { () -> ControlWait.Sample<Int> in .absent }, "Loading is absent.")

        let steps = try BatchTool.parseSteps([
            ["tool": "wait_for", "label": "Ready", "condition": "appears"],
            ["tool": "wait_for", "web": true, "label": "Ready", "condition": "appears"],
        ], defaultApp: "Fixture")
        XCTAssertEqual(steps.map(\.tool), ["wait_for", "browser"])
        XCTAssertTrue(steps.allSatisfy(\.isReadOnly))
    }

    func testValueWaitRejectsAReplacementWithTheSameLabel() throws {
        let wait = try XCTUnwrap(ControlWait(["label": "Volume", "condition": "value_changed"]))
        var samples: [ControlWait.Sample<Int>] = [.value(1, "20"), .value(2, "22")]
        XCTAssertThrowsError(try wait.run(pause: { _ in }) { samples.removeFirst() }) {
            XCTAssertTrue($0.localizedDescription.contains("identity"))
        }
        XCTAssertTrue(samples.isEmpty)
    }

    func testExplicitTextRangePreservesUTF16BoundariesAndBatchRouting() throws {
        let value = "A😀B"
        let target = try TextSelectionResolver.resolve(value: value, start: 1, length: 2)
        XCTAssertEqual(target.location, 1)
        XCTAssertEqual(target.length, 2)
        XCTAssertEqual(try TextSelectionResolver.resolve(value: value, start: 4, length: 0).location, 4)
        XCTAssertThrowsError(try TextSelectionResolver.resolve(value: value, start: 1, length: 1))
        XCTAssertThrowsError(try TextSelectionResolver.resolve(value: value, start: 2, length: 1))
        XCTAssertThrowsError(try TextSelectionResolver.resolve(value: value, start: 1, length: Int.max))
        XCTAssertThrowsError(try TextRangeRequest(["start": 0, "length": 1, "text": "A"]))

        let steps = try BatchTool.parseSteps([
            ["tool": "select_text", "label": "Body", "start": 1, "length": 2],
            ["tool": "select_text", "web": true, "label": "Body", "start": 1, "length": 2],
        ], defaultApp: "Fixture")
        XCTAssertEqual(steps.map(\.tool), ["select_text", "browser"])
        let command = FixtureCommand(kind: "select_text", identifier: "fixture-input", rangeStart: 1, rangeLength: 2)
        let roundTrip = try JSONDecoder().decode(FixtureCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(roundTrip.rangeStart, 1)
        XCTAssertEqual(roundTrip.rangeLength, 2)
        let legacy = try JSONDecoder().decode(FixtureCommand.self, from: Data(#"{"kind":"select_text","identifier":"fixture-input","value":"B"}"#.utf8))
        XCTAssertNil(legacy.rangeLength)
    }

    func testHoverDwellUsesBoundedMillisecondsAndStrictRouting() throws {
        XCTAssertEqual(try ActionOptions.duration("dwell_ms", in: ["dwell_ms": 750], maxMs: 2000), 0.75)
        XCTAssertThrowsError(try ActionOptions.duration("dwell_ms", in: ["dwell_ms": 2001], maxMs: 2000))
        XCTAssertTrue(ActionOptions.usesStrictRoute("hover", ["dwell_ms": 750]))
        XCTAssertFalse(ActionOptions.usesStrictRoute("hover", [:]))
        XCTAssertThrowsError(try BrowserCallBudget.withDeadline(BrowserCallBudget.deadline(after: 0.1)) {
            try ActionOptions.requireTime(for: 0.75)
        })
    }

    func testHeldKeysReleaseOnceOnSuccessOrUncertainPress() throws {
        var events: [String] = []
        try BrowserPage.deliverHeldKey(hold: 0.2, pause: { events.append("hold \($0)") },
                                       press: { events.append("down") }, release: { events.append("up") })
        XCTAssertEqual(events, ["down", "hold 0.2", "up"])
        events.removeAll()
        XCTAssertThrowsError(try BrowserPage.deliverHeldKey(hold: 0.2, pause: { _ in XCTFail("Unexpected hold") },
            press: { events.append("down"); throw ComputerUseError.stateUnavailable("Uncertain press.") },
            release: { events.append("up") }))
        XCTAssertEqual(events, ["down", "up"])
        XCTAssertTrue(ActionOptions.usesStrictRoute("press_key", ["hold_ms": 200]))
    }

    func testNativeHeldKeyReleasesItsModifiersWhenFocusChanges() throws {
        let chord = try KeyPressParser.parse("shift+Down", layout: { _ in nil })
        var events: [CGEvent] = []
        var maySend = true
        XCTAssertThrowsError(try InputSimulation.deliverHeldKey(chord, hold: 0.2, validate: {
            if !maySend { throw ComputerUseError.stateUnavailable("Window changed.") }
        }, post: { events.append($0) }, release: { events.append($0) }, pause: { _ in maySend = false }))
        XCTAssertEqual(Array(events.dropFirst().dropLast()).map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(events.dropLast().allSatisfy { $0.flags.contains(.maskShift) })
        XCTAssertFalse(events.last?.flags.contains(.maskShift) ?? true)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [chord.modifiers[0].keyCode, chord.keyCode, chord.keyCode, chord.modifiers[0].keyCode].map(Int64.init))
    }

    func testGestureUsesBoundedZoomAndTabScopedHistoryOrRefuses() throws {
        XCTAssertEqual(try GestureAction(arguments: ["kind": "pinch_out"]).zoomTarget(from: 2), 2.5)
        XCTAssertEqual(GestureAction.pinchIn.zoomTarget(from: 1), 1)
        XCTAssertEqual(GestureAction.zoomIn.zoomTarget(from: 4.8), 5)
        XCTAssertTrue(GestureAction.zoomWasVerified(before: 2, target: 2.5, after: 2.499))
        XCTAssertFalse(GestureAction.zoomWasVerified(before: 2, target: 2.5, after: 2))
        XCTAssertNil(GestureAction.rotateLeft.zoomTarget(from: 2))
        XCTAssertEqual(GestureAction.swipeBack.historyOperation, "back")
        XCTAssertThrowsError(try GestureAction(arguments: ["kind": "swipe"]))

        let steps = try BatchTool.parseSteps([
            ["tool": "gesture", "kind": "rotate_left"],
            ["tool": "gesture", "web": true, "kind": "swipe_back"],
        ], defaultApp: "Fixture")
        XCTAssertEqual(steps.map(\.tool), ["gesture", "browser"])
        let result = ComputerUseToolDispatcher().callToolAsResult(name: "gesture", arguments: steps[0].arguments)
        XCTAssertEqual(result.failureCode, .backgroundUnsupported)
    }

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
