import XCTest
@testable import OpenComputerUseKit

final class RefereeViewTests: XCTestCase {
    func testLateMailCandidateKeepsItsSectionAndNeighbor() {
        let filler = (1...70).map { "\t\($0) row Archive message \($0)" }.joined(separator: "\n")
        let state = """
        Window: "Mail", App: Mail.
        0 standard window Inbox
        \(filler)
        \t71 group Message actions
        \t\t72 static text Project Cedar
        \t\t73 button Move Message
        \t74 group Mailbox actions
        \t\t75 button Move Message
        The focused UI element is subject Project Cedar.
        """
        let options = [75, 73]
        let goal = "Move the Project Cedar message"
        let view = RefereeView.build(state: state, goal: goal, optionIndexes: options)
        XCTAssertEqual(view, RefereeView.build(state: state, goal: goal, optionIndexes: options))
        XCTAssertTrue(view.hasPrefix("Window:"))
        XCTAssertTrue(view.contains("focused UI element"))
        XCTAssertTrue(view.contains("74 group Mailbox actions\n75 button Move Message"))
        XCTAssertTrue(view.contains("71 group Message actions\n72 static text Project Cedar\n73 button Move Message"))
        XCTAssertTrue(view.split(separator: "\n").last?.hasPrefix("Omitted rows:") == true)
        XCTAssertLessThanOrEqual(view.unicodeScalars.count, 1_200)
        XCTAssertFalse(RefereeSummary.screen(from: state).contains("Project Cedar"))
    }

    func testEveryCandidateGetsSpaceOnCrowdedSettingsTree() {
        let options = Array(101...112)
        let state = """
        Window: "Privacy & Security 👩🏽‍💻", App: System Settings.
        0 standard window Privacy & Security
        \t100 group Application access
        """ + "\n" + (101...112).map {
            "\t\t\($0) switch Application \($0) " + String(repeating: "設定", count: 80)
        }.joined(separator: "\n")
        let view = RefereeView.build(state: state, goal: "Inspect Application 112", optionIndexes: options)
        for index in 1...12 { XCTAssertTrue(view.contains("\(100 + index) switch")) }
        XCTAssertLessThanOrEqual(view.unicodeScalars.count, 1_200)
    }

    func testLateFixtureFieldAndWebEvidenceReachDecide() {
        let filler = (1...90).map { "\($0) link Related item \($0)" }.joined(separator: "\n")
        // Same field syntax as the headless calculator and form scenarios.
        let views = [
            ("Window: \"Calculator\", App: Fixture.", "91 text field Result = 42", "Result 42"),
            ("Window: \"Transfers\", App: Finder.", "91 static text Cedar.mov copied", "Cedar.mov copied"),
            ("Page: Export report", "91 textbox Status = File ready", "File ready"),
        ]
        for (title, evidence, doneWhen) in views {
            let state = "\(title)\n\(filler)\n\(evidence)"
            let screen = RefereeView.build(state: state, goal: "Check outcome", doneWhen: doneWhen, limit: 600)
            let summary = RefereeSummary.build(goal: "Check outcome", steps: [], repeatedFailures: 0,
                screenChanged: true, dialogOpen: false, changes: nil, screen: screen)
            XCTAssertTrue(summary.contains(evidence), summary)
            XCTAssertLessThanOrEqual(summary.unicodeScalars.count, 1_200)
        }
    }
}
