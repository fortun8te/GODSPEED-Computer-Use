import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Tests for the local learning log. They write only into a temporary folder and never touch
/// accessibility, the screen or a running app.
final class LearningLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRowsRoundTripWithMetadata() throws {
        let log = makeLog(runID: "run-1")
        let image = "learning-2026-11-20-123456-789-abcdef12.png"
        XCTAssertTrue(log.append(LearningDecisionRow(
            kind: "choose", app: "com.apple.Notes", view: "Pick one",
            options: [LearningOption(id: "a", text: "Save")], probabilities: ["a": 0.9],
            outcome: "act", latency_ms: 12, model: "d1"
        )))
        XCTAssertTrue(log.append(LearningLocateRow(
            app: "com.apple.Notes", query: "Save button", crop_width: 320, crop_height: 200,
            point: [0.5, 0.25], confidence: 0.8, verified: true, image: image
        )))
        XCTAssertTrue(log.append(LearningStepRow(
            app: "com.apple.Notes", tool: "click", target_role: "AXButton", target_label: "Save",
            delivery_state: "delivered", verification: "changed", done_when: "verified"
        )))
        XCTAssertTrue(log.append(LearningEpisodeRow(app: "com.apple.Notes", goal: "Save note", outcome: "done")))

        let rows = try lines()
        XCTAssertEqual(rows.count, 4)
        let decision = try JSONDecoder().decode(LearningDecisionRow.self, from: Data(rows[0].utf8))
        XCTAssertEqual(decision.kind, "choose")
        XCTAssertEqual(decision.options?.first?.id, "a")
        XCTAssertEqual(decision.probabilities?["a"], 0.9)
        XCTAssertEqual(decision.run_id, "run-1")
        XCTAssertNotNil(decision.ts)
        let locate = try object(rows[1])
        XCTAssertEqual(locate["kind"] as? String, "locate")
        XCTAssertEqual(locate["image"] as? String, image, "Image names are never redacted")
        XCTAssertEqual(locate["verified"] as? Bool, true)
        let step = try JSONDecoder().decode(LearningStepRow.self, from: Data(rows[2].utf8))
        XCTAssertEqual(step.done_when, "verified")
        XCTAssertEqual(try object(rows[3])["kind"] as? String, "episode")
    }

    func testRowsSplitIntoUTCDayFiles() throws {
        XCTAssertTrue(makeLog(at: "2026-11-20T23:59:59Z").append(LearningEpisodeRow(goal: "late")))
        XCTAssertTrue(makeLog(at: "2026-11-21T00:00:01Z").append(LearningEpisodeRow(goal: "early")))
        XCTAssertEqual(try lines(day: "2026-11-20").count, 1)
        XCTAssertEqual(try lines(day: "2026-11-21").count, 1)
    }

    func testSizeCapDeletesOldestDaysFirst() throws {
        let long = String(repeating: "x", count: 1_000)
        for day in ["2026-11-18", "2026-11-19", "2026-11-20"] {
            let log = makeLog(at: "\(day)T10:00:00Z", maxBytes: 3_000)
            XCTAssertTrue(log.append(LearningDecisionRow(view: long)))
            XCTAssertTrue(log.append(LearningDecisionRow(view: long)))
        }
        XCTAssertFalse(exists("learning-2026-11-18.jsonl"), "Oldest day goes first")
        XCTAssertTrue(exists("learning-2026-11-20.jsonl"), "Newest day is kept")
        XCTAssertLessThanOrEqual(try folderBytes(), 3_000)
    }

    func testDisabledLogWritesNothing() {
        let log = LearningLog(directory: directory, enabled: false, imagesEnabled: true)
        XCTAssertFalse(log.append(LearningEpisodeRow(goal: "nothing")))
        XCTAssertNil(log.saveImage(Data([1, 2, 3])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEnvironmentSwitches() {
        XCTAssertTrue(LearningLog.isEnabled(environment: [:]))
        XCTAssertTrue(LearningLog.imagesEnabled(environment: [:]))
        for value in ["0", "false", "no", "off", " OFF "] {
            XCTAssertFalse(LearningLog.isEnabled(environment: [LearningLog.enabledVariable: value]), value)
            XCTAssertFalse(LearningLog.imagesEnabled(environment: [LearningLog.imagesVariable: value]), value)
        }
        XCTAssertTrue(LearningLog.isEnabled(environment: [LearningLog.enabledVariable: "1"]))
    }

    func testSecureFieldDropsLabelAndValues() throws {
        let log = makeLog()
        XCTAssertTrue(log.append(LearningStepRow(
            tool: "type_text", target_role: "AXSecureTextField", target_label: "Enter PIN",
            before: "1234", after: "1234 typed"
        )))
        let text = try lines()[0]
        let step = try object(text)
        XCTAssertNil(step["target_label"])
        XCTAssertNil(step["before"])
        XCTAssertNil(step["after"])
        XCTAssertFalse(text.contains("1234"))
        XCTAssertFalse(text.contains("PIN"))
    }

    func testCodeFieldKeepsLabelAndRedactsValues() throws {
        let log = makeLog()
        XCTAssertTrue(log.append(LearningStepRow(
            tool: "type_text", target_role: "AXTextField", target_label: "Verification code",
            before: "", after: "493021"
        )))
        let step = try object(try lines()[0])
        XCTAssertEqual(step["target_label"] as? String, "Verification code")
        XCTAssertEqual(step["after"] as? String, "[redacted]")
    }

    func testKeysAndLongTokensAreRedacted() {
        XCTAssertEqual(LearningScrubber.clean("key sk-ABCDEFGH12345678 end"), "key [redacted] end")
        XCTAssertEqual(LearningScrubber.clean("ghp_abcdefgh12345678 ok"), "[redacted] ok")
        XCTAssertEqual(LearningScrubber.clean("AKIAIOSFODNN7EXAMPLE"), "[redacted]")
        XCTAssertEqual(LearningScrubber.clean("token abcdefghijklmnopqrstu2345 here"), "token [redacted] here")
        XCTAssertEqual(LearningScrubber.clean("abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnopqrstuvwxyz",
                       "Long words without digits are kept")
        XCTAssertEqual(LearningScrubber.clean("task-description-list"), "task-description-list")
    }

    func testLuhnCardNumbers() {
        XCTAssertEqual(LearningScrubber.clean("Card 4111 1111 1111 1111 ok"), "Card [redacted] ok")
        XCTAssertEqual(LearningScrubber.clean("4111-1111-1111-1111"), "[redacted]")
        XCTAssertEqual(LearningScrubber.clean("4111 1111 1111 1112"), "4111 1111 1111 1112",
                       "Digits that fail Luhn are kept")
        XCTAssertTrue(LearningScrubber.isLuhn("4111111111111111"))
        XCTAssertFalse(LearningScrubber.isLuhn("4111111111111112"))
    }

    func testTextIsClippedToLimit() {
        let clipped = LearningScrubber.clean(String(repeating: "a b ", count: 3_000))
        XCTAssertEqual(clipped.count, LearningScrubber.textLimit)
    }

    func testImagesSaveBesideRowsAndShareTheCap() {
        let first = makeLog(at: "2026-11-20T10:00:00Z", maxBytes: 1_000)
        let oldName = first.saveImage(Data(repeating: 1, count: 600))
        XCTAssertNotNil(oldName)
        XCTAssertTrue(exists(oldName!))
        let second = makeLog(at: "2026-11-20T10:00:01Z", maxBytes: 1_000)
        let newName = second.saveImage(Data(repeating: 2, count: 600))
        XCTAssertNotNil(newName)
        XCTAssertFalse(exists(oldName!), "The oldest image is evicted with the cap")
        XCTAssertTrue(exists(newName!))
    }

    func testImagesOffSavesNothing() {
        let log = LearningLog(directory: directory, enabled: true, imagesEnabled: false)
        XCTAssertNil(log.saveImage(Data([1])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Hook rows (each writes only into the temporary folder)

    private func kinds() throws -> [String] {
        try lines().map { try object($0)["kind"] as? String ?? "" }
    }

    func testRefereeWritesDecideAndChooseRows() throws {
        let log = makeLog()
        let options = [(id: "a", text: "click Save"), (id: "b", text: "click Cancel")]
        Referee.recordDecision(kind: "choose", view: "Save screen", options: options,
                               reply: ["probs": ["a": 0.9, "b": 0.05, "none": 0.05], "model": "d1"],
                               latencyMs: 12, log: log)
        Referee.recordDecision(kind: "choose", view: "Save screen", options: options, reply: nil, latencyMs: 3_000, log: log)
        Referee.recordDecision(kind: "decide", view: "view", options: [], reply: ["label": "done", "confidence": 0.95],
                               latencyMs: 5, log: log)
        Referee.recordDecision(kind: "decide", view: "view", options: [], reply: ["label": "act", "confidence": 0.9],
                               latencyMs: 5, log: log)
        Referee.recordDecision(kind: "decide", view: "view", options: [], reply: ["label": "stuck", "confidence": 0.2],
                               latencyMs: 5, log: log)
        let rows = try lines().map { try object($0) }
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["choose", "choose", "decide", "decide", "decide"])
        XCTAssertEqual(rows.map { $0["outcome"] as? String }, ["act", "timeout", "hint", "act", "abstain"])
        XCTAssertEqual(rows[0]["view"] as? String, "Save screen")
        XCTAssertEqual(rows[0]["model"] as? String, "d1")
        XCTAssertNotNil(rows[0]["probabilities"])
        XCTAssertEqual(rows[2]["label"] as? String, "done")
    }

    func testRefereeDisabledWritesNothing() {
        let log = LearningLog(directory: directory, enabled: false, imagesEnabled: true)
        Referee.recordDecision(kind: "decide", view: "v", options: [], reply: nil, latencyMs: 1, log: log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testVisionLocateRowRecordsEvidenceAndCropImage() throws {
        let crop = try XCTUnwrap(makeImage())
        let log = makeLog()
        VisionFallback.recordLocate(query: "Save", crop: crop,
                                    candidate: VisionFallback.Candidate(fraction: CGPoint(x: 0.5, y: 0.25), evidence: .model),
                                    verified: true, log: log)
        let row = try object(try lines()[0])
        XCTAssertEqual(row["kind"] as? String, "locate")
        XCTAssertEqual(row["evidence"] as? String, "model")
        XCTAssertEqual(row["verified"] as? Bool, true)
        XCTAssertEqual(row["point"] as? [Double], [0.5, 0.25])
        XCTAssertEqual(row["crop_width"] as? Double, 8)
        let image = try XCTUnwrap(row["image"] as? String)
        XCTAssertTrue(exists(image))
    }

    func testVisionLocateMissStillWritesRowWithoutImageWhenImagesOff() throws {
        let crop = try XCTUnwrap(makeImage())
        let log = LearningLog(directory: directory, enabled: true, imagesEnabled: false, runID: "r", clock: { Date(timeIntervalSince1970: 0) })
        VisionFallback.recordLocate(query: "Save", crop: crop, candidate: nil, verified: false, log: log)
        let row = try object(try lines(day: "1970-01-01")[0])
        XCTAssertEqual(row["kind"] as? String, "locate")
        XCTAssertNil(row["point"])
        XCTAssertNil(row["image"])
        XCTAssertEqual(row["verified"] as? Bool, false)
    }

    func testVisionLocateDisabledWritesNothing() throws {
        let crop = try XCTUnwrap(makeImage())
        VisionFallback.recordLocate(query: "Save", crop: crop, candidate: nil, verified: false,
                                    log: LearningLog(directory: directory, enabled: false, imagesEnabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testBatchWritesStepAndEpisodeRowsWithoutTypedText() throws {
        var receipt = TrajectoryLog.BatchReceipt(totalSteps: 2)
        receipt.steps = [
            .init(),
            .init(failureCode: .staleState, observation: .noEffectSeen, deliveryState: .notSent),
        ]
        receipt.stop = .stepFailure
        receipt.doneCheck = .unmet
        let steps = [
            BatchTool.Step(tool: "click", arguments: ["label": "Save", "app": "Notes"]),
            BatchTool.Step(tool: "type_text", arguments: ["text": "hunter2-secret"]),
        ]
        BatchTool.learn(receipt: receipt, steps: steps, goal: "Save note", app: "Notes", log: makeLog())
        let text = try lines().joined(separator: "\n")
        XCTAssertEqual(try kinds(), ["step", "step", "episode"])
        let rows = try lines().map { try object($0) }
        XCTAssertEqual(rows[0]["target_label"] as? String, "Save")
        XCTAssertEqual(rows[0]["delivery_state"] as? String, "acknowledged")
        XCTAssertNil(rows[0]["done_when"])
        XCTAssertEqual(rows[1]["done_when"] as? String, "unmet", "The check belongs to the last step")
        XCTAssertEqual(rows[1]["verification"] as? String, "no effect seen")
        XCTAssertEqual(rows[2]["outcome"] as? String, "stopped_step_failure")
        XCTAssertFalse(text.contains("hunter2-secret"))
    }

    func testBatchDisabledWritesNothing() {
        BatchTool.learn(receipt: TrajectoryLog.BatchReceipt(totalSteps: 1), steps: [], goal: "g", app: nil,
                        log: LearningLog(directory: directory, enabled: false, imagesEnabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func handoffRequest() -> HandoffTool.Request {
        HandoffTool.Request(app: "x", goal: "Click Export PDF", doneWhen: [.text("Exported")], values: [],
                            maxSteps: 2, timeBudget: 5)
    }

    private func handoffDeps(_ request: HandoffTool.Request) -> HandoffTool.Dependencies {
        let initial = "App=x\nWindow: Export\nWindow ID: 12\n1 button Export PDF"
        return HandoffTool.Dependencies(
            readState: { initial },
            act: { _, _ in .init(ok: true, message: "", delivery: .acknowledged,
                                 observedState: initial + "\n2 static text Exported") },
            choose: { _, _, _, _, _ in nil },
            looksStuck: { _, _, _ in false },
            check: { HandoffTool.check(request.doneWhen, screen: $0) },
            replay: { _ in nil },
            now: { 0 }
        )
    }

    func testHandoffWritesStepAndEpisodeRows() throws {
        let request = handoffRequest()
        let outcome = HandoffTool.run(request, handoffDeps(request), learning: makeLog())
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(try kinds(), ["step", "episode"])
        let rows = try lines().map { try object($0) }
        XCTAssertEqual(rows[0]["delivery_state"] as? String, "acknowledged")
        XCTAssertEqual(rows[1]["goal"] as? String, "Click Export PDF")
    }

    func testHandoffDisabledWritesNothing() {
        let request = handoffRequest()
        _ = HandoffTool.run(request, handoffDeps(request),
                            learning: LearningLog(directory: directory, enabled: false, imagesEnabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// A folder that cannot be created (a file sits at its path) must not change what the tool returns.
    func testLoggingFailureDoesNotChangeToolResult() throws {
        let blocker = directory!
        try Data("not a folder".utf8).write(to: blocker)
        let broken = LearningLog(directory: blocker, enabled: true, imagesEnabled: true, runID: "r")
        XCTAssertFalse(broken.append(LearningEpisodeRow(goal: "probe")), "The blocked log must fail")

        let request = handoffRequest()
        let quiet = HandoffTool.run(request, handoffDeps(request),
                                    learning: LearningLog(directory: blocker, enabled: false, imagesEnabled: false))
        let failing = HandoffTool.run(request, handoffDeps(request), learning: broken)
        XCTAssertEqual(failing.kind, quiet.kind)
        XCTAssertEqual(failing.reply(), quiet.reply())
        XCTAssertEqual(failing.steps, quiet.steps)
    }

    private func makeImage() -> CGImage? {
        CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    private func makeLog(
        at time: String = "2026-11-20T12:00:00Z", runID: String? = "bench-7", maxBytes: UInt64 = LearningLog.defaultMaxBytes
    ) -> LearningLog {
        let date = ISO8601DateFormatter().date(from: time)!
        return LearningLog(directory: directory, maxBytes: maxBytes, enabled: true, imagesEnabled: true,
                           runID: runID, clock: { date })
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private func lines(day: String = "2026-11-20") throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent("learning-\(day).jsonl"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private func object(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func folderBytes() throws -> UInt64 {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return urls.reduce(UInt64(0)) { total, url in
            total + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
