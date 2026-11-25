import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Synthetic observations with independent target/state oracles. Byte measurements below
/// are serialized UTF-8 sizes, not a tokenizer count or a claim about model task accuracy.
final class AXLocalInterpretationTests: XCTestCase {
    private func standardOptions() -> AXTreeCondenser.Options {
        var options = AXTreeCondenser.Options.default
        options.dropStructuralNoise = false
        options.collapseRuns = false
        options.truncateText = false
        options.dedupeText = false
        options.dropHidden = false
        options.unwrapSingleChild = false
        options.maxDescriptionLength = 0
        options.dropRepeatedProperties = false
        options.maxCharacters = 0
        return options
    }

    func testCompactObservationDropsOnlyAnExactPlainControlLabelLeaf() {
        let lines = [
            "App=Fixture", "0 window Settings", "\t1 group Billing",
            "\t\t2 button (disabled) Save", "\t\t\t3 text Save",
            "\t\t\t4 text Save (selected)", "\t\t\t5 text Save changes",
            "\t\t6 button Save", "\t\t\t7 text Save Secondary Actions: Press",
            "\t\t8 text field (w:str) Name = Save", "\t\t\t9 text Save",
            "\t10 row Save", "\t\t11 text Save",
        ]
        let result = AXTreeCondenser.compactObservation(lines.joined(separator: "\n"))
        XCTAssertEqual(result, lines.filter { $0 != "\t\t\t3 text Save" }.joined(separator: "\n"))
        XCTAssertEqual(AXTreeCondenser.compactObservation(lines.joined(separator: "\n"), preserving: ["3"]),
                       lines.joined(separator: "\n"))
    }

    func testCompactBatchRetainsLateFieldLabelsValidationAndCompletionEvidence() {
        let preamble = (1...20).map { "\t\($0) text Article paragraph \($0)" }
        let essential = [
            "\t30 group Billing", "\t\t31 text Email", "\t\t32 text Use your work address",
            "\t\t33 text field (w:str) =", "\t\t34 text Address is required",
            "\t40 text Saved successfully", "\t41 button Close",
        ]
        let input = (["App=Fixture", "0 window Settings"] + preamble + essential).joined(separator: "\n")
        let result = AXTreeCondenser.batchReply(input)
        for line in essential { XCTAssertTrue(result.contains(line), "Lost evidence: \(line)") }
        XCTAssertFalse(result.contains("\t12 text Article paragraph 12"))
        XCTAssertTrue(result.contains("text lines omitted"))
        let preserved = LeanOutput.condensed(.init(content: [.text(input)], isError: false), mode: .compactBatch, preserving: ["12"])
        XCTAssertTrue(LeanOutput.stateText(of: preserved)?.contains("\t12 text Article paragraph 12") == true)
    }

    func testCompactBatchKeepsDialogTextAndAnAncestorThatIsText() {
        let input = (["App=Fixture", "0 window Settings"] + (1...12).map { "\t\($0) text Paragraph \($0)" } + [
            "\t20 dialog Confirm export", "\t\t21 text Existing files will be replaced",
            "\t\t22 text Review the filename before continuing", "\t\t23 button Cancel",
            "\t30 text Destination", "\t\t31 button Choose",
        ]).joined(separator: "\n")
        let result = AXTreeCondenser.batchReply(input)
        XCTAssertTrue(result.contains("21 text Existing files will be replaced"))
        XCTAssertTrue(result.contains("22 text Review the filename before continuing"))
        XCTAssertTrue(result.contains("30 text Destination\n\t\t31 button Choose"))
    }

    func testBudgetBringsTheActualParentPathWithALateControl() {
        var options = standardOptions(); options.maxCharacters = 300
        let input = (["0 window Checkout", "\t1 group Archive"] + (2...18).map {
            "\t\t\($0) text Earlier content with padding words"
        } + ["\t30 group Billing", "\t\t31 section Address", "\t\t\t32 button Save"]).joined(separator: "\n")
        let output = AXTreeCondenser.condense(input, options: options)
        XCTAssertTrue(output.contains("\t30 group Billing\n\t\t31 section Address\n\t\t\t32 button Save"))
        XCTAssertTrue(output.contains("more lines cut to fit"))
        XCTAssertLessThan(output.count, 540)
    }

