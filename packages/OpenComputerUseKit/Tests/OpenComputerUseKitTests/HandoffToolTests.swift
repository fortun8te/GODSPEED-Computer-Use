import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Candidate building, the decision rule and the loop, with a fake referee and a fake app. No window,
/// no accessibility, no network, no model.
final class HandoffToolTests: XCTestCase {
    private let form = """
    App=com.example.Notes (pid 1)
    Window: "New contact", App: Notes.
    [w=settable]
    \t1 text field Name = (w:str)
    \t2 text field Email = (w:str)
    \t3 button Save
    \t4 button (disabled, w:float) Share
    \t5 button Delete contact
    \t6 button Help
    \t7 scroll area Secondary Actions: Scroll Up, Scroll Down
    """

    private func controls() -> [HandoffTool.Control] { HandoffTool.parseControls(form) }

    private func build(
        goal: String = "Save a contact named Ann",
        values: [(key: String, value: String)] = [("Name", "Ann")],
        tried: Set<String> = [], typed: Bool = false, scrolls: Int = 0, state: [HandoffTool.Control]? = nil
    ) -> [HandoffTool.Candidate] {
        HandoffTool.candidates(goal: goal, doneSummary: "\"Saved\" is on screen", values: values,
                               controls: state ?? controls(), tried: tried, typedAny: typed, scrollsDone: scrolls)
    }

    // MARK: Parsing

