import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import OpenComputerUseKit

final class GodspeedTerminalSettingsTests: XCTestCase {
    private typealias Settings = GodspeedTerminalSettings

    private func item(_ key: String) throws -> Settings.Item {
        try XCTUnwrap(Settings.items.first { $0.key == key })
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult
    private func interact(_ commands: [String], draft: inout Settings.Draft,
                          beforeInput: ((Int) -> Void)? = nil) -> String {
        var next = 0
        var transcript = ""
        Settings.interact(draft: &draft, environment: ["TERM": "dumb"], terminal: false, input: {
            beforeInput?(next)
            guard next < commands.count else { return nil }
            defer { next += 1 }
            return commands[next]
        }, output: { transcript += $0 })
        return transcript
    }

    func testCLISettingsStayLocal() throws {
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["settings"]), .settings(arguments: []))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["settings", "--show"]), .settings(arguments: ["--show"]))
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["settings", "--unknown"]))
        XCTAssertFalse(shouldUseMacOSAppAgentProxy(command: .settings(arguments: []), proxyDisabled: false,
                                                  appBundleAvailable: true, runningFromLaunchServicesAppInstance: false))
    }

    func testDraftPreservesUnrelatedValuesAndRequiresSave() throws {
        let url = try directory().appendingPathComponent("settings.json")
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
        XCTAssertFalse(draft.changed)
    }

    func testReturningToOriginalValueDoesNotRewriteFile() throws {
        let url = try directory().appendingPathComponent("settings.json")
        let bytes = Data("{ \"cursor_visible\" : true, \"unknown\" : [1, 2] }\n".utf8)
        try bytes.write(to: url)
        var draft = try Settings.Draft(url: url)
        try draft.apply(item("cursor_visible"), input: "off")
        XCTAssertTrue(draft.changed)
        try draft.apply(item("cursor_visible"), input: "on")
        XCTAssertFalse(draft.changed)
        try draft.save()
        XCTAssertEqual(try Data(contentsOf: url), bytes, "A net no-op must preserve original bytes.")
    }

    func testPresetsStageOnlyTheirDeclaredValuesAndNeverEnableModels() throws {
        let url = try directory().appendingPathComponent("settings.json")
        let bytes = Data(#"{"cursor_color":"#2f6fde","gsd1_url":"http://127.0.0.1:18765","unknown":9}"#.utf8)
        try bytes.write(to: url)
        var draft = try Settings.Draft(url: url)
        let preview = try Settings.presetPreview(Settings.presets[0], draft: draft)
        XCTAssertTrue(preview.contains("Model helpers: on → off"))
        XCTAssertFalse(draft.changed)
        try draft.stage(Settings.presets[0])
        try draft.stage(Settings.presets[2])
        try draft.stage(Settings.presets[1])
        XCTAssertEqual(draft.values["model_helpers"] as? Bool, false)
        XCTAssertEqual(draft.values["cursor_color"] as? String, "#2f6fde")
        XCTAssertEqual(draft.values["gsd1_url"] as? String, "http://127.0.0.1:18765")
        XCTAssertEqual(draft.values["unknown"] as? Int, 9)
        XCTAssertEqual(draft.values["cursor_idle_hide_seconds"] as? Double, 2)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Preset application must not write until save.")
    }

    func testPaletteSupportsNamedNumberedAndCustomAccents() throws {
        var draft = try Settings.Draft(url: directory().appendingPathComponent("settings.json"))
        let color = try item("cursor_color")
        XCTAssertEqual(Settings.shown(color, values: [:]), "Auto")
        try draft.apply(color, input: "Violet")
        XCTAssertEqual(draft.values["cursor_color"] as? String, "#8b5cf6")
        try draft.apply(color, input: "3")
        XCTAssertEqual(Settings.shown(color, values: draft.values), "Blue")
        try draft.apply(color, input: "#ABCDEF")
        XCTAssertEqual(draft.values["cursor_color"] as? String, "#abcdef")
        try draft.apply(color, input: "Graphite")
        XCTAssertEqual(draft.values["cursor_color"] as? String, "default")
        XCTAssertEqual(GodspeedSettings.mappedVariables(from: draft.values)["OPEN_COMPUTER_USE_CURSOR_COLOR"], "default")
        try draft.apply(color, input: "reset")
        XCTAssertFalse(draft.changed)
        XCTAssertThrowsError(try draft.apply(color, input: "red"))
        XCTAssertThrowsError(try draft.apply(color, input: "#abc"))
    }

    func testNamesDurationsAndEndpointValidation() throws {
        var draft = try Settings.Draft(url: directory().appendingPathComponent("settings.json"))
        let name = try item("cursor_name")
        for invalid in ["123", "A\nB", "Michael!", String(repeating: "a", count: 21), "\u{001B}Agent"] {
            XCTAssertThrowsError(try draft.apply(name, input: invalid), invalid)
        }
        try draft.apply(name, input: "Studio 2")
        XCTAssertEqual(draft.values["cursor_name"] as? String, cursorAgentName("Studio 2"))
        try draft.apply(name, input: "auto")
        XCTAssertNil(draft.values["cursor_name"])
        let seconds = try item("cursor_idle_hide_seconds")
        for invalid in ["nan", "inf", "-1", "0", "60.1"] {
            XCTAssertThrowsError(try draft.apply(seconds, input: invalid), invalid)
        }
        try draft.apply(seconds, input: "0.2")
        XCTAssertEqual(draft.values["cursor_idle_hide_seconds"] as? Double, 0.2)
        let endpoint = try item("helper_url")
        for invalid in ["https://example.com", "http://user:password@localhost:8765",
                        "http://localhost:8765?token=secret", "http://localhost:0", "http://localhost:65536"] {
            XCTAssertThrowsError(try draft.apply(endpoint, input: invalid), invalid)
        }
        try draft.apply(endpoint, input: "http://[::1]:8765")
        XCTAssertEqual(draft.values["helper_url"] as? String, "http://[::1]:8765")
    }

    func testEveryMenuControlMapsToAnExistingRuntimeVariable() throws {
        var draft = try Settings.Draft(url: directory().appendingPathComponent("settings.json"))
        for item in Settings.items {
            let input: String
            switch item.kind {
            case .toggle: input = "on"
            case .choice(let options): input = item.key == "browser" ? "on" : options[0]
            case .color: input = "Blue"
            case .endpoint: input = "http://127.0.0.1:8765"
            case .name: input = "Studio"
            case .seconds: input = "2.5"
            }
            try draft.apply(item, input: input)
            if let variable = item.environment {
                XCTAssertNotNil(GodspeedSettings.mappedVariables(from: draft.values)[variable], item.key)
            }
        }
    }

    func testReadOnlySummaryRedactsSecretsAndClearlyMarksOverrides() {
        let summary = Settings.snapshot(values: [
            "helper_url": "http://user:password@localhost:8765",
            "gsd1_url": "http://localhost:18765/private-token",
            "cursor_name": "A\u{001B}[31m\u{202E}B",
            "model_helpers": false,
        ], environment: [
            "OPEN_COMPUTER_USE_VISUAL_CURSOR": "0",
            "OPEN_COMPUTER_USE_MODEL_HELPERS": "1",
            "OPEN_COMPUTER_USE_REFEREE_URL": "http://user:secret@localhost",
        ])
        XCTAssertTrue(summary.contains("read-only"))
        XCTAssertTrue(summary.contains("[env]"))
        XCTAssertTrue(summary.contains("Model helpers"))
        XCTAssertTrue(summary.contains("LOCAL COMPUTE"))
        for secret in ["password", "private-token", "user:secret", "\u{001B}", "\u{202E}"] {
            XCTAssertFalse(summary.contains(secret), secret)
        }
        XCTAssertFalse(summary.contains("[s]"))
        XCTAssertFalse(summary.contains("[q]"))
        XCTAssertFalse(summary.contains("[number]"))
        XCTAssertEqual(Settings.shown(try! item("cursor_visible"), values: ["cursor_visible": 1]), "(invalid)")
        XCTAssertTrue(Settings.hasOverride(try! item("helper_url"), environment: ["OPEN_COMPUTER_USE_HANDOFF_URL": "http://localhost:9"]))
    }

    func testFocusedPagesAndSummaryFitNarrowWidths() {
        for width in [24, 40, 60, 80] {
            let pages = [Settings.menu(values: [:], environment: [:], dirty: false, width: width)]
                + Settings.Section.allCases.map {
                    Settings.menu(values: [:], environment: [:], dirty: true, width: width, section: $0)
                } + [Settings.snapshot(values: ["cursor_name": "長い名前"], environment: ["OPEN_COMPUTER_USE_CURSOR_NAME": "x"], width: width)]
            for page in pages {
                for line in page.split(separator: "\n", omittingEmptySubsequences: false) {
                    XCTAssertLessThanOrEqual(Settings.columns(in: String(line)), width, String(line))
                }
            }
        }
        let cursor = Settings.menu(values: [:], environment: [:], dirty: false, section: .cursor)
        XCTAssertFalse(cursor.contains("Decision hints"))
        XCTAssertLessThanOrEqual(cursor.components(separatedBy: "\n").count, 24)
        XCTAssertLessThanOrEqual(Settings.menu(values: [:], environment: [:], dirty: false).components(separatedBy: "\n").count, 24)
    }

    func testNoColorAndDumbTerminalsStayPlain() {
        XCTAssertTrue(Settings.supportsColor(environment: ["TERM": "xterm-256color"], terminal: true))
        XCTAssertFalse(Settings.supportsColor(environment: ["TERM": "xterm", "NO_COLOR": ""], terminal: true))
        XCTAssertFalse(Settings.supportsColor(environment: ["TERM": "dumb"], terminal: true))
        XCTAssertFalse(Settings.supportsColor(environment: ["TERM": "vt100"], terminal: true))
        XCTAssertFalse(Settings.supportsColor(environment: ["TERM": "xterm"], terminal: false))
        XCTAssertFalse(Settings.palette(width: 80, color: false).contains("\u{001B}"))
        XCTAssertTrue(Settings.palette(width: 80, color: true).contains("\u{001B}[38;2;"))
        XCTAssertTrue(Settings.palette(width: 80, color: false).contains("Graphite"))
    }

    func testInteractiveAccentAndSpeedChoicesSaveOnlyOnCommand() throws {
        let url = try directory().appendingPathComponent("settings.json")
        var draft = try Settings.Draft(url: url)
        let transcript = interact(["1", "2", "4", "3", "3", "s"], draft: &draft) { position in
            if position <= 5 { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        }
        let saved = try Settings.Draft(url: url)
        XCTAssertEqual(saved.values["cursor_color"] as? String, "#8b5cf6")
        XCTAssertEqual(saved.values["cursor_speed"] as? String, "fast")
        XCTAssertTrue(transcript.contains("Violet"))
        XCTAssertTrue(transcript.contains("Settings saved"))
        XCTAssertFalse(transcript.contains("\u{001B}"))
    }

    func testInteractiveResetUndoAndCancelledEditPreserveOriginalBytes() throws {
        let url = try directory().appendingPathComponent("settings.json")
        let bytes = Data(#"{"cursor_color":"#2f6fde","cursor_speed":"fast","unknown":7}"#.utf8)
        try bytes.write(to: url)
        var draft = try Settings.Draft(url: url)
        let transcript = interact(["1", "2", "r", "r", "b", "u", "1", "2", "", "q"], draft: &draft)
        XCTAssertFalse(draft.changed)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(transcript.contains("Edits undone"))
    }

    func testPresetPreviewCancelAndEOFNeverSave() throws {
        let url = try directory().appendingPathComponent("settings.json")
        var draft = try Settings.Draft(url: url)
        interact(["5", "1", "b", "q"], draft: &draft)
        XCTAssertFalse(draft.changed)
        let transcript = interact(["5", "1", "a"], draft: &draft)
        XCTAssertEqual(draft.values["model_helpers"] as? Bool, false)
        XCTAssertTrue(transcript.contains("Unsaved changes discarded"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDirtyQuitCanContinueDiscardOrSave() throws {
        let url = try directory().appendingPathComponent("settings.json")
        var draft = try Settings.Draft(url: url)
        let transcript = interact(["1", "2", "3", "q", "", "q", "d"], draft: &draft)
        XCTAssertTrue(transcript.contains("[Enter] keep editing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        draft.undo()
        interact(["1", "2", "3", "q", "s"], draft: &draft)
        XCTAssertEqual(try Settings.Draft(url: url).values["cursor_color"] as? String, "#2f6fde")
    }

    func testInteractiveConflictKeepsExternalFileAndReturnsToMenu() throws {
        let url = try directory().appendingPathComponent("settings.json")
        let external = Data(#"{"another_editor":true}"#.utf8)
        var draft = try Settings.Draft(url: url)
        let transcript = interact(["1", "2", "3", "s", "q", "d"], draft: &draft) { position in
            if position == 3 { try! external.write(to: url) }
        }
        XCTAssertTrue(transcript.contains("Settings changed on disk"))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testConcurrentDraftAndSaveLockCannotLoseAnotherEdit() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("settings.json")
        var first = try Settings.Draft(url: url)
        var second = try Settings.Draft(url: url)
        try first.apply(item("cursor_speed"), input: "fast")
        try second.apply(item("cursor_color"), input: "Blue")
        try first.save()
        XCTAssertThrowsError(try second.save())
        XCTAssertNil(try Settings.Draft(url: url).values["cursor_color"])

        var third = try Settings.Draft(url: url)
        try third.apply(item("cursor_speed"), input: "calm")
        let descriptor = open(folder.appendingPathComponent(".settings.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try third.save())
        XCTAssertEqual(try Settings.Draft(url: url).values["cursor_speed"] as? String, "fast")
    }

    func testMalformedOrSymlinkedSettingsAreNotOverwritten() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("settings.json")
        let bytes = Data("not JSON".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try Settings.Draft(url: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let alias = folder.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        XCTAssertThrowsError(try Settings.Draft(url: alias))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
