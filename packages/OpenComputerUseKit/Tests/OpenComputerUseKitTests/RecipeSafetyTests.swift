import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Review fixes: recipes never store secrets or flows whose done_when was already true, the store survives
/// concurrent writers, healing never lands on a risky control, handoff replies carry state and options.
final class RecipeSafetyTests: XCTestCase {
    private func tempStore() -> (BatchRecipes, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recipes-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("recipes.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (BatchRecipes(fileURL: url), url)
    }

    private func state(_ rows: [String], title: String = "Login - Safari", window: UInt32 = 14, pid: Int = 1) -> String {
        (["App=com.example (pid \(pid))", "Window: \"\(title)\", App: Safari.", "Window ID: \(window)"] + rows).joined(separator: "\n")
    }

    private func matched(_ store: BatchRecipes, app: String = "Safari", goal: String = "log in as bob",
                         values: [String: String] = [:], screen: String? = nil) -> BatchRecipes.Recipe? {
        guard case .match(let recipe) = store.lookup(app: app, goal: goal, values: values, state: screen ?? state([])) else {
            return nil
        }
        return recipe
    }

    @discardableResult
    private func saveVerified(_ store: BatchRecipes, app: String = "Safari", goal: String = "log in as bob",
                              label: String = "Save", screen: String? = nil) -> BatchRecipes.Recipe? {
        store.save(app: app, goal: goal, steps: [["tool": "click", "label": label]], doneWhen: [.text("Saved")],
                   window: BatchRecipes.Window(state: screen ?? state([])), verified: true)
    }

    // MARK: locator

    func testLabelMatchUsesWholeWords() {
        XCTAssertEqual(RecipeLocator.labelMatch("OK", "Book"), 0)
        XCTAssertEqual(RecipeLocator.labelMatch("Save", "Save As"), 1)
        XCTAssertEqual(RecipeLocator.labelMatch("Save", "save"), 2)
    }

    func testSecretDetection() {
        XCTAssertTrue(RecipeLocator.looksSecret("Password"))
        XCTAssertTrue(RecipeLocator.looksSecret("Card number"))
        XCTAssertFalse(RecipeLocator.looksSecret("Subject"))
        let s = state(["\t1 secure text field Pass (w:str)", "\t2 text field User = bob (w:str)"])
        XCTAssertTrue(RecipeLocator.hasSecureField(s))
        XCTAssertTrue(RecipeLocator.isSecretField(label: "Pass", in: s))
        XCTAssertFalse(RecipeLocator.isSecretField(label: "User", in: s))
    }

    func testHealNeverLandsOnRiskyControl() {
        let saved = state(["\t1 toolbar Actions", "\t\t2 button Attach", "\t\t3 button Save", "\t\t4 button Discard"])
        let loc = RecipeLocator.capture(label: "Save", in: saved)!
        let now = state(["\t1 toolbar Actions", "\t\t2 button Attach", "\t\t3 button Delete", "\t\t4 button Discard"])
        XCTAssertFalse(RecipeLocator.confirms(loc, label: "Save", in: now))
    }

    func testSiblingWithSameRoleAndParentAloneDoesNotHeal() {
        let loc = RecipeLocator.Locator(role: "button", label: "Export", parent: "Actions", nearby: ["Attach"])
        let now = state(["\t1 toolbar Actions", "\t\t2 button Attach", "\t\t3 button Zoom", "\t\t4 button Rotate"])
        XCTAssertFalse(RecipeLocator.confirms(loc, label: "Export", in: now))
    }

    // MARK: store

    func testStoreMergesWritesFromTwoProcessesAndSurvivesThreads() {
        let (a, url) = tempStore()
        let b = BatchRecipes(fileURL: url)
        saveVerified(a, app: "Notes", goal: "make a note", label: "New")
        saveVerified(b, app: "Mail", goal: "archive mail", label: "Archive")
        XCTAssertNotNil(matched(a, app: "Mail", goal: "archive mail"))
        XCTAssertNotNil(matched(b, app: "Notes", goal: "make a note"))

        let window = BatchRecipes.Window(state: state([]))
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            let store = i % 2 == 0 ? a : b
            store.save(app: "App\(i)", goal: "goal number \(i) word\(i)x", steps: [["tool": "click", "label": "Go"]],
                       doneWhen: [.text("Complete")], window: window, verified: true)
        }
        let fresh = BatchRecipes(fileURL: url)
        for i in 0..<20 { XCTAssertNotNil(matched(fresh, app: "App\(i)", goal: "goal number \(i) word\(i)x"), "lost \(i)") }
        let data = try? Data(contentsOf: url)
        XCTAssertNotNil(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }

    func testCorruptFileIsSetAsideNotOverwritten() throws {
        let (store, url) = tempStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        saveVerified(store, app: "Notes", goal: "make a note", label: "New")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        XCTAssertNotNil(matched(store, app: "Notes", goal: "make a note"))
    }

    // MARK: save decisions

    private func run(store: BatchRecipes, initial: String, steps: [BatchTool.Step], done: [DoneCheck.Condition],
                     verified: Bool, remember: Bool? = nil, values: Any? = nil) -> [String] {
        let run = BatchRecipes.Run(goal: "log in as bob", values: values, app: "Safari") { _ in initial }
        run.store = store
        run.doneWhen = done
        for (i, step) in steps.enumerated() { _ = run.prepared(step, number: i + 1, before: nil) }
        return run.finish(app: "Safari", steps: steps, lines: [], failed: false, stopped: false,
                          remember: remember, verifiedDone: verified, finalState: initial + "\n42 static text Saved")
    }

    func testDoneWhenAlreadyTrueIsNotSaved() {
        let (store, _) = tempStore()
        let initial = state(["\t1 button Save", "\t2 static text Saved"])
        let steps = [BatchTool.Step(tool: "click", arguments: ["app": "Safari", "label": "Save"])]
        let out = run(store: store, initial: initial, steps: steps, done: [.text("Saved")], verified: true)
        XCTAssertNil(matched(store))
        XCTAssertTrue(out.joined().contains("cannot verify"))
    }

    func testDoneWhenFalseBeforeIsSaved() {
        let (store, _) = tempStore()
        let initial = state(["\t1 button Save"])
        let steps = [BatchTool.Step(tool: "click", arguments: ["app": "Safari", "label": "Save"])]
        _ = run(store: store, initial: initial, steps: steps, done: [.appeared("Saved")], verified: true)
        XCTAssertNotNil(matched(store))
    }

    func testReplayAlreadySatisfiedIsWeakAndSendsNothing() throws {
        let (store, _) = tempStore()
        let screen = state(["1 static text Saved"])
        let run = BatchRecipes.Run(goal: "Save", values: nil, app: "Safari") { _ in screen }
        run.store = store
        store.save(app: "Safari", goal: "Save", steps: [["tool": "click", "label": "Save"]],
                   doneWhen: [.text("Saved")], window: BatchRecipes.Window(state: screen), verified: true)
        guard case .match(let recipe) = run.lookup(app: "Safari") else { return XCTFail("no recipe") }
        run.doneWhen = recipe.doneWhen

        let result = try XCTUnwrap(run.alreadySatisfied())
        XCTAssertEqual(result.batchReceipt?.doneCheck, .weakEvidence)
        XCTAssertEqual(result.batchReceipt?.totalSteps, 0)
        XCTAssertEqual(result.deliveryState, .notSent)
        XCTAssertTrue(result.textContent.contains("Already satisfied"))
        XCTAssertTrue(result.textContent.contains("Not verified"), "weak evidence never reads as done")
        XCTAssertEqual(HandoffTool.replayResult(result), .alreadySatisfied(result.textContent))
        run.doneWhen = [.appeared("Saved")]
        XCTAssertNil(run.alreadySatisfied(), "A pre-existing label cannot meet a change check")
    }

    func testReplayCompletionUsesFileAndURLEvidenceAndRequiresSameWindow() throws {
        let initial = state(["1 button Save"])
        let run = BatchRecipes.Run(goal: "Save", values: nil, app: "Safari") { _ in initial }
        let conditions: [DoneCheck.Condition] = [.fileExists("/test/report.pdf"), .urlContains("/receipt")]
        let recipe = BatchRecipes.Recipe(app: "Safari", goal: "Save", steps: [], uses: 0, failures: 0,
                                        doneWhen: conditions, window: BatchRecipes.Window(state: initial))
        run.doneWhen = conditions
        _ = try run.replaySteps(recipe)
        var evidence = DoneCheck.Evidence(screenText: initial, pageURL: { "https://example.test/receipt" },
                                          fileExists: { $0 == "/test/report.pdf" })
        XCTAssertEqual(run.checkReplay(evidence: evidence, baseline: nil, after: nil),
                       .weak(met: conditions.map(\.summary)))
        evidence.pageURL = { nil }
        XCTAssertEqual(run.checkReplay(evidence: evidence, baseline: nil, after: nil),
                       .missing(unmet: [conditions[1].summary]))
        evidence.screenText = state(["1 button Save"], window: 15)
        XCTAssertEqual(run.checkReplay(evidence: evidence, baseline: nil, after: nil),
                       .missing(unmet: conditions.map(\.summary)))
    }

    func testPasswordTypingIsNeverSaved() {
        let (store, url) = tempStore()
        let initial = state(["\t1 text field User = (w:str)", "\t2 secure text field Pass = (w:str)", "\t3 button Log in"])
        let steps = [
            BatchTool.Step(tool: "set_value", arguments: ["app": "Safari", "label": "User", "value": "bob"]),
            BatchTool.Step(tool: "set_value", arguments: ["app": "Safari", "label": "Pass", "value": "hunter2"]),
            BatchTool.Step(tool: "click", arguments: ["app": "Safari", "label": "Log in"]),
        ]
        let out = run(store: store, initial: initial, steps: steps, done: [.text("Welcome")], verified: true, remember: true)
        XCTAssertNil(matched(store))
        XCTAssertTrue(out.joined().contains("never stored"))
        XCTAssertFalse((try? String(contentsOf: url, encoding: .utf8))?.contains("hunter2") ?? false)
    }

    func testTypeTextWhileSecureFieldShownIsNeverSaved() {
        let (store, _) = tempStore()
        let initial = state(["\t1 secure text field Pass = (w:str)"])
        let steps = [BatchTool.Step(tool: "type_text", arguments: ["app": "Safari", "text": "hunter2"])]
        _ = run(store: store, initial: initial, steps: steps, done: [.text("Welcome")], verified: true, remember: true)
        XCTAssertNil(matched(store))
    }

    func testReplayCutShortByTimeIsNotCounted() {
        let (store, _) = tempStore()
        saveVerified(store)
        let run = BatchRecipes.Run(goal: "log in as bob", values: nil, app: "Safari") { [screen = state([])] _ in screen }
        run.store = store
        guard case .match(let recipe) = run.lookup(app: "Safari") else { return XCTFail("no recipe") }
        XCTAssertNoThrow(try run.replaySteps(recipe))
        _ = run.finish(app: "Safari", steps: [], lines: [], failed: false, stopped: true, remember: nil, verifiedDone: false)
        XCTAssertEqual(matched(store)?.uses, 0)
        XCTAssertEqual(matched(store)?.failures, 0)
    }

    func testChangedRecipientAndMissingSlotCannotReplaySavedValues() throws {
        let (store, _) = tempStore()
        let goal = "Fill recipient alice@example.test"
        let screen = state(["1 text field To ="])
        store.save(app: "Safari", goal: goal, steps: [["tool": "set_value", "label": "To", "value": "{{to}}"]],
                   params: ["to": "alice@example.test"], slotKinds: ["to": .recipient],
                   doneWhen: [.field(label: "To", equals: "alice@example.test")],
                   window: BatchRecipes.Window(state: screen), verified: true)
        let correct = ["to": "alice@example.test"]
        XCTAssertNotNil(matched(store, goal: goal, values: correct, screen: screen))
        let cases = [("Fill recipient bob@example.test", [:]), (goal, [:]), (goal, ["to": "bob@example.test"])]
        for (requested, values) in cases {
            guard case .blocked(let reason) = store.lookup(app: "Safari", goal: requested, values: values, state: screen) else {
                return XCTFail("unsafe match for \(requested)")
            }
            XCTAssertTrue(reason.contains("Confirm"))
            XCTAssertFalse(reason.contains("alice@example.test"))
        }
        XCTAssertNil(matched(store, goal: "Put Alice in the To field", values: correct, screen: screen))
    }

    func testChangedWindowCannotReplayEvenWithTheSameTitleAndControls() throws {
        let (store, _) = tempStore()
        let goal = "Save form"
        let rows = ["1 button Save"]
        let original = state(rows, title: "Alice - Safari")
        saveVerified(store, goal: goal, screen: original)
        XCTAssertNotNil(matched(store, goal: goal, screen: original))
        let changed = [state(rows, title: "Bob - Safari"), state(rows, title: "Alice - Safari", window: 15),
                       state(rows, title: "Alice - Safari", pid: 2)]
        for screen in changed {
            guard case .blocked(let reason) = store.lookup(app: "Safari", goal: goal, state: screen) else {
                return XCTFail("a different window matched")
            }
            XCTAssertTrue(reason.contains("original window"))
        }
        let locator = try XCTUnwrap(RecipeLocator.capture(label: "Save", in: original))
        store.save(app: "Safari", goal: "Save with locator", steps: [["tool": "click", "label": "Save", "_loc": locator.dictionary]],
                   doneWhen: [.text("Saved")], window: BatchRecipes.Window(state: original), verified: true)
        var live = original
        let run = BatchRecipes.Run(goal: "Save with locator", values: nil, app: "Safari") { _ in live }
        run.store = store
        guard case .match(let recipe) = run.lookup(app: "Safari") else { return XCTFail("no verified recipe") }
        _ = try run.replaySteps(recipe)
        let step = BatchTool.Step(tool: "click", arguments: ["app": "Safari", "label": "Save"])
        let originalBinding = try XCTUnwrap(run.prepareReplay(step, number: 1))
        XCTAssertEqual(originalBinding.arguments["window_id"] as? UInt32, 14)
        live = changed[1]
        XCTAssertNil(run.prepareReplay(step, number: 1))
    }

    func testReplayStopsOnAnUncertainEffectOrLostExpectedChange() throws {
        let run = BatchRecipes.Run(goal: "Save form", values: nil, app: "Safari") { _ in nil }
        let recipe = BatchRecipes.Recipe(app: "Safari", goal: "Save form", steps: [
            ["tool": "click", "label": "Save", "_fx": "changed"],
            ["tool": "click", "label": "Done"]
        ], uses: 0, failures: 0)
        _ = try run.replaySteps(recipe)
        let lines = ["1. click Save"]
        XCTAssertNotNil(run.verify(number: 1, total: 2, lines: lines, observation: .noEffectSeen))
        XCTAssertNotNil(run.verify(number: 1, total: 2, lines: lines, observation: .outcomeUnknown))
        XCTAssertNil(run.verify(number: 1, total: 2, lines: lines, observation: nil))
    }

    func testLegacyRecipeRequiresFreshVerifiedRun() throws {
        let (store, url) = tempStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"[{"app":"Safari","goal":"Save form","shape":"safari","steps":[{"tool":"click","label":"Save"}],"done_when":[{"text":"Saved"}]}]"#
        try Data(old.utf8).write(to: url)
        guard case .blocked(let reason) = store.lookup(app: "Safari", goal: "Save form", state: state([])) else {
            return XCTFail("legacy recipe should be unverified")
        }
        XCTAssertTrue(reason.contains("unverified"))
        saveVerified(store, goal: "Save form")
        XCTAssertNotNil(matched(store, goal: "Save form"))
    }

    func testRememberWithoutCheckDoesNotSaveMutation() {
        let (store, url) = tempStore()
        let steps = [BatchTool.Step(tool: "click", arguments: ["app": "Safari", "label": "Save"])]
        let reply = run(store: store, initial: state(["\t1 button Save"]), steps: steps, done: [],
                        verified: false, remember: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(reply.joined().contains("done_when"))
    }

    func testSavingAnotherVersionDoesNotReplaceWorkingRecipe() throws {
        let (store, _) = tempStore()
        let goal = "Save the form"
        let champion = try XCTUnwrap(saveVerified(store, goal: goal))
        let challenger = try XCTUnwrap(saveVerified(store, goal: goal, label: "Save As"))
        XCTAssertFalse(challenger.champion)
        XCTAssertEqual(matched(store, goal: goal)?.version, champion.version)
        store.recordReplay(champion, succeeded: false)
        XCTAssertEqual(matched(store, goal: goal)?.failures, 1)
        store.recordReplay(champion, succeeded: true)
        XCTAssertEqual(matched(store, goal: goal)?.failures, 0)
        store.recordReplay(champion, succeeded: false)
        store.recordReplay(champion, succeeded: false)
        XCTAssertEqual(matched(store, goal: goal)?.version, challenger.version)
        store.recordReplay(champion, succeeded: false)
        XCTAssertEqual(matched(store, goal: goal)?.failures, 0)
    }

    func testUnverifiedChallengerDoesNotReplayAfterEviction() throws {
        let (store, _) = tempStore()
        let champion = try XCTUnwrap(saveVerified(store))
        store.save(app: "Safari", goal: champion.goal, steps: [], doneWhen: [.text("Saved")],
                   window: BatchRecipes.Window(state: state([])), verified: false)
        store.recordReplay(champion, succeeded: false)
        store.recordReplay(champion, succeeded: false)
        XCTAssertNil(matched(store))
    }

    // MARK: handoff

    func testBlockedRecipeHandsBackWithoutCallingChooserOrActing() {
        let screen = state(["1 button Save"])
        let request = HandoffTool.Request(app: "Safari", goal: "Save the form", doneWhen: [.text("Saved")],
                                          values: [], maxSteps: 2, timeBudget: 10)
        let deps = HandoffTool.Dependencies(
            readState: { screen }, act: { _, _ in XCTFail("acted after blocked recipe"); return .init(ok: false, message: "") },
            choose: { _, _, _, _, _ in XCTFail("called chooser after blocked recipe"); return nil },
            looksStuck: { _, _, _ in false }, check: { HandoffTool.check(request.doneWhen, screen: $0) },
            replay: { _ in .blocked("Confirm the recipient.") }, now: { 0 }
        )
        let outcome = HandoffTool.run(request, deps)
        XCTAssertEqual(outcome.kind, .escalate)
        XCTAssertEqual(outcome.reason, "Confirm the recipient.")
        XCTAssertTrue(outcome.steps.isEmpty)
    }

    func testSecretFieldIsNeverTypedByHandoff() {
        let controls = HandoffTool.parseControls("\t1 text field Password = (w:str)\n\t2 text field Name = (w:str)\n\t3 button Save")
        let out = HandoffTool.candidates(goal: "save login", doneSummary: "", values: [("Password", "hunter2"), ("Name", "bob")],
                                         controls: controls, tried: [], typedAny: false, scrollsDone: 0)
        XCTAssertFalse(out.contains { $0.text.contains("hunter2") })
        XCTAssertTrue(out.contains { $0.text.contains("bob") })
    }

    func testReturnIsRiskyNextToASendButton() {
        let controls = HandoffTool.parseControls("\t1 text field To = a (w:str)\n\t2 button Send")
        let out = HandoffTool.candidates(goal: "fill the To field", doneSummary: "", values: [], controls: controls,
                                         tried: [], typedAny: true, scrollsDone: 0)
        XCTAssertEqual(out.first { $0.kind == .pressReturn }?.risky, true)
    }

    func testSameNamedButtonsAreBothOffered() {
        let controls = HandoffTool.parseControls("\t1 button Save\n\t2 button Save")
        let first = HandoffTool.candidates(goal: "save", doneSummary: "", values: [], controls: controls, tried: [], typedAny: false, scrollsDone: 0)
        XCTAssertEqual(first.count, 2)
        let second = HandoffTool.candidates(goal: "save", doneSummary: "", values: [], controls: controls,
                                            tried: [first[0].key], typedAny: false, scrollsDone: 0)
        XCTAssertEqual(second.count, 1)
    }

    func testRiskyRecipeIsNotReplayedUnattended() {
        XCTAssertFalse(HandoffTool.isSafeRecipeStep(.init(tool: "click", arguments: ["label": "Delete contact"]), app: "Notes"))
        XCTAssertFalse(HandoffTool.isSafeRecipeStep(.init(tool: "click", arguments: ["label": "Save", "app": "com.example.app"]),
                                                     app: "com.exampleapp"))
        XCTAssertTrue(HandoffTool.isSafeRecipeStep(.init(tool: "click", arguments: ["label": "Save"]), app: "Notes"))
    }

    func testReplayIsNotRunWhenGoalAlreadyTrue() {
        var replayed = false
        let deps = HandoffTool.Dependencies(
            readState: { "App=x\nWindow: \"w\"\n\t1 static text Saved" }, act: { _, _ in .init(ok: true, message: "") },
            choose: { _, _, _, _, _ in nil }, looksStuck: { _, _, _ in false },
            check: { DoneCheck.check([.text("Saved")], evidence: .init(screenText: $0, pageURL: { nil })) },
            replay: { _ in replayed = true; return .verified }, now: { 0 })
        let outcome = HandoffTool.run(.init(app: "x", goal: "g", doneWhen: [.text("Saved")], values: [], maxSteps: 3, timeBudget: 30), deps)
        // Already on screen is weak evidence: reported as not verified, and no replay runs.
        XCTAssertEqual(outcome.kind, .notVerified)
        XCTAssertFalse(replayed)
    }

    func testEscalationReplyCarriesScreenMissingAndOptions() {
        let deps = HandoffTool.Dependencies(
            readState: { "App=x\nWindow: \"Calc\"\n\t1 button Add\n\t2 button Subtract" }, act: { _, _ in .init(ok: true, message: "") },
            choose: { _, _, _, _, options in Dictionary(uniqueKeysWithValues: options.map { ($0.id, 0.4) }).merging(["none": 0.1]) { a, _ in a } },
            looksStuck: { _, _, _ in false },
            check: { DoneCheck.check([.text("42")], evidence: .init(screenText: $0, pageURL: { nil })) },
            replay: { _ in nil }, now: { 0 })
        let outcome = HandoffTool.run(.init(app: "x", goal: "add numbers", doneWhen: [.text("42")], values: [], maxSteps: 3, timeBudget: 30), deps)
        XCTAssertEqual(outcome.kind, .escalate)
        let reply = outcome.reply()
        XCTAssertTrue(reply.contains("Needs you:"))
        XCTAssertTrue(reply.contains("Still missing: \"42\" is on screen"))
        XCTAssertTrue(reply.contains("Screen now:"))
        XCTAssertTrue(reply.contains("Window: \"Calc\""))
        XCTAssertTrue(reply.contains("Top options"))
        let close = HandoffTool.decide(candidates: [
            .init(id: "a", kind: .click, text: "click \"Add\"", tool: "click", arguments: [:], risky: false, key: "a"),
            .init(id: "b", kind: .click, text: "click \"Subtract\"", tool: "click", arguments: [:], risky: false, key: "b"),
        ], probabilities: ["a": 0.7, "b": 0.6, "none": 0.01])
        guard case .escalate(let why) = close else { return XCTFail() }
        XCTAssertTrue(why.contains("next: click \"Subtract\""), why)
    }
}