    func testParsesControls() {
        let found = controls()
        XCTAssertEqual(found.map(\.index), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(found[0].role, "text field")
        XCTAssertEqual(found[0].label, "Name")
        XCTAssertTrue(found[3].disabled)
        XCTAssertEqual(found[3].label, "Share")
        XCTAssertEqual(found[6].role, "scroll area")
        let filled = HandoffTool.parseControls("\t2 text field To = a@x.com (w:str)")
        XCTAssertEqual(filled.first?.value, "a@x.com")
    }

    func testParsesRequestAndCaps() throws {
        let request = try HandoffTool.parse([
            "app": "Notes", "goal": "g", "done_when": ["text": "Saved"],
            "values": ["Name": "Ann", "Email": "a@x.com"], "max_steps": 99, "time_budget_s": 1000,
        ])
        XCTAssertEqual(request.maxSteps, 30)
        XCTAssertEqual(request.timeBudget, 300)
        XCTAssertEqual(request.values.map(\.key), ["Email", "Name"])
        let defaults = try HandoffTool.parse(["app": "Notes", "goal": "g", "done_when": ["text": "x"]])
        XCTAssertEqual(defaults.maxSteps, 15)
        XCTAssertEqual(defaults.timeBudget, 60)
        XCTAssertThrowsError(try HandoffTool.parse(["app": "Notes", "goal": "g"]))
        XCTAssertThrowsError(try HandoffTool.parse(["goal": "g", "done_when": ["text": "x"]]))
    }

    // MARK: Candidates

    func testCandidatesTypeValueIntoMatchingFieldAndOfferSave() {
        let found = build()
        XCTAssertEqual(found.first?.kind, .setValue)
        XCTAssertEqual(found.first?.arguments["element_index"] as? String, "1")
        XCTAssertEqual(found.first?.arguments["value"] as? String, "Ann")
        XCTAssertTrue(found.contains { $0.text == "click \"Save\"" })
        XCTAssertFalse(found.contains { $0.text.contains("Share") }, "disabled controls are not offered")
        XCTAssertFalse(found.contains { $0.text.contains("Help") }, "unrelated controls are not offered")
    }

    func testRiskyControlOnlyWhenGoalNamesIt() {
        XCTAssertFalse(build().contains { $0.text.contains("Delete") })
        let named = build(goal: "Delete the contact named Ann", values: [])
        let delete = named.first { $0.text.contains("Delete") }
        XCTAssertEqual(delete?.risky, true)
    }

    func testReturnAndScrollAndTried() {
        XCTAssertFalse(build().contains { $0.kind == .pressReturn })
        XCTAssertTrue(build(typed: true).contains { $0.kind == .pressReturn })
        XCTAssertTrue(build().contains { $0.kind == .scroll })
        XCTAssertFalse(build(scrolls: 3).contains { $0.kind == .scroll })
        let all = build()
        let save = all.first { $0.text == "click \"Save\"" }!
        XCTAssertFalse(build(tried: [save.key]).contains { $0.key == save.key })
    }

    func testSkipsValueAlreadyInField() {
        let filled = HandoffTool.parseControls("\t1 text field Name = Ann (w:str)\n\t3 button Save")
        XCTAssertFalse(build(state: filled).contains { $0.kind == .setValue })
    }

    func testCapsAtTwelveAndIdsAreUnique() {
        let many = (1...30).map { "\t\($0) button Save item \($0)" }.joined(separator: "\n")
        let found = build(goal: "Save an item", values: [], state: HandoffTool.parseControls(many))
        XCTAssertEqual(found.count, 12)
        XCTAssertEqual(Set(found.map(\.id)).count, 12)
    }

    func testRiskWords() {
        for label in ["Delete", "Send message", "Buy now", "Pay", "Submit order", "Remove item"] {
            XCTAssertTrue(HandoffTool.isRisky(label: label), label)
        }
        XCTAssertFalse(HandoffTool.isRisky(label: "Save"))
    }

    // MARK: Decision rule

    private func fakeCandidates() -> [HandoffTool.Candidate] { build() }

    func testActsOnClearWinner() {
        let cands = fakeCandidates()
        let probs = [cands[0].id: 0.8, cands[1].id: 0.1, "none": 0.05]
        guard case .act(let chosen, let p) = HandoffTool.decide(candidates: cands, probabilities: probs) else { return XCTFail() }
        XCTAssertEqual(chosen.id, cands[0].id)
        XCTAssertEqual(p, 0.8, accuracy: 0.001)
    }

    func testEscalatesBelowProbabilityOrMargin() {
        let cands = fakeCandidates()
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.55, "none": 0.1]) { XCTFail("0.55 is under 0.6") }
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.65, cands[1].id: 0.5]) { XCTFail("margin 0.15") }
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.7, "none": 0.6]) { XCTFail("none is close") }
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.3, "none": 0.7]) { XCTFail("none wins") }
        guard case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.8, cands[1].id: 0.6]) else { return XCTFail("margin 0.2 is enough") }
    }

    func testEscalatesWithoutRefereeOrCandidatesOrOnRisk() {
        let cands = fakeCandidates()
        if case .act = HandoffTool.decide(candidates: cands, probabilities: nil) { XCTFail() }
        if case .act = HandoffTool.decide(candidates: [], probabilities: ["a": 1]) { XCTFail() }
        let risky = build(goal: "Delete the contact", values: []).first { $0.risky }!
        if case .act = HandoffTool.decide(candidates: [risky], probabilities: [risky.id: 0.99]) { XCTFail("risky never acts") }
    }

    // MARK: The loop

    /// A tiny fake app: typing sets Name, Save shows "Saved".
    private final class FakeApp {
        var name = ""
        var saved = false
        var clock = Date(timeIntervalSince1970: 0)
        var acts: [String] = []
        var chooseCalls = 0

        var state: String {
            """
            App=x
            Window: "w"
            \t1 text field Name = \(name) (w:str)
            \t3 button Save
            \t5 button Delete contact
            \(saved ? "\t9 static text Saved" : "")
            """
        }

        func deps(choose: @escaping ([(id: String, text: String)]) -> [String: Double]?, stuck: Bool = false,
                  replay: Bool? = nil, stepSeconds: TimeInterval = 0, changes: Bool = true) -> HandoffTool.Dependencies {
            HandoffTool.Dependencies(
                readState: { self.state },
                act: { candidate, _ in
                    self.acts.append(candidate.text)
                    self.clock.addTimeInterval(stepSeconds)
                    if changes {
                        if candidate.kind == .setValue { self.name = candidate.arguments["value"] as! String }
                        if candidate.text == "click \"Save\"" { self.saved = true }
                    }
                    return HandoffTool.ActResult(ok: true, message: "")
                },
                choose: { _, _, _, _, options in self.chooseCalls += 1; return choose(options) },
                looksStuck: { _, _, _ in stuck },
                check: { state in
                    DoneCheck.check([.text("Saved")], evidence: DoneCheck.Evidence(screenText: state, pageURL: { nil }))
                },
                replay: { replay },
                now: { self.clock }
            )
        }
    }

    private func request(maxSteps: Int = 15, budget: TimeInterval = 60, goal: String = "Save a contact named Ann") -> HandoffTool.Request {
        HandoffTool.Request(app: "x", goal: goal, doneWhen: [.text("Saved")], values: [("Name", "Ann")],
                            maxSteps: maxSteps, timeBudget: budget)
    }

    /// Picks the option whose text contains `needle` with 0.9, the rest low.
    private func pick(_ needles: [String]) -> ([(id: String, text: String)]) -> [String: Double]? {
        { options in
            var probs = ["none": 0.02]
            for option in options { probs[option.id] = 0.03 }
            if let hit = needles.compactMap({ needle in options.first { $0.text.contains(needle) } }).first { probs[hit.id] = 0.9 }
            return probs
        }
    }

    func testRunsToDone() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: { options in
            // type first, then Save
            let pickText = app.name.isEmpty ? "type" : "click \"Save\""
            return self.pick([pickText])(options)
        }))
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(app.acts, ["type \"Ann\" into \"Name\"", "click \"Save\""])
        XCTAssertEqual(outcome.steps.count, 2)
        XCTAssertTrue(outcome.reply().hasPrefix("Done:"))
        XCTAssertTrue(outcome.reply().contains("Changes:"))
    }

    func testAlreadyDoneTakesNoSteps() {
        let app = FakeApp()
        app.saved = true
        let outcome = HandoffTool.run(request(), app.deps(choose: { _ in nil }))
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertTrue(app.acts.isEmpty)
    }

    func testEscalatesWhenUnsureWithTopOptions() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: { options in
            var probs = ["none": 0.1]
            for (i, option) in options.enumerated() { probs[option.id] = 0.3 - Double(i) * 0.01 }
            return probs
        }))
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertTrue(app.acts.isEmpty)
        XCTAssertFalse(outcome.options.isEmpty)
        XCTAssertTrue(outcome.reply().contains("Top options"))
    }

    func testEscalatesWhenRefereeDown() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: { _ in nil }))
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertEqual(app.chooseCalls, 2, "one retry")
        XCTAssertTrue(app.acts.isEmpty)
    }

    func testRiskyActionEscalatesInsteadOfActing() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(goal: "Delete the contact"), app.deps(choose: pick(["Delete"])))
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertTrue(app.acts.isEmpty)
        XCTAssertTrue(outcome.reason.contains("risky"))
    }

    func testStuckAfterTwoNoChangeSteps() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: pick(["type", "Save", "scroll"]), changes: false))
        XCTAssertEqual(outcome.kind, .stuck)
        XCTAssertLessThanOrEqual(app.acts.count, 3)
    }

    func testStuckFromCheckerModel() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: pick(["type", "Return"]), stuck: true))
        XCTAssertEqual(outcome.kind, .stuck)
        XCTAssertEqual(app.acts.count, 2, "the checker is asked from the second step")
    }

    func testStopsOnTimeBudgetAndStepCap() {
        let slow = FakeApp()
        let timed = HandoffTool.run(request(budget: 5), slow.deps(choose: pick(["type", "scroll"]), stepSeconds: 10))
        XCTAssertEqual(timed.kind, .budget)
        XCTAssertEqual(slow.acts.count, 1)
        let capped = FakeApp()
        let steps = HandoffTool.run(request(maxSteps: 1), capped.deps(choose: pick(["type"])))
        XCTAssertEqual(steps.kind, .budget)
        XCTAssertEqual(capped.acts.count, 1)
    }

    func testReplayedRecipeFinishes() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: { _ in nil }, replay: true))
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(app.chooseCalls, 0)
        let failed = FakeApp()
        let continued = HandoffTool.run(request(), failed.deps(choose: pick(["type", "Save"]), replay: false))
        XCTAssertEqual(continued.kind, .done, "a recipe that did not finish falls back to the loop")
    }

    func testParseChooseReply() {
        XCTAssertEqual(Referee.parseChoose(["probs": ["a": 0.7, "none": 0.1]]) ?? [:], ["a": 0.7, "none": 0.1])
        XCTAssertNil(Referee.parseChoose(["probs": ["a": 7]]))
        XCTAssertNil(Referee.parseChoose([:]))
    }
}
