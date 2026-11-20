import Foundation
import XCTest
@testable import OpenComputerUseKit

final class FailureSignaturesTests: XCTestCase {
    func testNormalization() {
        let sig = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "timeout", targetRole: "button", targetLabel: "  Order   123456789012345678901234567890123456789 ")
        XCTAssertEqual(sig.targetLabel, "order ##################################")
        let secure = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "text", targetLabel: "Secret", isSecureField: true)
        XCTAssertEqual(secure.targetLabel, "")
    }

    func testThresholdAndRiskRefusal() {
        let store = FailureSignatureStore()
        let sig = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "stale_state", targetRole: "button", targetLabel: "Continue")
        store.record(sig, recovery: "refresh", succeeded: true)
        XCTAssertNil(store.suggestion(for: sig))
        store.record(sig, recovery: "refresh", succeeded: true)
        XCTAssertEqual(store.suggestion(for: sig)?.hint, "refresh")
        let risky = FailureSignature(appBundleID: "a", toolName: "send", failureCode: "timeout", targetRole: "button", targetLabel: "Continue")
        store.record(risky, recovery: "retry", succeeded: true); store.record(risky, recovery: "retry", succeeded: true)
        XCTAssertNil(store.suggestion(for: risky))
    }

    func testEvictionAndPersistence() throws {
        let store = FailureSignatureStore()
        let base = Date(timeIntervalSince1970: 1)
        let first = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "button", targetLabel: "first")
        store.record(first, recovery: "refresh", succeeded: true, now: base)
        store.record(first, recovery: "refresh", succeeded: true, now: base.addingTimeInterval(1))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("store.json")
        try store.save(to: file)
        let loaded = FailureSignatureStore(); try loaded.load(from: file)
        XCTAssertEqual(loaded.suggestion(for: first)?.hint, "refresh")
        // `first` is the least recently seen signature with a qualifying suggestion. Overflow must evict it,
        // while a signature seen after the fillers survives.
        for i in 0..<1_000 {
            let sig = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "filler \(i)", targetRole: "button", targetLabel: "item")
            loaded.record(sig, recovery: nil, succeeded: false, now: base.addingTimeInterval(Double(i + 2)))
        }
        let recent = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "button", targetLabel: "recent")
        loaded.record(recent, recovery: "refresh", succeeded: true, now: base.addingTimeInterval(2_000))
        loaded.record(recent, recovery: "refresh", succeeded: true, now: base.addingTimeInterval(2_001))
        XCTAssertNil(loaded.suggestion(for: first))
        XCTAssertEqual(loaded.suggestion(for: recent)?.hint, "refresh")
    }

    func testRecoveryHintsAreCapped() throws {
        let store = FailureSignatureStore()
        let sig = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "button", targetLabel: "cap")
        for _ in 0..<5 { store.record(sig, recovery: "keep", succeeded: true) }
        for i in 0..<30 { store.record(sig, recovery: "hint \(i)", succeeded: true) }
        XCTAssertEqual(store.suggestion(for: sig)?.hint, "keep")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("store.json")
        try store.save(to: file)
        struct SavedEntry: Decodable { let hints: [String: Int] }
        struct SavedRow: Decodable { let entry: SavedEntry }
        let rows = try JSONDecoder().decode([SavedRow].self, from: Data(contentsOf: file))
        XCTAssertEqual(rows.count, 1)
        XCTAssertLessThanOrEqual(rows[0].entry.hints.count, 8)
        XCTAssertEqual(rows[0].entry.hints["keep"], 5)
    }

    private func riskSignature(tool: String = "click", label: String) -> FailureSignature {
        FailureSignature(appBundleID: "a", toolName: tool, failureCode: "timeout", targetRole: "button", targetLabel: label)
    }

    private func suggestionAfterTwoSuccesses(_ sig: FailureSignature, store: FailureSignatureStore = FailureSignatureStore()) -> String? {
        store.record(sig, recovery: "retry", succeeded: true)
        store.record(sig, recovery: "retry", succeeded: true)
        return store.suggestion(for: sig)?.hint
    }

    func testRiskyWordsAreRefusedInEnglishDutchGermanFrenchAndSpanish() {
        let words = [
            "Place order", "Purchase", "Checkout", "Confirm payment", "Pay now", "Submit", "Post", "Publish",
            "Transfer funds", "Delete", "Remove item", "Erase data", "Discard draft", "Unsubscribe", "Cancel subscription",
            "Verzenden", "Verstuur", "Stuur", "Betalen", "Bestellen", "Afrekenen", "Verwijderen", "Verwijder", "Overmaken", "Wis", "Koop nu",
            "Senden", "Kaufen", "Bezahlen", "Löschen", "Jetzt absenden",
            "Envoyer", "Acheter", "Payer", "Supprimer", "Paiement",
            "Enviar", "Comprar", "Pagar", "Eliminar",
        ]
        for word in words {
            XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(label: word)), "expected refusal for \(word)")
        }
        // The same signature shape with a safe label is suggested, so the refusals above are not vacuous.
        XCTAssertEqual(suggestionAfterTwoSuccesses(riskSignature(label: "Continue")), "retry")
    }

    func testRiskyToolNameIsRefused() {
        XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(tool: "purchase", label: "Continue")))
        XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(tool: "verzenden", label: "Continue")))
    }

    func testRiskWordMatchIgnoresCaseAndDiacritics() {
        XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(label: "VERZÉNDEN")))
        XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(label: "Löschen")))
        XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(label: "lôschen")))
    }

    func testHarmlessWordsContainingRiskStemsAreNotRefused() {
        XCTAssertEqual(suggestionAfterTwoSuccesses(riskSignature(label: "Display settings")), "retry")
        XCTAssertEqual(suggestionAfterTwoSuccesses(riskSignature(label: "Border")), "retry")
        XCTAssertEqual(suggestionAfterTwoSuccesses(riskSignature(label: "Wissel")), "retry")
    }

    func testInjectedRiskPredicateIsAppliedInAdditionToWordCheck() {
        let store = FailureSignatureStore { $0.targetLabel.contains("launch") }
        XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(label: "Launch rocket"), store: store))
        XCTAssertEqual(suggestionAfterTwoSuccesses(riskSignature(label: "Continue"), store: store), "retry")
        XCTAssertNil(suggestionAfterTwoSuccesses(riskSignature(label: "Purchase"), store: store))
    }

    func testConcurrentRecording() {
        let store = FailureSignatureStore()
        let sig = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "button", targetLabel: "go")
        DispatchQueue.concurrentPerform(iterations: 100) { _ in store.record(sig, recovery: "refresh", succeeded: true) }
        XCTAssertEqual(store.suggestion(for: sig)?.hint, "refresh")
    }
}