    func testBudgetDoesNotAttachAControlToAnUnrelatedParentWhenContextCannotFit() {
        var options = standardOptions(); options.maxCharacters = 50
        let input = "0 window Checkout\n\t1 group Archive\n\t2 group " + String(repeating: "Billing ", count: 20) + "\n\t\t3 button Save"
        let output = AXTreeCondenser.condense(input, options: options)
        XCTAssertFalse(output.contains("3 button Save"))
        XCTAssertTrue(output.contains("more lines cut to fit"))
    }

    func testSubstringMatchingDoesNotEraseNamedParentContext() {
        var options = standardOptions(); options.dropStructuralNoise = true; options.unwrapSingleChild = true
        let input = "0 window Checkout\n\t1 group Billing\n\t\t2 button Billing address"
        XCTAssertEqual(AXTreeCondenser.condense(input, options: options), input)
    }

    func testPackedStructuralCompactionMovesOneLogicalLevel() {
        var options = standardOptions(); options.dropStructuralNoise = true
        let input = ["App=Fixture", "[tab=4 w=settable]", "0 window Settings", " 1 group Named",
                     "  2 group Named", "   3 group", "\t4 button Save", "  5 button Other"].joined(separator: "\n")
        XCTAssertEqual(AXTreeCondenser.condense(input, options: options),
                       input.replacingOccurrences(of: "   3 group\n\t4 button Save", with: "   4 button Save"))
    }

    func testProtectedTextAndHiddenStateDoNotDisappear() {
        var options = standardOptions(); options.truncateText = true; options.dedupeText = true; options.dropHidden = true
        let long = String(repeating: "Important label ", count: 20)
        let lines = ["0 window Settings", "\t1 text \(long)(focused)", "\t2 text \(long)(focused)",
                     "\t3 row (offscreen, expanded) Details", "\t4 row (hidden, disabled) Disabled",
                     "\t5 row (offscreen) Progress = 40", "\t6 text Saved successfully: \(long)"]
        XCTAssertEqual(AXTreeCondenser.condense(lines.joined(separator: "\n"), options: options), lines.joined(separator: "\n"))
    }

    func testRepeatedPropertiesStayWithinTheirPackedParent() {
        var options = standardOptions(); options.dropRepeatedProperties = true
        let input = ["[tab=4 w=settable]", "0 window Settings", " 1 group Billing", "  2 group Personal",
                     "   3 group Details", "\t4 button Save Help: Save this address", "  5 group Business",
                     "   6 group Details", "\t7 button Save Help: Save this address"].joined(separator: "\n")
        XCTAssertEqual(AXTreeCondenser.condense(input, options: options), input)
    }

    private func form(_ billing: String, _ shipping: String, reversed: Bool = false) -> String {
        let groups = [
            ["\t1 group Billing", "\t\t2 text field (w:str) Name = \(billing)"],
            ["\t3 group Shipping", "\t\t4 text field (w:str) Name = \(shipping)"],
        ]
        return (["App=Fixture", "0 window Checkout"] + (reversed ? groups.reversed().flatMap { $0 } : groups.flatMap { $0 })).joined(separator: "\n")
    }

    func testSemanticChangesUseNamedScopeAndDoNotInventChangesAfterReordering() {
        XCTAssertEqual(SemanticChanges.events(before: form("Alice", "Bob"), after: form("Alice", "Bob", reversed: true)), [])
        XCTAssertEqual(SemanticChanges.events(before: form("Alice", "Bob"), after: form("Alicia", "Bob", reversed: true)),
                       ["Name [Billing]: Alice → Alicia"])
    }

