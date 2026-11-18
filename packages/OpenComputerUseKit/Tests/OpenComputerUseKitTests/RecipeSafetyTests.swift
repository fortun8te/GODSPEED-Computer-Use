import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Review fixes: recipes never store secrets or flows whose done_when was already true, the store survives
/// concurrent writers, healing never lands on a risky control, handoff replies carry state and options.
final class RecipeSafetyTests: XCTestCase {
    private func tempStore() -> (BatchRecipes, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recipes-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("recipes.json")
        return (BatchRecipes(fileURL: url), url)
    }

    private func state(_ rows: [String]) -> String {
        (["App=com.example (pid 1)", "Window: \"Login - Safari\", App: Safari.", "[legend]"] + rows).joined(separator: "\n")
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
        XCTAssertEqual(RecipeLocator.resolve(loc, label: "Save", in: now), .missing)
    }

    func testSiblingWithSameRoleAndParentAloneDoesNotHeal() {
        let loc = RecipeLocator.Locator(role: "button", label: "Export", parent: "Actions", nearby: ["Attach"])
        let now = state(["\t1 toolbar Actions", "\t\t2 button Attach", "\t\t3 button Zoom", "\t\t4 button Rotate"])
        XCTAssertEqual(RecipeLocator.resolve(loc, label: "Export", in: now), .missing)
    }

    // MARK: store

    func testStoreMergesWritesFromTwoProcessesAndSurvivesThreads() {
        let (a, url) = tempStore()
        let b = BatchRecipes(fileURL: url)
        a.save(app: "Notes", goal: "make a note", steps: [["tool": "click", "label": "New"]])
        b.save(app: "Mail", goal: "archive mail", steps: [["tool": "click", "label": "Archive"]])
        XCTAssertNotNil(a.find(app: "Mail", goal: "archive mail"))
        XCTAssertNotNil(b.find(app: "Notes", goal: "make a note"))

        DispatchQueue.concurrentPerform(iterations: 20) { i in
            let store = i % 2 == 0 ? a : b
            store.save(app: "App\(i)", goal: "goal number \(i) word\(i)x", steps: [["tool": "click", "label": "Go"]])
        }
        let fresh = BatchRecipes(fileURL: url)
        for i in 0..<20 { XCTAssertNotNil(fresh.find(app: "App\(i)", goal: "goal number \(i) word\(i)x"), "lost \(i)") }
        let data = try? Data(contentsOf: url)
        XCTAssertNotNil(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }

    func testCorruptFileIsSetAsideNotOverwritten() throws {
        let (store, url) = tempStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        store.save(app: "Notes", goal: "make a note", steps: [["tool": "click", "label": "New"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        XCTAssertNotNil(store.find(app: "Notes", goal: "make a note"))
    }

    // MARK: save decisions

    private func run(store: BatchRecipes, initial: String, steps: [BatchTool.Step], done: [DoneCheck.Condition],
                     verified: Bool, remember: Bool? = nil, values: Any? = nil) -> [String] {
        let run = BatchRecipes.Run(goal: "log in as bob", values: values, app: "Safari") { _ in initial }
        run.store = store
        run.doneWhen = done
        for (i, step) in steps.enumerated() { _ = run.prepared(step, number: i + 1, before: nil) }
        return run.finish(app: "Safari", steps: steps, lines: [], failed: false, stopped: false,
                          remember: remember, verifiedDone: verified)
    }

    func testDoneWhenAlreadyTrueIsNotSaved() {
        let (store, _) = tempStore()
        let initial = state(["\t1 button Save", "\t2 static text Saved"])
        let steps = [BatchTool.Step(tool: "click", arguments: ["app": "Safari", "label": "Save"])]
        let out = run(store: store, initial: initial, steps: steps, done: [.text("Saved")], verified: true)
        XCTAssertNil(store.find(app: "Safari", goal: "log in as bob"))
        XCTAssertTrue(out.joined().contains("already true"))
    }

    func testDoneWhenFalseBeforeIsSaved() {
        let (store, _) = tempStore()
        let initial = state(["\t1 button Save"])
        let steps = [BatchTool.Step(tool: "click", arguments: ["app": "Safari", "label": "Save"])]
        _ = run(store: store, initial: initial, steps: steps, done: [.text("Saved")], verified: true)
        XCTAssertNotNil(store.find(app: "Safari", goal: "log in as bob"))
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
        XCTAssertNil(store.find(app: "Safari", goal: "log in as bob"))
        XCTAssertTrue(out.joined().contains("never stored"))
        XCTAssertFalse((try? String(contentsOf: url, encoding: .utf8))?.contains("hunter2") ?? false)
    }

    func testTypeTextWhileSecureFieldShownIsNeverSaved() {
        let (store, _) = tempStore()
        let initial = state(["\t1 secure text field Pass = (w:str)"])
        let steps = [BatchTool.Step(tool: "type_text", arguments: ["app": "Safari", "text": "hunter2"])]
        _ = run(store: store, initial: initial, steps: steps, done: [.text("Welcome")], verified: true, remember: true)
        XCTAssertNil(store.find(app: "Safari", goal: "log in as bob"))
    }

    func testReplayCutShortByTimeIsNotCounted() {
        let (store, _) = tempStore()
        store.save(app: "Safari", goal: "log in as bob", steps: [["tool": "click", "label": "Go"]])
        let recipe = store.find(app: "Safari", goal: "log in as bob")!
        let run = BatchRecipes.Run(goal: "log in as bob", values: nil, app: "Safari") { _ in nil }
        run.store = store
        _ = run.find(app: "Safari")
        XCTAssertNotNil(run.recipe)
        _ = run.finish(app: "Safari", steps: [], lines: [], failed: false, stopped: true, remember: nil, verifiedDone: false)
        XCTAssertEqual(store.find(app: "Safari", goal: "log in as bob")?.uses, 0)
        _ = recipe
    }

    // MARK: handoff

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
        XCTAssertTrue(HandoffTool.recipeIsRisky([["tool": "click", "label": "Delete contact"]]))
        XCTAssertFalse(HandoffTool.recipeIsRisky([["tool": "click", "label": "Save"]]))
    }

    func testReplayIsNotRunWhenGoalAlreadyTrue() {
        var replayed = false
        let deps = HandoffTool.Dependencies(
            readState: { "App=x\nWindow: \"w\"\n\t1 static text Saved" }, act: { _, _ in .init(ok: true, message: "") },
            choose: { _, _, _, _, _ in nil }, looksStuck: { _, _, _ in false },
            check: { DoneCheck.check([.text("Saved")], evidence: .init(screenText: $0, pageURL: { nil })) },
            replay: { replayed = true; return true }, now: { 0 })
        let outcome = HandoffTool.run(.init(app: "x", goal: "g", doneWhen: [.text("Saved")], values: [], maxSteps: 3, timeBudget: 30), deps)
        XCTAssertEqual(outcome.kind, .done)
        XCTAssertFalse(replayed)
    }

    func testEscalationReplyCarriesScreenMissingAndOptions() {
        let deps = HandoffTool.Dependencies(
            readState: { "App=x\nWindow: \"Calc\"\n\t1 button Add\n\t2 button Subtract" }, act: { _, _ in .init(ok: true, message: "") },
            choose: { _, _, _, _, options in Dictionary(uniqueKeysWithValues: options.map { ($0.id, 0.4) }).merging(["none": 0.1]) { a, _ in a } },
            looksStuck: { _, _, _ in false },
            check: { DoneCheck.check([.text("42")], evidence: .init(screenText: $0, pageURL: { nil })) },
            replay: { nil }, now: { 0 })
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
