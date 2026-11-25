import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Fails when docs/GODSPEED.md states a limit or default that no longer matches the code.
/// Pure file read: no windows, accessibility, network or child processes.
final class DocsDriftTests: XCTestCase {
    private static let guide: String? = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // Tests/OpenComputerUseKitTests/<file> -> repo root
        return try? String(contentsOf: url.appendingPathComponent("docs/GODSPEED.md"), encoding: .utf8)
    }()

    private func guideText() throws -> String {
        try XCTUnwrap(Self.guide, "docs/GODSPEED.md not found next to the package")
    }

    /// Returns the Default column of the settings table row for `variable`.
    private func documentedDefault(_ variable: String) throws -> String {
        let row = try XCTUnwrap(try guideText().split(separator: "\n").first { $0.hasPrefix("| `\(variable)` |") },
                                "docs/GODSPEED.md has no settings row for \(variable)")
        let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return try XCTUnwrap(cells.count > 1 ? cells[1] : nil)
    }

    private func skipIfOverridden(_ variable: String) throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment[variable] != nil, "\(variable) is set in the test environment")
    }

    func testBatchStepLimitMatchesDocs() throws {
        let text = try guideText()
        XCTAssertTrue(text.contains("Up to \(BatchTool.maxSteps) steps in one call"),
                      "Tool table must say the batch limit is \(BatchTool.maxSteps) steps")
        XCTAssertTrue(text.contains("A batch is at most \(BatchTool.maxSteps) steps"),
                      "Limits section must say the batch limit is \(BatchTool.maxSteps) steps")
    }

    func testRefereeDefaultsMatchDocs() throws {
        let doubles: [(String, Double)] = [
            ("OPEN_COMPUTER_USE_REFEREE_DONE_CONFIDENCE", Referee.doneConfidence),
            ("OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE", Referee.minimumConfidence),
            ("OPEN_COMPUTER_USE_REFEREE_TIMEOUT_MS", Referee.timeout * 1000),
            ("OPEN_COMPUTER_USE_REFEREE_MAX_VIEW", Double(Referee.maxViewCharacters)),
        ]
        for (variable, value) in doubles {
            try skipIfOverridden(variable)
            let documented = try documentedDefault(variable)
            let number = try XCTUnwrap(Double(documented), "\(variable) default '\(documented)' is not a number")
            XCTAssertEqual(number, value, accuracy: 1e-9, "docs/GODSPEED.md default for \(variable) drifted from code")
        }
    }

    func testCursorAndHelperDefaultsMatchDocs() throws {
        let cursor = VisualCursorSettings(environment: [:])
        XCTAssertEqual(try documentedDefault("OPEN_COMPUTER_USE_CURSOR_COLOR"), cursor.automaticTint ? "auto" : "default")
        XCTAssertEqual(Double(try documentedDefault("OPEN_COMPUTER_USE_CURSOR_IDLE_HIDE_SECONDS")), Double(cursor.idleHideDelay))
        XCTAssertEqual(try documentedDefault("OPEN_COMPUTER_USE_CURSOR_FEEDBACK"), cursor.feedbackEnabled ? "on" : "off")
        XCTAssertEqual(try documentedDefault("OPEN_COMPUTER_USE_CURSOR_LABEL"), cursor.labelEnabled ? "on" : "off")
        XCTAssertEqual(try documentedDefault("OPEN_COMPUTER_USE_MODEL_HELPERS"), ModelHelperPolicy.isEnabled(environment: [:]) ? "on" : "off")
        XCTAssertEqual(try documentedDefault("OPEN_COMPUTER_USE_LEARNING_LOG_IMAGES"), LearningLog.imagesEnabled(environment: [:]) ? "on" : "off")
    }
}
