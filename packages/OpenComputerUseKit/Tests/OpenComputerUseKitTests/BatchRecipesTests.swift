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

    func testWindowShape() {
        XCTAssertEqual(BatchRecipes.windowShape(title: "Q3 plan - Pages"), "pages")
        XCTAssertEqual(BatchRecipes.windowShape(title: "Untitled"), "untitled")
        XCTAssertEqual(BatchRecipes.windowShape(title: nil), "")
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

    func testSubstituteUsesValuesThenDefaultsAndStripsMeta() {
        let steps: [Any] = [["tool": "set_value", "label": "To", "value": "{{to}}", "_loc": ["label": "To"], "_fx": "changed"]]
        let withValue = BatchRecipes.substitute(steps, params: ["to": "old@x.com"], values: ["to": "new@x.com", "extra": "1"])
        let dict = withValue.steps[0] as? [String: Any]
        XCTAssertEqual(dict?["value"] as? String, "new@x.com")
        XCTAssertNil(dict?["_loc"])
        XCTAssertNil(dict?["_fx"])
        XCTAssertEqual(withValue.ignored, ["extra"])
        let defaulted = BatchRecipes.substitute(steps, params: ["to": "old@x.com"], values: [:])
        XCTAssertEqual((defaulted.steps[0] as? [String: Any])?["value"] as? String, "old@x.com")
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

    func testResolveKeepsLabelWhenStillThere() {
        let loc = RecipeLocator.capture(label: "Send", in: state(compose))!
        XCTAssertEqual(RecipeLocator.resolve(loc, label: "Send", in: state(compose)), .found)
    }

    func testResolveHealsRenamedButton() {
        let loc = RecipeLocator.capture(label: "Send", in: state(compose))!
        let renamed = state(compose.map { $0.replacingOccurrences(of: "Send", with: "Send now") })
        // "Send" is contained in "Send now", so the label itself still resolves.
        XCTAssertEqual(RecipeLocator.resolve(loc, label: "Send", in: renamed), .found)
        let rewritten = state(compose.map { $0.replacingOccurrences(of: "Send", with: "Submit") })
        guard case .healed(let label, let healed) = RecipeLocator.resolve(loc, label: "Send", in: rewritten) else {
            return XCTFail("expected a healed locator")
        }
        XCTAssertEqual(label, "Submit")
        XCTAssertEqual(healed.parent, "Actions")
    }

    func testResolveMissingWhenNothingFits() {
        let loc = RecipeLocator.capture(label: "Send", in: state(compose))!
        let other = state(["\t1 window Photos", "\t\t2 button Import", "\t\t3 text Library"])
        XCTAssertEqual(RecipeLocator.resolve(loc, label: "Send", in: other), .missing)
    }

    func testResolveRefusesAmbiguousClues() {
        let loc = RecipeLocator.Locator(role: "button", label: "Send", parent: "Actions", nearby: [])
        let twins = state(["\t1 toolbar Actions", "\t\t2 button Alpha", "\t\t3 button Beta"])
        XCTAssertEqual(RecipeLocator.resolve(loc, label: "Send", in: twins), .missing)
    }

    func testLocatorRoundTrip() {
        let loc = RecipeLocator.Locator(role: "button", label: "Send", parent: "Actions", nearby: ["Attach"])
        XCTAssertEqual(RecipeLocator.Locator(dictionary: loc.dictionary), loc)
    }
}
