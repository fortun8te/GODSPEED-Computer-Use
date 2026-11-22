import Foundation
import ImageIO
import XCTest
@testable import OpenComputerUseKit

/// Exports production-shaped requests without networking or reading the screen.
final class LocalHelperEvalFixturesTests: XCTestCase {
    private struct Fixtures: Decodable {
        let prefixes: [String: String]
        let cases: [Case]
    }

    private struct Case: Decodable {
        struct Option: Decodable {
            let id: String
            let text: String
            let index: Int?
        }

        let id: String
        let split: String
        let route: String
        let fixture: String
        let tail: String
        let goal: String
        let doneWhen: String
        let expected: String
        let step: String?
        let result: String?
        let failures: Int?
        let options: [Option]?
    }

    private struct Visual: Decodable {
        let id: String
        let image: String
        let query: String
        let box: [Double]?
    }

    func testExportLocalHelperEval() throws {
        guard let output = ProcessInfo.processInfo.environment["GODSPEED_LOCAL_EVAL_OUTPUT"] else {
            throw XCTSkip("Use experiments/LocalHelper/eval.py to export and score the fixtures.")
        }
        let directory = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
            .appendingPathComponent("experiments/LocalHelper/fixtures")
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: directory.appendingPathComponent("trees.json")))
        let familySplits = Dictionary(grouping: fixtures.cases, by: \.fixture)
        XCTAssertTrue(familySplits.values.allSatisfy { Set($0.map(\.split)).count == 1 })
        let decisions: [[String: Any]] = try fixtures.cases.map { row in
            let prefix = try XCTUnwrap(fixtures.prefixes[row.fixture])
            let state = prefix + "\n" + row.tail
            let baseline = RefereeSummary.screen(from: state)
            let options = row.options ?? []
            let step = row.step ?? ""
            let result = row.result ?? ""
            let focused = RefereeView.build(state: state, goal: row.goal, doneWhen: row.route == "choose" ? row.doneWhen : step,
                optionIndexes: options.compactMap(\.index), limit: row.route == "choose" ? 1200 : 600)
            func request(screen: String) -> [String: Any] {
                if row.route == "choose" {
                    return ["screen": screen, "goal": row.goal, "done_when": row.doneWhen, "history": "",
                            "options": options.map { ["id": $0.id, "text": $0.text] }]
                }
                let summary = RefereeSummary.build(goal: row.goal, steps: [(step, result)],
                    repeatedFailures: row.failures ?? 0, screenChanged: row.expected == "done",
                    dialogOpen: RefereeSummary.dialogOpen(in: state), changes: nil, screen: screen)
                return ["view": summary, "goal": row.goal, "result": result, "last_step": step]
            }
            XCTAssertGreaterThan(state.unicodeScalars.count, 1200)
            XCTAssertLessThanOrEqual(focused.unicodeScalars.count, 1200)
            XCTAssertNotEqual(baseline, focused)
            return ["id": row.id, "route": row.route, "split": row.split, "expected": row.expected,
                    "legacy": request(screen: baseline), "focused": request(screen: focused)]
        }

        let screenshots: [[String: Any]]
        if ProcessInfo.processInfo.environment["GODSPEED_LOCAL_EVAL_INCLUDE_SCREENSHOTS"] == "0" {
            screenshots = []
        } else {
            let visuals = try JSONDecoder().decode([Visual].self, from: Data(contentsOf: directory.appendingPathComponent("visual.json")))
            screenshots = try visuals.map { row in
                let bytes = try Data(contentsOf: directory.appendingPathComponent(row.image))
                let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let crop = try XCTUnwrap(LocalWindowImage.downscaled(image))
                let jpeg = try XCTUnwrap(LocalWindowImage.jpeg(crop))
                let started = ProcessInfo.processInfo.systemUptime
                var ambiguous = false
                let candidate = VisionFallback.candidate(scan: { accurate in
                    let scan = LocalOCR.scan(crop, label: row.query, level: accurate ? .accurate : .fast)
                    if case .ambiguous = scan { ambiguous = true }
                    return scan
                }, locate: { nil })
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                var values: [String: Any] = [
                    "id": row.id, "legacy": bytes.base64EncodedString(), "crop": jpeg.base64EncodedString(),
                    "query": row.query, "ocr_ms": elapsed, "ambiguous": ambiguous,
                ]
                values["box"] = row.box
                values["ocr_point"] = candidate.map { [$0.fraction.x, $0.fraction.y] }
                return values
            }
        }

        let data = try JSONSerialization.data(withJSONObject: ["decisions": decisions, "screenshots": screenshots])
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
