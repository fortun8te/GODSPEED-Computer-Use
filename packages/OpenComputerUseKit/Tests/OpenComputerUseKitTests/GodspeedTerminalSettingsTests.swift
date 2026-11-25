import Foundation
import XCTest
@testable import OpenComputerUseKit

final class GodspeedTerminalSettingsTests: XCTestCase {
    private typealias Settings = GodspeedTerminalSettings

    private func item(_ key: String) throws -> Settings.Item {
        try XCTUnwrap(Settings.items.first { $0.key == key })
    }

    func testCLISettingsStayLocal() throws {
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["settings"]), .settings(arguments: []))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["settings", "--show"]), .settings(arguments: ["--show"]))
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["settings", "--unknown"]))
        XCTAssertFalse(shouldUseMacOSAppAgentProxy(command: .settings(arguments: []), proxyDisabled: false,
                                                  appBundleAvailable: true, runningFromLaunchServicesAppInstance: false))
    }

    func testDraftPreservesUnrelatedValuesAndRequiresSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let bytes = Data(#"{"unknown":{"keep":true},"cursor_visible":true}"#.utf8)
        try bytes.write(to: url)
        var draft = try Settings.Draft(url: url)
        try draft.apply(item("cursor_visible"), input: "off")
        try draft.apply(item("cursor_speed"), input: "fast")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try draft.save()
        let reopened = try Settings.Draft(url: url)
        XCTAssertEqual(reopened.values["cursor_visible"] as? Bool, false)
        XCTAssertEqual(reopened.values["cursor_speed"] as? String, "fast")
        XCTAssertEqual((reopened.values["unknown"] as? [String: Bool])?["keep"], true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectsInvalidInputsAndExternalEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        var draft = try Settings.Draft(url: url)
        XCTAssertThrowsError(try draft.apply(item("helper_url"), input: "https://example.com"))
        XCTAssertThrowsError(try draft.apply(item("helper_url"), input: "http://user:password@localhost:8765"))
        XCTAssertThrowsError(try draft.apply(item("cursor_color"), input: "red"))
        try draft.apply(item("gsd1_url"), input: "http://127.0.0.1:8766")
        let external = Data(#"{"cursor_visible":false}"#.utf8)
        try external.write(to: url)
        XCTAssertThrowsError(try draft.save())
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testMenuShowsOverridesWithoutShowingSecrets() {
        let menu = Settings.menu(values: ["helper_url": "http://user:password@localhost:8765"],
                                 environment: ["OPEN_COMPUTER_USE_VISUAL_CURSOR": "0"], dirty: true)
        XCTAssertTrue(menu.contains("unsaved changes"))
        XCTAssertTrue(menu.contains("[env override]"))
        XCTAssertTrue(menu.contains("INTELLIGENCE"))
        XCTAssertFalse(menu.contains("password"))
    }

    func testMalformedSettingsAreNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let bytes = Data("not JSON".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try Settings.Draft(url: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