    func testAmbiguousDuplicatesNeverInventPerFieldValueTransitions() {
        let before = "0 window Form\n\t1 text field Name = Alice\n\t2 text field Name = Bob"
        let reordered = "0 window Form\n\t40 text field Name = Bob\n\t41 text field Name = Alice"
        XCTAssertEqual(SemanticChanges.events(before: before, after: reordered), [])
        let changed = "0 window Form\n\t1 text field Name = Carol\n\t2 text field Name = Dana"
        let events = SemanticChanges.events(before: before, after: changed)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.first?.contains("duplicate controls") == true)
        XCTAssertFalse(events.joined().contains("→"))
    }

    func testSelectionBetweenSameNamedRowsUsesItsRealGroup() {
        let before = "0 window Files\n\t1 group Source\n\t\t2 row (selected) Report\n\t3 group Destination\n\t\t4 row Report"
        let after = "0 window Files\n\t1 group Source\n\t\t2 row Report\n\t3 group Destination\n\t\t4 row (selected) Report"
        XCTAssertEqual(SemanticChanges.events(before: before, after: after),
                       ["Selection changed: Report [Source] → Report [Destination]"])
    }

    func testSensitiveParentContextSuppressesUnlabelledFieldValues() {
        let before = "0 window Login\n\t1 group Verification code\n\t\t2 text field (w:str) = 123456"
        let after = before.replacingOccurrences(of: "123456", with: "654321")
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), ["Text field changed"])
    }

    func testNativeCheckboxAndLiteralParenthesesAreInterpretedLocally() {
        let before = "0 window Form\n\t1 checkbox (w:bool) Remember me = off\n\t2 text field (w:str) Name (legal (full)) = Alice"
        let after = before.replacingOccurrences(of: "= off", with: "= on").replacingOccurrences(of: "= Alice", with: "= Alice (selected)")
        XCTAssertEqual(SemanticChanges.events(before: before, after: after), [
            "Name (legal (full)): Alice → Alice (selected)", "Checkbox \"Remember me\" turned on",
        ])
    }

    func testDuplicateRichFixtureMeasuresBytesWithAllControlAndContextFactsRetained() throws {
        var lines = ["App=SyntheticSettings", "Window: \"Accounts\", App: Settings.", "Window ID: 17", "[w=settable]", "0 window Accounts"]
        var required: [String] = ["0 window Accounts"]
        for account in 0..<200 {
            let base = account * 5 + 1
            let group = "\t\(base) group Account \(account) (expanded)"
            let button = "\t\t\(base + 1) button\(account % 3 == 0 ? " (disabled)" : "") Open café \(account)"
            let label = "\t\t\t\(base + 2) text Open café \(account)"
            let field = "\t\t\(base + 3) text field (w:str) Label = Account \(account)"
            let toggle = "\t\t\(base + 4) check box (w:bool) Enabled = \(account % 2 == 0 ? "on" : "off")"
            lines += [group, button, label, field, toggle]
            required += [group, button, field, toggle]
        }
        lines.append("\t1001 text Saved successfully")
        required.append("\t1001 text Saved successfully")
        let input = lines.joined(separator: "\n")
        let output = AXTreeCondenser.compactObservation(input)
        let actual = Set(output.components(separatedBy: "\n"))
        let retained = required.filter { actual.contains($0) }.count
        XCTAssertEqual(retained, required.count)
        XCTAssertEqual(output.components(separatedBy: "\n").count, lines.count - 200)
        XCTAssertLessThan(Double(output.utf8.count), Double(input.utf8.count) * 0.90)
        // The exact lines and original order retain every control's named ancestor, state,
        // value, role and index. The only omitted refs were redundant plain label leaves.
        XCTAssertEqual(output.components(separatedBy: "\n").filter { required.contains($0) }, required)
        let metrics: [String: Any] = ["fixture": "200_account_controls", "before_utf8_bytes": input.utf8.count,
                                    "after_utf8_bytes": output.utf8.count, "required_facts": required.count,
                                    "retained_facts": retained, "lost_facts": required.count - retained,
                                    "model_token_count": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("AX_LOCAL_OBSERVATION_METRICS " + String(decoding: data, as: UTF8.self))
    }
}
