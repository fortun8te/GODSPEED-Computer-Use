import Darwin
import XCTest
@testable import OpenComputerUseKit

final class OperationJournalTests: XCTestCase {
    private func withJournal(_ body: (OperationJournal) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(OperationJournal(directory: folder))
    }

    func testBatchJournalsEveryWriteWithoutStoringArguments() throws {
        try withJournal { journal in
            let reply = try OperationJournal.withRecording(journal) {
                try ClientScope.with("journal-test") {
                    try ComputerUseToolDispatcher(service: ComputerUseService()).runBatch(arguments: [
                        "steps": [["tool": "clipboard", "action": "write", "text": "test-secret-one"],
                                  ["tool": "clipboard", "action": "write", "text": "test-secret-two"],
                                  ["tool": "clipboard", "action": "read"]],
                    ])
                }
            }
            XCTAssertFalse(reply.isError, reply.textContent)
            let entries = try journal.recoveredEntries()
            XCTAssertEqual(entries.map(\.tool), ["clipboard", "clipboard"])
            XCTAssertEqual(entries.map(\.state), [.acknowledged, .acknowledged])
            XCTAssertEqual(Set(entries.map(\.requestID)).count, 1)
            let file = journal.directory.appendingPathComponent("operations.jsonl")
            let raw = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(raw.contains("test-secret"))
            XCTAssertEqual(raw.split(separator: "\n").count, 4)
        }
    }

    func testTimeoutAfterEffectRecordsUnknownAndRunsOnce() throws {
        try withJournal { journal in
            var sends = 0
            XCTAssertThrowsError(try journal.record(tool: "click", requestID: UUID()) {
                XCTAssertEqual(try journal.recoveredEntries().map(\.phase), [.intent])
                sends += 1
                throw ComputerUseError.stateUnavailable("reply timed out")
            })
            let recovered = try OperationJournal(directory: journal.directory).recoveredEntries()
            XCTAssertEqual(recovered.map(\.phase), [.outcome])
            XCTAssertEqual(recovered.map(\.state), [.outcomeUnknown])
            XCTAssertEqual(sends, 1)
        }
    }

    func testNoDeliveryWhenIntentCannotBeWritten() throws {
        try withJournal { journal in
            try Data().write(to: journal.directory)
            XCTAssertThrowsError(try journal.record(tool: "click", requestID: UUID()) {
                XCTFail("a write without a durable intent must never be sent")
                return .text("unexpected")
            })
        }
    }

    func testKilledWriterIsRecoveredAsUnknownWithoutReplay() throws {
        try withJournal { journal in
            let fixture = Process()
            fixture.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            fixture.arguments = ["xctest", "-XCTest", "OpenComputerUseKitTests.OperationJournalTests/testJournalChildFixture",
                                 Bundle(for: Self.self).bundleURL.path]
            fixture.environment = ProcessInfo.processInfo.environment.merging([
                "GODSPEED_L6_JOURNAL_FIXTURE_DIRECTORY": journal.directory.path,
            ]) { _, fixture in fixture }
            fixture.standardOutput = FileHandle.nullDevice
            fixture.standardError = FileHandle.nullDevice
            try fixture.run()
            defer { if fixture.isRunning { kill(fixture.processIdentifier, SIGKILL); fixture.waitUntilExit() } }
            let effect = journal.directory.appendingPathComponent("delivered")
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !FileManager.default.fileExists(atPath: effect.path), fixture.isRunning,
                  ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            XCTAssertTrue(fixture.isRunning)
            XCTAssertTrue(FileManager.default.fileExists(atPath: effect.path))
            guard fixture.isRunning else { return }
            XCTAssertEqual(kill(fixture.processIdentifier, SIGKILL), 0)
            fixture.waitUntilExit()
            let reopened = OperationJournal(directory: journal.directory)
            for _ in 0..<2 {
                let entries = try reopened.recoveredEntries()
                XCTAssertEqual(entries.map(\.phase), [.intent])
                XCTAssertEqual(entries.map(\.state), [.outcomeUnknown])
                XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "delivered once")
            }
        }
    }

    func testJournalChildFixture() throws {
        guard let folder = ProcessInfo.processInfo.environment["GODSPEED_L6_JOURNAL_FIXTURE_DIRECTORY"] else {
            return
        }
        let journal = OperationJournal(directory: URL(fileURLWithPath: folder))
        _ = try journal.record(tool: "click", requestID: UUID()) {
            try Data("delivered once".utf8).write(to: journal.directory.appendingPathComponent("delivered"), options: .atomic)
            // The parent kills this worker after delivery, before it can save an outcome.
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 15)
            return .text("delivered")
        }
    }
}
