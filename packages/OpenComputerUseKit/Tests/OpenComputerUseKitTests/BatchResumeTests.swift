import Foundation
import XCTest
@testable import OpenComputerUseKit

final class BatchResumeTests: XCTestCase {
    private func withJournal(_ body: (OperationJournal) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(OperationJournal(directory: folder))
    }

    /// Step 7 of a batch with a goal: the restart notice says where the unfinished intent was.
    func testRestartNoticeNamesStepAndGoal() throws {
        try withJournal { journal in
            _ = try journal.begin(tool: "click", requestID: UUID(), app: "Notes", step: 7, goal: "Send the report")
            XCTAssertEqual(RestartNoticeState(journal: journal).claim(),
                           "After a restart: click in Notes (step 7 of 'Send the report') may or may not have happened. Read the app before repeating it.")
        }
    }
}
