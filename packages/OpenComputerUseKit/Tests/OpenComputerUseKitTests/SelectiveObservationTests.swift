import AppKit
import XCTest
@testable import OpenComputerUseKit

final class SelectiveObservationTests: XCTestCase {
    private func app(pid: Int32 = 42, name: String = "ObservationFixture") -> RunningAppDescriptor {
        .init(name: name, bundleIdentifier: "test.\(name)", pid: pid, runningApplication: .current)
    }

    private func snapshot(pid: Int32 = 42, name: String = "ObservationFixture",
                          options: SnapshotObservationOptions = .defaults) -> AppSnapshot {
        let state = FixtureAppState(windowTitle: "test", windowBounds: .init(rect: CGRect(x: 0, y: 0, width: 300, height: 200)),
                                    focusedIdentifier: "input", elements: [
            .init(identifier: "input", index: 7, role: "text", title: "Input", value: "中文🙂", actions: [],
                  frame: .init(rect: CGRect(x: 10, y: 10, width: 100, height: 30)))
        ], selectedText: "中文🙂")
        return SnapshotBuilder.buildFixtureSnapshot(app: app(pid: pid, name: name), state: state, observation: options)
    }

    func testNativeActionReadbackRequestsOneAXReadAndZeroScreenshots() throws {
        var reads = 0
        var captures = 0
        let result = try ComputerUseService().actionResult(for: "ObservationFixture") { options in
            reads += 1
            if options.includeScreenshot { captures += 1 }
            return self.snapshot(options: options)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(result.content.filter { $0.dictionary["type"] as? String == "image" }.count, 0)
        XCTAssertTrue(result.textContent.contains("Input"))
    }

    func testFrameSamplingRequiresAnExplicitOptIn() {
        XCTAssertFalse(WindowSettle.frameSamplingEnabled(environment: [:]))
        XCTAssertTrue(WindowSettle.frameSamplingEnabled(environment: ["OPEN_COMPUTER_USE_SETTLE_BY_FRAME": "1"]))
    }

    func testSmartStepsReuseActionReadbackAndRefreshOnNoChange() throws {
        let capture = NativeActionObservation()
        var reads = 0
        let after = snapshot(options: .init(includeScreenshot: false))
        _ = try ComputerUseService.$actionObservation.withValue(capture) {
            try ComputerUseService().actionResult(for: "ObservationFixture") { _ in
                reads += 1
                return after
            }
        }

        func refresh() -> AppSnapshot? {
            reads += 1
            return after
        }
        XCTAssertEqual(capture.read(before: ["earlier state"], fallback: refresh)?.treeLines, after.treeLines)
        XCTAssertEqual(reads, 1)
        XCTAssertNotNil(capture.read(before: after.treeLines, fallback: refresh))
        XCTAssertEqual(reads, 2)
    }

    func testEmptyObservationFailsBeforeResolvingApp() {
        XCTAssertThrowsError(try ComputerUseService().getAppState(app: "missing-test-app",
            observation: .init(includeAX: false, includeScreenshot: false))) {
            XCTAssertTrue(String(describing: $0).contains("At least one"))
        }
    }

    func testDispatcherRequiresActualJSONBooleans() {
        let dispatcher = ComputerUseToolDispatcher()
        for key in ["include_ax", "include_screenshot"] {
            // "false", 0 and 1 are read as booleans on purpose (ArgumentNormalizer forgives weak models).
            for value: Any in [NSNull(), [], [:]] {
                XCTAssertThrowsError(try dispatcher.callTool(name: "get_app_state", arguments: ["app": "missing-test-app", key: value])) {
                    XCTAssertTrue(String(describing: $0).contains("\(key) must be a boolean"))
                }
            }
        }
    }

    func testSchemaHasMatchingFullDefaults() throws {
        let tool = try XCTUnwrap(ToolDefinitions.all.first { $0.name == "get_app_state" })
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        for (key, expected) in [("include_ax", true), ("include_screenshot", LeanDefaults.includeScreenshot)] {
            let value = try XCTUnwrap(properties[key] as? [String: Any])
            XCTAssertEqual(value["type"] as? String, "boolean")
            XCTAssertEqual(value["default"] as? Bool, expected)
        }
    }

    func testCLIObservationOptionsAndDefaultCompatibility() throws {
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit"]), .snapshot(app: "TextEdit"))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["snapshot", "--include-screenshot", "false", "TextEdit"]),
                       .snapshot(app: "TextEdit", observation: .init(includeScreenshot: false)))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit", "--include-ax", "FALSE"]),
                       .snapshot(app: "TextEdit", observation: .init(includeAX: false)))
        for args in [["--include-ax"], ["--include-screenshot", "0"], ["--include-ax", "no"],
                     ["--include-ax", "false", "--include-screenshot", "false"]] {
            XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit"] + args))
        }
    }

    func testFixtureChannelsPreserveOrOmitAXAndCoordinateGuidance() {
        let full = snapshot()
        XCTAssertEqual(full.selectedText, "中文🙂")
        XCTAssertEqual(full.elements.count, 1)
        XCTAssertEqual(full.elements[7]?.title, "Input")
        XCTAssertEqual(full.elements[7]?.value, "中文🙂")
        let image = snapshot(options: .init(includeAX: false))
        XCTAssertTrue(image.elements.isEmpty)
        XCTAssertTrue(image.treeLines.isEmpty)
        XCTAssertNil(image.focusedSummary)
        XCTAssertNil(image.selectedText)
        XCTAssertTrue(image.renderedText.contains("indexes invalidated"))
        let ax = snapshot(options: .init(includeScreenshot: false))
        XCTAssertEqual(ax.elements.count, 1)
        XCTAssertEqual(ax.selectedText, "中文🙂")
        XCTAssertNil(ax.screenshotData)
        XCTAssertEqual(ax.screenshotNote, SnapshotObservationOptions.screenshotOmittedNote)
    }

    func testScreenshotOnlyInvalidatesOlderAliasesAcrossPIDChangeAndAXRestoresIndexes() throws {
        let service = ComputerUseService()
        service.rememberSnapshot(snapshot(), for: "older-query")
        service.rememberSnapshot(snapshot(), for: "ObservationFixture")
        service.rememberSnapshot(snapshot(pid: 99, name: "Other"), for: "Other")
        service.rememberSnapshot(snapshot(pid: 43, options: .init(includeAX: false)), for: "ObservationFixture")
        XCTAssertThrowsError(try service.currentSnapshot(for: "older-query"))
        XCTAssertThrowsError(try service.currentSnapshot(for: "42"))
        XCTAssertTrue(try service.currentSnapshot(for: "ObservationFixture").elements.isEmpty)
        XCTAssertEqual(try service.currentSnapshot(for: "Other").elements.count, 1)
        service.rememberSnapshot(snapshot(pid: 43, options: .init(includeScreenshot: false)), for: "ObservationFixture")
        XCTAssertEqual(try service.currentSnapshot(for: "ObservationFixture").elements.count, 1)
    }

    func testQueryIndexInvalidationIsScopedAndNeverReissuesIDs() throws {
        let registry = TargetedElementRegistry<String>()
        let first = TargetedAppIdentity(pid: 42, bundleIdentifier: "a", launchedAt: nil)
        let other = TargetedAppIdentity(pid: 99, bundleIdentifier: "b", launchedAt: nil)
        let a = registry.insert(app: first) { _ in "a" }
        let b = registry.insert(app: other) { _ in "b" }
        registry.removeAll(forPIDs: [42])
        XCTAssertThrowsError(try registry.resolve(a, app: first))
        XCTAssertEqual(try registry.resolve(b, app: other), "b")
        XCTAssertGreaterThan(registry.insert(app: first) { _ in "new" }, b)
    }

    func testAXOnlyRejectsCoordinateInputBeforeAnyFixtureCommand() {
        let service = ComputerUseService()
        service.rememberSnapshot(snapshot(options: .init(includeScreenshot: false)), for: "fixture")
        XCTAssertThrowsError(try service.click(app: "fixture", elementIndex: nil, x: 10, y: 10,
                                              clickCount: 1, mouseButton: "left")) {
            XCTAssertTrue(String(describing: $0).contains("include_screenshot=false"))
        }
        XCTAssertThrowsError(try service.drag(app: "fixture", fromX: 1, fromY: 1, toX: 2, toY: 2)) {
            XCTAssertTrue(String(describing: $0).contains("include_screenshot=false"))
        }
    }
}
