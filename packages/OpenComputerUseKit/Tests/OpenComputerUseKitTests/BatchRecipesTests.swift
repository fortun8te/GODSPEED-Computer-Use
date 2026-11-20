import XCTest
@testable import OpenComputerUseKit

final class BatchRecipesTests: XCTestCase {
    private func state(_ rows: [String], title: String = "Draft - Mail") -> String {
        (["App=com.example (pid 1)", "Window: \"\(title)\", App: Mail.", "[legend]"] + rows).joined(separator: "\n")
    }

    // MARK: keys

    func testTemplateKeyIgnoresValuesEmailsAndNumbers() {
        let a = BatchRecipes.templateKey("Send email to bob@x.com about invoice 42")
        let b = BatchRecipes.templateKey("send email to alice@y.org about invoice 7")
        XCTAssertEqual(a, b)
        XCTAssertEqual(BatchRecipes.templateKey("Email Sam the report", values: ["Sam"]),
                       BatchRecipes.templateKey("Email Kim the report", values: ["Kim"]))
        XCTAssertNotEqual(BatchRecipes.templateKey("Email Sam the report"), BatchRecipes.templateKey("Archive the report"))
    }

    // MARK: parameters

    func testParameterizeNamesFromLabelAndValues() {
        let steps: [[String: Any]] = [
            ["tool": "set_value", "label": "To", "value": "sam@x.com"],
            ["tool": "set_value", "label": "Subject", "value": "Hi"],
            ["tool": "type_text", "text": "Body text"],
            ["tool": "click", "label": "Send"],
        ]
        let out = BatchRecipes.parameterize(steps, values: [:])
        XCTAssertEqual(out.steps[0]["value"] as? String, "{{to}}")
        XCTAssertEqual(out.steps[1]["value"] as? String, "{{subject}}")
        XCTAssertEqual(out.steps[2]["text"] as? String, "{{text}}")
        XCTAssertEqual(out.steps[3]["label"] as? String, "Send")
        XCTAssertEqual(out.params, ["to": "sam@x.com", "subject": "Hi", "text": "Body text"])

        let named = BatchRecipes.parameterize(steps, values: ["recipient": "sam@x.com"])
        XCTAssertEqual(named.steps[0]["value"] as? String, "{{recipient}}")
    }

    func testParameterizeDedupesNames() {
        let steps: [[String: Any]] = [
            ["tool": "set_value", "label": "Name", "value": "A"],
            ["tool": "set_value", "label": "Name", "value": "B"],
        ]
        XCTAssertEqual(BatchRecipes.parameterize(steps, values: [:]).params, ["name": "A", "name_2": "B"])
    }

    func testSlotsBindOnlyExplicitMatchingValuesAndStripMeta() throws {
        let steps: [Any] = [["tool": "set_value", "label": "To", "value": "{{to}}", "_loc": ["label": "To"], "_fx": "changed"]]
        let recipe = BatchRecipes.Recipe(app: "Mail", goal: "Fill the recipient", steps: steps, uses: 0, failures: 0,
                                        params: ["to": "old@x.com"], slotKinds: ["to": .recipient])
        XCTAssertThrowsError(try BatchRecipes.boundSteps(recipe, values: [:]))
        XCTAssertThrowsError(try BatchRecipes.boundSteps(recipe, values: ["to": "new@x.com"]))
        XCTAssertThrowsError(try BatchRecipes.boundSteps(recipe, values: ["to": "old@x.com", "extra": "1"]))
        let bound = try BatchRecipes.boundSteps(recipe, values: ["to": "old@x.com"])
        let step = try XCTUnwrap(bound.first as? [String: Any])
        XCTAssertEqual(step["value"] as? String, "old@x.com")
        XCTAssertNil(step["_loc"])
        XCTAssertNil(step["_fx"])
    }

    func testSlotTypesFromFieldAndValue() {
        let slots = ["To": "Alice", "Email": "a@example.test", "Quantity": "42.5", "Path": "/tmp/file", "Note": "A note"]
        let result = BatchRecipes.parameterize(slots.map { ["tool": "set_value", "label": $0.key, "value": $0.value] }, values: [:])
        XCTAssertEqual(result.kinds, ["to": .recipient, "email": .email, "quantity": .number, "path": .path, "note": .text])
        XCTAssertFalse(BatchRecipes.SlotKind.recipient.accepts("Alice\nBob"))
        XCTAssertFalse(BatchRecipes.SlotKind.email.accepts("not an address"))
        XCTAssertFalse(BatchRecipes.SlotKind.number.accepts("many"))
        XCTAssertFalse(BatchRecipes.SlotKind.path.accepts("relative/path"))
        XCTAssertTrue(BatchRecipes.SlotKind.text.accepts("a\nline"))
    }

    // MARK: effects

    func testEffectKindAndReplayStop() {
        let none = ["3. click \"Send\": ok", "   no visible change", "4. click \"Done\": ok"]
        let changed = ["3. click \"Send\": ok", "   effect: 12 checkbox A = 0→1"]
        XCTAssertEqual(BatchRecipes.block(for: 3, in: none), Array(none.prefix(2)))
        XCTAssertEqual(BatchRecipes.effectKind(of: BatchRecipes.block(for: 3, in: none)), "none")
        XCTAssertEqual(BatchRecipes.effectKind(of: changed), "changed")
        XCTAssertNil(BatchRecipes.effectKind(of: ["3. click: ok"]))

        let stop = BatchRecipes.replayStop(number: 3, total: 5, recorded: "changed", block: BatchRecipes.block(for: 3, in: none))
        XCTAssertNotNil(stop)
        XCTAssertTrue(stop?.contains("Steps 4-5") == true)
        XCTAssertNil(BatchRecipes.replayStop(number: 3, total: 5, recorded: "none", block: none))
        XCTAssertNil(BatchRecipes.replayStop(number: 3, total: 5, recorded: "changed", block: changed))
    }

    // MARK: locators

    private let compose = [
        "\t1 window Compose",
        "\t\t2 toolbar Actions",
        "\t\t\t3 button Attach",
        "\t\t\t4 button Send",
        "\t\t\t5 button Discard",
    ]

    func testCaptureStoresRoleParentAndNeighbours() {
        let loc = RecipeLocator.capture(label: "Send", in: state(compose))
        XCTAssertEqual(loc?.role, "button")
        XCTAssertEqual(loc?.parent, "Actions")
        XCTAssertEqual(loc?.nearby, ["Attach", "Discard"])
    }

    func testLocatorRequiresOriginalRoleAndParentAndExactUniqueLabel() throws {
        let original = state(compose)
        let loc = try XCTUnwrap(RecipeLocator.capture(label: "Send", in: original))
        XCTAssertTrue(RecipeLocator.confirms(loc, label: "Send", in: original))
        XCTAssertFalse(RecipeLocator.confirms(loc, label: "Send", in: original.replacingOccurrences(of: "Send", with: "Send now")))
        XCTAssertFalse(RecipeLocator.confirms(loc, label: "Send", in: original.replacingOccurrences(of: "Actions", with: "Different account")))
        XCTAssertFalse(RecipeLocator.confirms(loc, label: "Send", in: original.replacingOccurrences(of: "button Send", with: "menu item Send")))
        XCTAssertFalse(RecipeLocator.confirms(loc, label: "Send", in: original + "\n\t\t\t6 button Send"))
    }

    func testLocatorRoundTrip() {
        let loc = RecipeLocator.Locator(role: "button", label: "Send", parent: "Actions", nearby: ["Attach"])
        XCTAssertEqual(RecipeLocator.Locator(dictionary: loc.dictionary), loc)
    }
}
