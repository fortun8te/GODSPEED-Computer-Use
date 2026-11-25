import Foundation
import XCTest
@testable import OpenComputerUseKit

final class GodspeedSettingsTests: XCTestCase {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("settings.json"))
    }

    func testPreferencesReachTheirRuntimeVariables() {
        let variables = GodspeedSettings.mappedVariables(from: [
            "model_helpers": false, "handoff_helper": false, "cursor_motion": "reduced",
            "cursor_feedback": false, "cursor_label": false, "cursor_float": true,
            "cursor_name": "Michael", "cursor_idle_hide_seconds": 2.5,
            "background_only": true, "batch_diff": false, "semantic_replies": false,
            "learning_log": false, "learning_log_images": true, "trajectory_log": false, "debug_timing": true,
        ])
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_MODEL_HELPERS"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_HANDOFF_HELPER"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_CURSOR_MOTION"], "reduced")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_CURSOR_FEEDBACK"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_CURSOR_LABEL"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_CURSOR_FLOAT"], "1")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_CURSOR_NAME"], "Michael")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS"], "2.5")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_BACKGROUND_ONLY"], "1")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_BATCH_DIFF"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_SEMANTIC_REPLIES"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_LEARNING_LOG"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_LEARNING_LOG_IMAGES"], "1")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_TRAJECTORY_LOG"], "0")
        XCTAssertEqual(variables["OPEN_COMPUTER_USE_DEBUG_TIMING"], "1")
    }

    func testNumericJSONDoesNotEnableBooleanSettingsOrUseBooleanAsSpeed() throws {
        let data = Data(#"{"model_helpers":1,"background_only":0,"decision_hints":1,"cursor_speed":true,"cursor_idle_hide_seconds":true}"#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(GodspeedSettings.mappedVariables(from: object).isEmpty)
        for value in [Double.nan, Double.infinity, -1, 0] {
            XCTAssertNil(GodspeedSettings.mappedVariables(from: ["cursor_speed": value])["OPEN_COMPUTER_USE_CURSOR_SPEED"])
        }
    }

    func testEnvironmentOverridesPreferencesIncludingExplicitEmptyValues() {
        let merged = GodspeedSettings.merged(
            ["OPEN_COMPUTER_USE_MODEL_HELPERS": "0", "OPEN_COMPUTER_USE_CURSOR_NAME": ""],
            settings: ["model_helpers": true, "cursor_name": "Work", "cursor_motion": "reduced"])
        XCTAssertEqual(merged["OPEN_COMPUTER_USE_MODEL_HELPERS"], "0")
        XCTAssertEqual(merged["OPEN_COMPUTER_USE_CURSOR_NAME"], "")
        XCTAssertEqual(merged["OPEN_COMPUTER_USE_CURSOR_MOTION"], "reduced")
    }

    func testCustomHelperRoutesHandoffWithoutEnablingHintsAndRespectsClientEndpoint() {
        let settings: [String: Any] = ["helper_url": "http://127.0.0.1:9000", "decision_hints": false]
        let mapped = GodspeedSettings.mappedVariables(from: settings)
        XCTAssertEqual(mapped["OPEN_COMPUTER_USE_HANDOFF_URL"], "http://127.0.0.1:9000")
        XCTAssertNil(mapped["OPEN_COMPUTER_USE_REFEREE_URL"])
        XCTAssertNil(mapped["OPEN_COMPUTER_USE_VISION_URL"])
        let client = GodspeedSettings.merged(["OPEN_COMPUTER_USE_REFEREE_URL": "http://localhost:9001"], settings: settings)
        XCTAssertNil(client["OPEN_COMPUTER_USE_HANDOFF_URL"])
        XCTAssertEqual(client["OPEN_COMPUTER_USE_REFEREE_URL"], "http://localhost:9001")
        let explicit = GodspeedSettings.merged(["OPEN_COMPUTER_USE_HANDOFF_URL": "http://localhost:9002"], settings: settings)
        XCTAssertEqual(explicit["OPEN_COMPUTER_USE_HANDOFF_URL"], "http://localhost:9002")
    }

    func testCacheDetectsAtomicReplacementWithSameDateAndSize() throws {
        try withFile { url in
            var now: TimeInterval = 0
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            try Data(#"{"cursor_color":"#123456"}"#.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
            let cache = SettingsFileCache(url: url, clock: { now })
            XCTAssertEqual(cache.load()["cursor_color"] as? String, "#123456")
            try Data(#"{"cursor_color":"#abcdef"}"#.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
            now = 1
            XCTAssertEqual(cache.load()["cursor_color"] as? String, "#abcdef")
        }
    }

    func testCacheKeepsLastValidPreferencesDuringPartialWriteThenRecovers() throws {
        try withFile { url in
            var now: TimeInterval = 0
            try Data(#"{"model_helpers":false}"#.utf8).write(to: url)
            let cache = SettingsFileCache(url: url, clock: { now })
            XCTAssertEqual(cache.load()["model_helpers"] as? Bool, false)
            try Data("{unfinished".utf8).write(to: url)
            now = 1
            XCTAssertEqual(cache.load()["model_helpers"] as? Bool, false)
            try Data(#"{"model_helpers":true}"#.utf8).write(to: url)
            now = 2
            XCTAssertEqual(cache.load()["model_helpers"] as? Bool, true)
            try FileManager.default.removeItem(at: url)
            now = 3
            XCTAssertTrue(cache.load().isEmpty)
        }
    }

    func testOversizedSettingsDoNotReplaceLastValidValues() throws {
        try withFile { url in
            var now: TimeInterval = 0
            try Data(#"{"model_helpers":false}"#.utf8).write(to: url)
            let cache = SettingsFileCache(url: url, clock: { now })
            XCTAssertEqual(cache.load()["model_helpers"] as? Bool, false)
            try Data(repeating: 32, count: 1_048_577).write(to: url)
            now = 1
            XCTAssertEqual(cache.load()["model_helpers"] as? Bool, false)
        }
    }

    func testLiveLearningPreferenceFollowsEachRequestWithoutRecreatingLog() throws {
        try withFile { url in
            let log = LearningLog(directory: url.deletingLastPathComponent(), enabled: true,
                                  imagesEnabled: true, followsSettings: true)
            RequestConfiguration.withEnvironment([
                LearningLog.enabledVariable: "0", LearningLog.imagesVariable: "1",
            ]) {
                XCTAssertFalse(log.isEnabled)
                XCTAssertFalse(log.append(LearningEpisodeRow(goal: "not stored")))
                XCTAssertNil(log.saveImage(Data([1, 2, 3])))
            }
            RequestConfiguration.withEnvironment([
                LearningLog.enabledVariable: "1", LearningLog.imagesVariable: "0",
            ]) {
                XCTAssertTrue(log.isEnabled)
                XCTAssertFalse(log.imagesEnabled)
                XCTAssertNil(log.saveImage(Data([1, 2, 3])))
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            XCTAssertTrue(files.isEmpty)
        }
    }
}
