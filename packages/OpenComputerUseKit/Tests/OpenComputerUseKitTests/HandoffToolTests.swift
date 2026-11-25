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

    func testRichTreeVisualRetryOnlyForUncertainScores() {
        let ids = ["save", "close"]
        XCTAssertFalse(HandoffTool.needsVisualTieBreak(["save": 0.95, "close": 0.02, "none": 0.03], optionIDs: ids))
        XCTAssertTrue(HandoffTool.needsVisualTieBreak(["save": 0.47, "close": 0.46, "none": 0.07], optionIDs: ids))
        XCTAssertFalse(HandoffTool.needsVisualTieBreak(["save": 0.11, "close": 0.09, "none": 0.80], optionIDs: ids))
        XCTAssertFalse(HandoffTool.needsVisualTieBreak(["save": .nan, "none": 0], optionIDs: ids))
        XCTAssertFalse(HandoffTool.needsVisualTieBreak(["save": 2, "none": 0], optionIDs: ids))
        XCTAssertFalse(HandoffTool.needsVisualTieBreak(["none": 1.0], optionIDs: ids))
    }

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

    func testBoundsModelGeneratedNumbersBeforeConvertingToInt() throws {
        for invalid in ["NaN", "Infinity", "-Infinity"] {
            let request = try HandoffTool.parse([
                "app": "Notes", "goal": "Save", "done_when": ["text": "Saved"],
                "max_steps": invalid, "time_budget_s": invalid,
            ])
            XCTAssertEqual(request.maxSteps, HandoffTool.defaultMaxSteps)
            XCTAssertEqual(request.timeBudget, HandoffTool.defaultTimeBudget)
        }
        let large = try HandoffTool.parse([
            "app": "Notes", "goal": "Save", "done_when": ["text": "Saved"], "max_steps": "1e100",
        ])
        XCTAssertEqual(large.maxSteps, 30)
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

    func testExplicitClickSurvivesMoreThanTwelveLooseFieldMatches() {
        let values = (1...12).map { ("Value \($0)", "entry \($0)") }
        let rows = (1...12).map { "\($0) text field Value \($0) =" } + ["13 button Export PDF"]
        let found = build(goal: "Click Export PDF", values: values, state: HandoffTool.parseControls(rows.joined(separator: "\n")))
        XCTAssertTrue(found.contains { $0.text == "click \"Export PDF\"" })
    }

    func testExactClickUsesNoModel() {
        var acted: [String] = []
        let initial = "App=x\nWindow: Export\nWindow ID: 12\n1 button Export PDF"
        let request = HandoffTool.Request(app: "x", goal: "Click Export PDF", doneWhen: [.text("Exported")],
                                          values: [], maxSteps: 2, timeBudget: 5)
        let deps = HandoffTool.Dependencies(
            readState: { initial },
            act: { action, _ in
                acted.append(action.text)
                return .init(ok: true, message: "", observedState: initial + "\n2 static text Exported")
            },
            choose: { _, _, _, _, _ in XCTFail("exact action called chooser"); return nil },
            check: { HandoffTool.check(request.doneWhen, screen: $0) },
            replay: { _ in XCTFail("exact action tried recipe first"); return nil }, now: { 0 }
        )
        XCTAssertEqual(HandoffTool.run(request, deps).kind, .done)
        XCTAssertEqual(acted, ["click \"Export PDF\""])
    }

    func testChooserUsesOnlyLoopbackReferee() {
        XCTAssertEqual(Referee.localChooseURL(refereeURL: nil, setting: nil)?.host, "127.0.0.1")
        XCTAssertNil(Referee.localChooseURL(refereeURL: URL(string: "https://example.test"), setting: nil))
        XCTAssertNil(Referee.localChooseURL(refereeURL: nil, setting: "0"))
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
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.55, "none": 0.1]) { XCTFail("0.55 is under 0.70") }
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.65, cands[1].id: 0.5]) { XCTFail("margin 0.15") }
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.7, "none": 0.6]) { XCTFail("none is close") }
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.3, "none": 0.7]) { XCTFail("none wins") }
        if case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.8, cands[1].id: 0.6]) {
            XCTFail("margin 0.20 is below 0.35")
        }
        guard case .act = HandoffTool.decide(candidates: cands, probabilities: [cands[0].id: 0.75, "none": 0.25]) else {
            return XCTFail("a high score and clear lead should act")
        }
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
        var email = ""
        var saved = false
        var clock: TimeInterval = 0
        var acts: [String] = []
        var chooseCalls = 0
        var reads = 0

        var state: String {
            """
            App=x
            Window: "w"
            \t1 text field Name = \(name) (w:str)
            \t2 text field Email = \(email) (w:str)
            \t3 button Save
            \t5 button Delete contact
            \t6 button Next
            \(saved ? "\t9 static text Saved" : "")
            """
        }

        func deps(choose: @escaping ([(id: String, text: String)]) -> [String: Double]?,
                  replay: Bool? = nil, stepSeconds: TimeInterval = 0, changes: Bool = true) -> HandoffTool.Dependencies {
            HandoffTool.Dependencies(
                readState: { self.reads += 1; return self.state },
                act: { candidate, _ in
                    self.acts.append(candidate.text)
                    self.clock += stepSeconds
                    if changes {
                        if candidate.kind == .setValue, let value = candidate.arguments["value"] as? String {
                            if candidate.arguments["element_index"] as? String == "2" { self.email = value }
                            else { self.name = value }
                        }
                        if candidate.text == "click \"Save\"" { self.saved = true }
                    }
                    return HandoffTool.ActResult(ok: true, message: "")
                },
                choose: { _, _, _, _, options in self.chooseCalls += 1; return choose(options) },
                check: { state in
                    DoneCheck.check([.text("Saved")], evidence: DoneCheck.Evidence(screenText: state, pageURL: { nil }))
                },
                replay: { _ in replay.map { $0 ? .verified : .incomplete } },
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

    func testGoalAlreadyOnScreenIsWeakAndNeverActs() {
        // "Saved" is already on screen before anything runs: weak evidence, so no action is taken and the
        // caller decides. It must not end as done.
        let app = FakeApp()
        app.saved = true
        let outcome = HandoffTool.run(request(), app.deps(choose: { _ in
            XCTFail("a weak match must not reach the chooser")
            return nil
        }))
        XCTAssertEqual(outcome.kind, .notVerified)
        XCTAssertTrue(outcome.steps.isEmpty)
        XCTAssertTrue(app.acts.isEmpty)
        XCTAssertTrue(outcome.reply().hasPrefix("Not verified:"), outcome.reply())
        XCTAssertTrue(outcome.reply().contains("already satisfied (weak evidence"), outcome.reply())
    }

    func testSavedRecipeReportingWeakEvidenceIsNotDone() {
        let app = FakeApp()
        var deps = app.deps(choose: { _ in XCTFail("no choice after a weak recipe check"); return nil })
        deps.replay = { _ in
            .alreadySatisfied("Already satisfied before replay (weak evidence): Saved. No steps ran.")
        }
        let outcome = HandoffTool.run(request(), deps)
        XCTAssertEqual(outcome.kind, .notVerified)
        XCTAssertTrue(outcome.steps.isEmpty)
        XCTAssertTrue(app.acts.isEmpty)
    }

    func testRunsToDone() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: { options in
            // type first, then Save
            let pickText = app.name.isEmpty ? "fill" : "click \"Save\""
            return self.pick([pickText])(options)
        }))
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(app.acts, ["fill \"Name\"", "click \"Save\""])
        XCTAssertEqual(outcome.steps.count, 2)
        XCTAssertEqual(app.chooseCalls, 2, "ambiguous steps have one local scoring request each")
        XCTAssertTrue(outcome.reply().hasPrefix("Done:"))
        XCTAssertFalse(outcome.reply(compact: true).contains("Changes:"))
    }

    func testLearningLinksChooserToReadbackWithoutStoringScreenContentInOutcome() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = LearningLog(directory: directory, enabled: true, imagesEnabled: false)
        let app = FakeApp()
        let deps = app.deps { options in
            let pickText = app.name.isEmpty ? "fill" : "click \"Save\""
            let scores = self.pick([pickText])(options)!
            Referee.recordDecision(kind: "choose", view: "fixture", options: options,
                                   reply: ["probs": scores], latencyMs: 1, log: log)
            return scores
        }
        XCTAssertEqual(HandoffTool.run(request(), deps, learning: log).kind, .done)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "jsonl" })
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let choices = rows.filter { $0["kind"] as? String == "choose" }
        let results = rows.filter { $0["kind"] as? String == "choice_outcome" }
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.compactMap { $0["readback"] as? String }, ["changed", "goal_verified"])
        let ids = try choices.map { try XCTUnwrap($0["decision_id"] as? String) }
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertTrue(ids.allSatisfy { UUID(uuidString: $0) != nil })
        for (choice, result) in zip(choices, results) {
            XCTAssertEqual(choice["decision_id"] as? String, result["decision_id"] as? String)
            XCTAssertEqual(choice["episode_id"] as? String, result["episode_id"] as? String)
            XCTAssertNotNil(result["selected_option_id"])
            XCTAssertNil(result["view"])
            XCTAssertNil(result["after"])
        }
    }

    func testFillsAnExplicitTwoFieldGoalWithoutCallingTheLocalChecker() {
        let app = FakeApp()
        let conditions: [DoneCheck.Condition] = [.field(label: "Name", equals: "Ann"), .field(label: "Email", equals: "a@example.test")]
        let request = HandoffTool.Request(app: "x", goal: "Fill contact fields", doneWhen: conditions,
                                          values: [("Name", "Ann"), ("Email", "a@example.test")],
                                          maxSteps: 5, timeBudget: 10)
        var deps = app.deps(choose: { _ in nil })
        deps.check = { HandoffTool.check(conditions, screen: $0) }
        let result = HandoffTool.run(request, deps)
        XCTAssertEqual(result.kind, .done)
        XCTAssertEqual(app.acts.count, 2)
        XCTAssertEqual(app.chooseCalls, 0)
        XCTAssertEqual(app.reads, 3)
    }

    func testExplicitFormWorkflowUsesRulesForInputsAndFinalClick() {
        let app = FakeApp()
        let request = HandoffTool.Request(app: "x", goal: "Click Save", doneWhen: [.text("Saved")],
                                          values: [("Name", "Ann"), ("Email", "ann@example.test")],
                                          maxSteps: 5, timeBudget: 10)
        let outcome = HandoffTool.run(request, app.deps(choose: { _ in
            XCTFail("a fully specified form must not need a chooser")
            return nil
        }))
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(app.acts, ["fill \"Name\"", "fill \"Email\"", "click \"Save\""])
        XCTAssertEqual(outcome.ruleActions, 3)
        XCTAssertEqual(outcome.chooserCalls, 0)
    }

    func testTypedFormDoesNotOverwriteOrSubmitOnMissingField() {
        for initialName in ["", "Existing"] {
            let app = FakeApp()
            app.name = initialName
            let request = HandoffTool.Request(app: "x", goal: "Click Save", doneWhen: [.text("Saved")],
                                              values: [("Name", "Ann"), ("Missing field", "X")],
                                              maxSteps: 5, timeBudget: 10)
            let outcome = HandoffTool.run(request, app.deps(choose: { _ in
                XCTFail("invalid typed form must not be handed to the ranker")
                return nil
            }, replay: true))
            XCTAssertEqual(outcome.kind, .escalate)
            XCTAssertTrue(app.acts.isEmpty)
        }
    }

    func testTypedFormWillNotContinueAcrossWindowChanges() {
        let app = FakeApp()
        let request = HandoffTool.Request(app: "x", goal: "Click Save", doneWhen: [.text("Saved")],
                                          values: [("Name", "Ann")], maxSteps: 5, timeBudget: 10)
        var deps = app.deps(choose: { _ in XCTFail("must not rank after window changed"); return nil })
        var reads = 0
        deps.readState = {
            reads += 1
            return "App=x\nWindow: \"Form\"\nWindow ID: \(reads == 1 ? 12 : 13)\n1 text field Name =\n3 button Save"
        }
        let outcome = HandoffTool.run(request, deps)
        XCTAssertNotEqual(outcome.kind, .done)
        XCTAssertEqual(app.acts, ["fill \"Name\""])
    }

    func testRankedFieldWritesRequireExactUniqueEmptyDestination() {
        let input = [("Name", "Ann")]
        let candidates = build(values: input, state: HandoffTool.parseControls("1 text field Name ="))
        let safe = candidates.first { $0.kind == .setValue }
        XCTAssertEqual(safe?.risky, false)
        XCTAssertEqual(safe?.expectedValue, "")
        for state in ["1 text field Name = Existing", "1 text field Display Name =", "1 text field Name =\n2 text field Name ="] {
            let proposals = build(values: input, state: HandoffTool.parseControls(state)).filter { $0.kind == .setValue }
            XCTAssertFalse(proposals.isEmpty)
            XCTAssertTrue(proposals.allSatisfy(\.risky))
        }
    }

    func testNavigationCycleStopsWithoutAskingStuckModel() {
        let request = HandoffTool.Request(app: "x", goal: "Navigate", doneWhen: [.text("Finished")],
                                          values: [], maxSteps: 10, timeBudget: 20)
        let first = "App=x\nWindow: Form\n1 button Next\n2 scroll area"
        let second = "App=x\nWindow: Form\n3 button Continue\n4 scroll area"
        var state = first
        var acts = 0
        let deps = HandoffTool.Dependencies(
            readState: { state },
            act: { _, _ in
                acts += 1
                state = acts % 2 == 0 ? first : second
                return .init(ok: true, message: "", observedState: state)
            },
            choose: { _, _, _, _, options in
                var result = Dictionary(uniqueKeysWithValues: options.map { ($0.id, 0.01) })
                result["none"] = 0.01
                if let option = options.first { result[option.id] = 0.95 }
                return result
            },
            check: { HandoffTool.check(request.doneWhen, screen: $0) }, replay: { _ in nil }, now: { 0 }
        )
        let outcome = HandoffTool.run(request, deps)
        XCTAssertEqual(outcome.kind, .stuck)
        XCTAssertEqual(acts, 3)
        XCTAssertTrue(outcome.reason.contains("previously observed states"))
    }

    func testGuardedLineEndingIsAddedOnlyWhenMissing() throws {
        for (kind, ending) in [("lf", "\n"), ("crlf", "\r\n")] {
            let request = try HandoffTool.parse([
                "app": "TextEdit", "goal": "Edit the draft", "line_ending": kind,
                "expected_values": ["Document": "Before" + ending],
                "values": ["Document": "After"],
                "done_when": ["field": "Document", "equals": "After" + ending],
            ])
            XCTAssertEqual(request.expectedValues["Document"], "Before" + ending)
            XCTAssertEqual(request.values.first?.value, "After" + ending)
            XCTAssertEqual(request.doneWhen, [.field(label: "Document", equals: "After" + ending)])
        }
    }

    func testGuardedEditReturnsVerifiedReceiptAfterExactReadback() {
        let app = FakeApp()
        app.name = "Before"
        let conditions: [DoneCheck.Condition] = [.field(label: "Name", equals: "After")]
        let request = HandoffTool.Request(
            app: "x", goal: "Update name", doneWhen: conditions, values: [("Name", "After")],
            maxSteps: 5, timeBudget: 10, expectedValues: ["Name": "Before"]
        )
        var deps = app.deps(choose: { _ in nil })
        deps.check = { HandoffTool.check(conditions, screen: $0) }
        let outcome = HandoffTool.run(request, deps)
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(outcome.deliveryState, .verified)
        XCTAssertEqual(app.name, "After")
        XCTAssertEqual(app.chooseCalls, 0)
    }

    func testGuardedFieldCompletionRejectsStaleSameTextPiggyback() {
        let window = "App=x\nWindow: Draft\nWindow ID: 31"
        let screen = window + "\n1 text field Name = Before (w:str)\n2 text field City = Before (w:str)"
        let conditions: [DoneCheck.Condition] = [
            .field(label: "Name", equals: "After"), .field(label: "City", equals: "After"),
        ]
        let request = HandoffTool.Request(
            app: "x", goal: "Update draft fields", doneWhen: conditions,
            values: [("Name", "After"), ("City", "After")], maxSteps: 2, timeBudget: 10,
            expectedValues: ["Name": "Before", "City": "Before"]
        )
        var name = "Before", city = "Before"
        var observed: [DoneCheck.Field] = []
        var reads = 0
        var acts = 0
        let deps = HandoffTool.Dependencies(
            readState: {
                reads += 1
                observed = [.init(label: "Name", value: name), .init(label: "City", value: city)]
                return screen
            },
            act: { _, _ in
                acts += 1
                if acts == 1 {
                    // Independent change before the retry read. The rendered state is identical.
                    name = "After"
                    city = "After"
                    return .init(ok: false, message: "the first action never went out", delivery: .notSent)
                }
                name = "Before"
                return .init(ok: true, message: "", delivery: .acknowledged, observedState: screen)
            },
            choose: { _, _, _, _, _ in XCTFail("guarded action called chooser"); return nil },
            check: { HandoffTool.check(conditions, screen: $0, observedFields: observed) },
            replay: { _ in nil }, now: { 0 }
        )
        let result = HandoffTool.run(request, deps)
        XCTAssertEqual(acts, 2)
        XCTAssertEqual(reads, 3)
        XCTAssertNotEqual(result.kind, .done)
        XCTAssertNotEqual(result.deliveryState, .verified)
    }

    func testGuardedEditsStopBeforeAnyWriteWhenOneFieldChanged() {
        let app = FakeApp()
        app.name = "Before"
        app.email = "changed@example.test"
        let conditions: [DoneCheck.Condition] = [
            .field(label: "Name", equals: "After"),
            .field(label: "Email", equals: "after@example.test"),
        ]
        let request = HandoffTool.Request(
            app: "x", goal: "Update contact fields", doneWhen: conditions,
            values: [("Name", "After"), ("Email", "after@example.test")],
            maxSteps: 5, timeBudget: 10,
            expectedValues: ["Name": "Before", "Email": "before@example.test"]
        )
        var deps = app.deps(choose: { _ in nil })
        deps.check = { HandoffTool.check(conditions, screen: $0) }
        let outcome = HandoffTool.run(request, deps)
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertTrue(app.acts.isEmpty)
        XCTAssertEqual(app.chooseCalls, 0)
        XCTAssertEqual(app.name, "Before")
    }

    func testExactFieldCheckCannotBeSatisfiedByAnotherFieldOrDuplicate() {
        let condition = DoneCheck.Condition.field(label: "Name", equals: "Ann")
        XCTAssertEqual(HandoffTool.check([condition], screen: "1 text field Display Name = Ann"), .missing(unmet: [condition.summary]))
        XCTAssertEqual(HandoffTool.check([condition], screen: "1 text field Name = Ann\n2 text field Name = Bob"), .missing(unmet: [condition.summary]))
    }

    func testExactFieldFillRequiresUniqueEmptyNativeTextField() {
        let request = HandoffTool.Request(app: "x", goal: "Fill name", doneWhen: [.field(label: "Name", equals: "Ann")],
                                          values: [("Name", "Ann")], maxSteps: 5, timeBudget: 10)
        for state in ["1 text field Name = Bob", "1 text field Name =\n2 text field Name =",
                      "1 secure text field Name =", "1 text field (disabled) Name ="] {
            let controls = HandoffTool.parseControls(state)
            XCTAssertNil(HandoffTool.exactFieldFill(request: request, controls: controls,
                                                    tried: []), state)
        }
    }

    func testPinnedHandoffCannotUseEvidenceFromAnotherWindow() throws {
        let app = FakeApp()
        let request = try HandoffTool.parse(["app": "x", "window_id": 31, "goal": "Save", "done_when": ["text": "Saved"]])
        XCTAssertThrowsError(try HandoffTool.parse(["app": "x", "window_id": true, "goal": "Save", "done_when": ["text": "Saved"]]))
        XCTAssertEqual(HandoffTool.run(request, app.deps(choose: { _ in nil })).kind, .failed)
        XCTAssertTrue(app.acts.isEmpty)
        XCTAssertEqual(app.chooseCalls, 0)
    }

    func testPinnedHandoffRefreshesWrongActionReadbackAndSkipsReplay() throws {
        let app = FakeApp()
        let request = try HandoffTool.parse(["app": "x", "window_id": 31, "goal": "Save", "done_when": ["text": "Saved"]])
        var deps = app.deps(choose: pick(["Save"]))
        var reads = 0
        deps.readState = {
            reads += 1
            return "App=x\nWindow: \"right\"\nWindow ID: 31\n3 button Save"
        }
        deps.act = { _, _ in
            HandoffTool.ActResult(ok: true, message: "", observedState: "App=x\nWindow: \"wrong\"\nWindow ID: 32\nSaved")
        }
        deps.replay = { _ in XCTFail("no replay in pinned window"); return .verified }
        let result = HandoffTool.run(request, deps)
        XCTAssertNotEqual(result.kind, .done)
        XCTAssertEqual(reads, 2)
    }

    func testUnknownDeliveryReadsOnceAndNeverRepeats() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = LearningLog(directory: folder, enabled: true, imagesEnabled: false)
        let app = FakeApp()
        var deps = app.deps(choose: pick(["fill"]))
        deps.act = { candidate, _ in
            app.acts.append(candidate.text)
            app.saved = true
            return HandoffTool.ActResult(ok: false, message: "transport interrupted")
        }
        deps.settleState = { _ in XCTFail("uncertain delivery must never start a retry or settling loop"); return nil }
        let outcome = HandoffTool.run(request(), deps, learning: log)
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertEqual(outcome.deliveryState, .outcomeUnknown)
        XCTAssertEqual(app.acts.count, 1)
        XCTAssertEqual(app.reads, 2)
        XCTAssertEqual(app.chooseCalls, 1)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "jsonl" })
        let observation = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .compactMap { $0 }
            .filter { $0["kind"] as? String == "choice_outcome" }
        XCTAssertEqual(observation.count, 1)
        XCTAssertEqual(observation.first?["readback"] as? String, "changed")
        XCTAssertEqual(observation.first?["delivery_state"] as? String, DeliveryState.outcomeUnknown.rawValue)
    }

    func testUncertainRecipeReadsBackWithoutTryingAnotherAction() {
        let app = FakeApp()
        var deps = app.deps(choose: pick(["fill"]))
        deps.replay = { _ in .uncertain }
        XCTAssertEqual(HandoffTool.run(request(), deps).kind, .escalate)
        XCTAssertEqual(app.reads, 2)
        XCTAssertTrue(app.acts.isEmpty)
        XCTAssertEqual(app.chooseCalls, 0)
    }

    func testUnattendedRecipesRejectImplicitFocusAndRiskyTargets() throws {
        let cases: [[String: Any]] = [
            ["tool": "press_key", "key": "Return"],
            ["tool": "type_text", "text": "Hello"],
            ["tool": "click", "target": "Delete"],
            ["tool": "click", "label": "Save", "app": "Other"],
            ["tool": "click", "label": "Save", "click_method": "global"],
            ["tool": "click", "label": "Save", "click_count": 2],
            ["tool": "click", "label": "Save", "x": 20, "y": 20],
            ["tool": "set_value", "label": "Password", "value": "fixture"],
        ]
        let steps = try BatchTool.parseSteps(cases, defaultApp: "Example")
        XCTAssertTrue(steps.allSatisfy { !HandoffTool.isSafeRecipeStep($0, app: "Example") })
    }

    func testRecipeMutationBindsOneExactEnabledControlInObservedWindow() throws {
        let step = BatchTool.Step(tool: "click", arguments: ["app": "Example", "label": "Save"])
        let state = "App=x\nWindow: w\nWindow ID: 501\n3 button Save"
        let bound = try XCTUnwrap(HandoffTool.bindRecipeStep(step, app: "Example", state: state))
        XCTAssertEqual(bound.arguments["window_id"] as? UInt32, 501)
        XCTAssertEqual(bound.arguments["element_index"] as? String, "3")
        XCTAssertEqual(bound.arguments["click_method"] as? String, "accessibility")
        XCTAssertNil(bound.arguments["label"])
        XCTAssertNil(HandoffTool.bindRecipeStep(step, app: "Example", state: state + "\n4 button Save"))
        XCTAssertNil(HandoffTool.bindRecipeStep(step, app: "Example", state: "App=x\nWindow: w\n3 button Save"))
    }

    func testAlreadyDoneTakesNoSteps() {
        let app = FakeApp()
        app.saved = true
        let outcome = HandoffTool.run(request(), app.deps(choose: { _ in nil }))
        // A match already on screen is weak evidence: no steps, and the caller decides.
        XCTAssertEqual(outcome.kind, .notVerified)
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
        XCTAssertEqual(app.chooseCalls, 1, "unavailable helper should not be retried immediately")
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
        let outcome = HandoffTool.run(request(), app.deps(choose: pick(["fill", "Save", "scroll"]), changes: false))
        XCTAssertEqual(outcome.kind, .stuck)
        XCTAssertLessThanOrEqual(app.acts.count, 3)
    }

    func testStallsAfterRealProgressAreDetectedLocally() {
        let app = FakeApp()
        var deps = app.deps(choose: pick(["fill", "Next", "Save"]))
        deps.act = { candidate, _ in
            app.acts.append(candidate.text)
            if candidate.kind == .setValue { app.name = "Ann" }
            return .init(ok: true, message: "", delivery: .acknowledged)
        }
        let outcome = HandoffTool.run(request(), deps)
        XCTAssertEqual(outcome.kind, .stuck)
        XCTAssertEqual(app.acts.count, 3)
        XCTAssertEqual(app.chooseCalls, 3, "only choosing actions uses the helper; stall detection is local")
        XCTAssertTrue(outcome.reason.contains("last two actions changed nothing"))
    }

    func testStopsOnTimeBudgetAndStepCap() {
        let slow = FakeApp()
        let timed = HandoffTool.run(request(budget: 5), slow.deps(choose: pick(["fill", "scroll"]), stepSeconds: 10))
        XCTAssertEqual(timed.kind, .budget)
        XCTAssertEqual(slow.acts.count, 1)
        XCTAssertEqual(slow.reads, 1, "the initial state is the only read when an action uses the budget")
        let capped = FakeApp()
        let steps = HandoffTool.run(request(maxSteps: 1), capped.deps(choose: pick(["fill"])))
        XCTAssertEqual(steps.kind, .budget)
        XCTAssertEqual(capped.acts.count, 1)
    }

    func testSpentReplayBudgetDoesNotStartNewReadOrAction() {
        let app = FakeApp()
        var deps = app.deps(choose: pick(["fill"]))
        deps.replay = { _ in app.clock += 5; return .incomplete }
        let outcome = HandoffTool.run(request(budget: 5), deps)
        XCTAssertEqual(outcome.kind, .budget)
        XCTAssertEqual(app.reads, 1)
        XCTAssertTrue(app.acts.isEmpty)
    }

    func testReplayedRecipeFinishes() {
        let app = FakeApp()
        let outcome = HandoffTool.run(request(), app.deps(choose: { _ in nil }, replay: true))
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(app.chooseCalls, 0)
        let failed = FakeApp()
        let continued = HandoffTool.run(request(), failed.deps(choose: pick(["fill", "Save"]), replay: false))
        XCTAssertEqual(continued.kind, .done, "a recipe that did not finish falls back to the loop")
    }

    func testParseChooseReply() {
        XCTAssertEqual(Referee.parseChoose(["probs": ["a": 0.7, "none": 0.1]]) ?? [:], ["a": 0.7, "none": 0.1])
        XCTAssertNil(Referee.parseChoose(["probs": ["a": 7]]))
        XCTAssertNil(Referee.parseChoose([:]))
    }

    func testLocalSettlingBacksOffAndStopsAsSoonAsTheScreenChanges() {
        var clock: TimeInterval = 0
        var pauses: [TimeInterval] = []
        var reads = 0
        let state = "App=x\nWindow: w\nWindow ID: 31\n1 button Save"
        let changed = state + "\n2 static text Saved"
        let result = HandoffTool.settledState(after: state, deadline: 5, now: { clock },
                                            pause: { pauses.append($0); clock += $0 }, read: {
            reads += 1
            return reads == 2 ? changed : state
        })
        XCTAssertEqual(result, changed)
        XCTAssertEqual(pauses, [0.1, 0.2])
        XCTAssertEqual(reads, 2)
    }

    func testLocalSettlingHasAReadCapAndHonorsDeadline() {
        var clock: TimeInterval = 0
        var reads = 0
        let result = HandoffTool.settledState(after: "same", deadline: 5, now: { clock },
                                            pause: { clock += $0 }, read: { reads += 1; return "same" })
        XCTAssertEqual(result, "same")
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(clock, 0.7, accuracy: 0.0001)
        clock = 0
        reads = 0
        _ = HandoffTool.settledState(after: "same", deadline: 0.15, now: { clock },
                                    pause: { clock += $0 }, read: { reads += 1; return "same" })
        XCTAssertEqual(reads, 1)
        XCTAssertLessThan(clock, 0.15)
    }

    func testLocalSettlingCancellationDoesNotReadAgain() {
        let cancellation = RequestCancellation()
        let result = RequestCancellation.$current.withValue(cancellation) {
            HandoffTool.settledState(after: "same", deadline: 5, now: { 0 },
                                    pause: { _ in cancellation.cancel() }, read: {
                XCTFail("cancelled settling read the app")
                return "changed"
            })
        }
        XCTAssertNil(result)
    }

    func testDelayedExactClickCompletesWithReadOnlySettlingAndNoModel() {
        let state = "App=x\nWindow: w\nWindow ID: 31\n1 button Save\n2 button Next"
        let request = HandoffTool.Request(app: "x", goal: "Click Save", doneWhen: [.text("Saved")],
                                          values: [], maxSteps: 5, timeBudget: 10)
        var acts = 0
        var settles = 0
        let deps = HandoffTool.Dependencies(
            readState: { state },
            act: { _, _ in acts += 1; return .init(ok: true, message: "", delivery: .acknowledged, observedState: state) },
            choose: { _, _, _, _, _ in XCTFail("an exact click must never ask a model"); return nil },
            check: { HandoffTool.check(request.doneWhen, screen: $0) },
            replay: { _ in XCTFail("an exact click must never replay"); return nil },
            now: { 0 },
            allowsModelChoices: false,
            settleState: { _ in settles += 1; return state + "\n3 static text Saved" }
        )
        let outcome = HandoffTool.run(request, deps)
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertEqual(outcome.deliveryState, .verified)
        XCTAssertEqual(acts, 1)
        XCTAssertEqual(settles, 1)
        XCTAssertEqual(outcome.chooserCalls, 0)
    }

    func testExactClickDoesNotFallBackToAnotherActionWhenCompletionIsMissing() {
        let state = "App=x\nWindow: w\nWindow ID: 31\n1 button Save\n2 button Next"
        let request = HandoffTool.Request(app: "x", goal: "Click Save", doneWhen: [.text("Saved")],
                                          values: [], maxSteps: 5, timeBudget: 10)
        var acts = 0
        let deps = HandoffTool.Dependencies(
            readState: { state },
            act: { _, _ in acts += 1; return .init(ok: true, message: "", delivery: .acknowledged, observedState: state) },
            choose: { _, _, _, _, _ in XCTFail("must not choose another button after the requested click"); return nil },
            check: { HandoffTool.check(request.doneWhen, screen: $0) },
            replay: { _ in nil }, now: { 0 }, settleState: { $0 }
        )
        let outcome = HandoffTool.run(request, deps)
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertEqual(outcome.deliveryState, .acknowledged)
        XCTAssertEqual(acts, 1)
        XCTAssertEqual(outcome.chooserCalls, 0)
    }

    func testMissingOrDuplicateExactClickStopsWithoutModelOrRecipe() {
        let request = HandoffTool.Request(app: "x", goal: "Click Save", doneWhen: [.text("Saved")],
                                          values: [], maxSteps: 5, timeBudget: 10)
        for controls in ["1 button Next", "1 button Save\n2 button Save", "1 button (disabled) Save"] {
            let deps = HandoffTool.Dependencies(
                readState: { "App=x\nWindow: w\nWindow ID: 31\n" + controls },
                act: { _, _ in XCTFail("unconfirmed exact click was sent"); return .init(ok: false, message: "") },
                choose: { _, _, _, _, _ in XCTFail("exact instruction is deterministic"); return nil },
                check: { HandoffTool.check(request.doneWhen, screen: $0) },
                replay: { _ in XCTFail("must not replay a missing exact target"); return nil }, now: { 0 }
            )
            XCTAssertEqual(HandoffTool.run(request, deps).kind, .escalate)
        }
    }

    func testGeneralHandoffPinsWindowAndProcessWithoutExplicitWindowID() {
        let initial = "App=x (pid 10)\nWindow: w\nWindow ID: 31\n1 button Next\n2 button Continue"
        let request = HandoffTool.Request(app: "x", goal: "Navigate", doneWhen: [.text("Finished")],
                                          values: [], maxSteps: 5, timeBudget: 10)
        for changed in [initial.replacingOccurrences(of: "Window ID: 31", with: "Window ID: 32"),
                        initial.replacingOccurrences(of: "pid 10", with: "pid 11")] {
            var acts = 0
            var reads = 0
            var choices = 0
            let deps = HandoffTool.Dependencies(
                readState: { reads += 1; return reads == 1 ? initial : changed + "\n3 static text Finished" },
                act: { _, _ in
                    acts += 1
                    return .init(ok: true, message: "", delivery: .acknowledged,
                                 observedState: changed + "\n3 static text Finished")
                },
                choose: { _, _, _, _, options in
                    choices += 1
                    return options.first.map { [$0.id: 1.0, "none": 0.0] }
                },
                check: { HandoffTool.check(request.doneWhen, screen: $0) }, replay: { _ in nil }, now: { 0 }
            )
            let outcome = HandoffTool.run(request, deps)
            XCTAssertEqual(outcome.kind, .failed)
            XCTAssertEqual(outcome.deliveryState, .acknowledged)
            XCTAssertEqual(acts, 1)
            XCTAssertEqual(choices, 1)
            XCTAssertEqual(reads, 2)
        }
    }

    func testLocalSettlingRejectsAnotherWindowAsCompletionEvidence() {
        let initial = "App=x\nWindow: w\nWindow ID: 31\n1 button Save"
        let request = HandoffTool.Request(app: "x", goal: "Click Save", doneWhen: [.text("Saved")],
                                          values: [], maxSteps: 5, timeBudget: 10)
        let deps = HandoffTool.Dependencies(
            readState: { initial },
            act: { _, _ in .init(ok: true, message: "", delivery: .acknowledged, observedState: initial) },
            choose: { _, _, _, _, _ in XCTFail("must not ask a model"); return nil },
            check: { HandoffTool.check(request.doneWhen, screen: $0) }, replay: { _ in nil }, now: { 0 },
            settleState: { _ in initial.replacingOccurrences(of: "Window ID: 31", with: "Window ID: 32") + "\nSaved" }
        )
        let outcome = HandoffTool.run(request, deps)
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(outcome.steps.count, 1)
        XCTAssertEqual(outcome.deliveryState, .acknowledged)
    }

    func testModelFreeHandoffSkipsChooserPreparationAndCall() {
        let app = FakeApp()
        var deps = app.deps(choose: { _ in XCTFail("models are disabled"); return nil })
        deps.allowsModelChoices = false
        let outcome = HandoffTool.run(request(), deps)
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertEqual(outcome.chooserCalls, 0)
        XCTAssertEqual(app.chooseCalls, 0)
        XCTAssertTrue(app.acts.isEmpty)
    }
}
