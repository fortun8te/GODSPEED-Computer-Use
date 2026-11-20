import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Recovery hints on failed native steps: a hint is named only after it has worked, its success is recorded from the
/// next step, and send/pay/delete-type steps never record or receive one.
final class FailureHintWiringTests: XCTestCase {
    private func signature(tool: String = "click", label: String = "Continue") -> FailureSignature {
        FailureSignature(appBundleID: "com.example.app", toolName: tool, failureCode: "timeout", targetRole: "button", targetLabel: label)
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testHintIsAppendedOnlyAfterItHasWorkedTwiceAndStaysOneLine() {
        let store = FailureSignatureStore()
        let tracker = FailureHintTracker(store: store, save: {})
        let plain = ComputerUseError.timedOut("The button did not respond.", delivery: .notSent)
        // No history: no hint.
        let fresh = signature(label: "Fresh")
        XCTAssertEqual(tracker.recordFailure(fresh, error: plain).localizedDescription, plain.localizedDescription)

        // Two successes that followed "refresh": the next failure names it. The failure itself counts too (2 > 1).
        let sig = signature()
        store.record(sig, recovery: "refresh", succeeded: true)
        store.record(sig, recovery: "refresh", succeeded: true)
        let after = tracker.recordFailure(sig, error: plain).localizedDescription
        XCTAssertEqual(after, plain.localizedDescription + "\nHint: refresh.")
        XCTAssertEqual(after.components(separatedBy: "\n").count, 2)
    }

    func testHintSuccessIsRecordedFromTheNextSuccessfulStep() {
        let store = FailureSignatureStore()
        let tracker = FailureHintTracker(store: store, save: {})
        let sig = signature()
        store.record(sig, recovery: "refresh", succeeded: true)
        store.record(sig, recovery: "refresh", succeeded: true)
        _ = tracker.recordFailure(sig, error: .notSent("busy"))
        // Two successes and one failure so far: 2 / 3.
        XCTAssertEqual(store.suggestion(for: sig)?.confidence ?? -1, 2.0 / 3.0, accuracy: 1e-9)

        tracker.recordSuccess()
        // The next step succeeded after following the hint: 3 / 4.
        XCTAssertEqual(store.suggestion(for: sig)?.confidence ?? -1, 0.75, accuracy: 1e-9)

        // Nothing is pending any more, so another success changes nothing.
        tracker.recordSuccess()
        XCTAssertEqual(store.suggestion(for: sig)?.confidence ?? -1, 0.75, accuracy: 1e-9)
    }

    func testAFailedNextStepCancelsThePendingHint() {
        let store = FailureSignatureStore()
        let tracker = FailureHintTracker(store: store, save: {})
        let sig = signature()
        store.record(sig, recovery: "refresh", succeeded: true)
        store.record(sig, recovery: "refresh", succeeded: true)
        _ = tracker.recordFailure(sig, error: .notSent("busy"))
        _ = tracker.recordFailure(sig, error: .notSent("still busy"))
        tracker.recordSuccess()
        // Two successes against two failures: the hint is no longer named and was not credited.
        XCTAssertNil(store.suggestion(for: sig))
    }

    func testSendPayAndDeleteStepsNeverRecordOrReceiveHints() {
        let store = FailureSignatureStore()
        let tracker = FailureHintTracker(store: store, save: {})
        for label in ["Send", "Pay now", "Delete"] {
            let sig = signature(label: label)
            tracker.recordSuccess()
            store.record(sig, recovery: "retry", succeeded: true)
            store.record(sig, recovery: "retry", succeeded: true)
            let message = tracker.recordFailure(sig, error: .notSent("failed")).localizedDescription
            XCTAssertEqual(message, "failed", "\(label) received a hint")
            XCTAssertNil(store.suggestion(for: sig))
        }
        let riskyTool = signature(tool: "purchase", label: "Continue")
        _ = tracker.recordFailure(riskyTool, error: .notSent("x"))
        XCTAssertNil(store.suggestion(for: riskyTool))
    }

    func testAnnotationKeepsTheKindAndDeliveryState() {
        let acknowledged = ComputerUseError.timedOut("late", delivery: .acknowledged).annotated(with: "Hint: retry.")
        XCTAssertEqual(acknowledged.deliveryState, .acknowledged)
        XCTAssertEqual(acknowledged.localizedDescription, "late\nHint: retry.")
        XCTAssertEqual(ComputerUseError.notSent("a").annotated(with: "Hint: b.").deliveryState, .notSent)
        XCTAssertEqual(ComputerUseError.staleRef.annotated(with: "Hint: b.").localizedDescription, ComputerUseError.staleRef.localizedDescription)
    }

    func testLearnedHintsSurviveARestartThroughAdaptiveLearning() throws {
        let dir = try tempDirectory()
        let sig = signature()
        let first = AdaptiveLearning(directory: dir)
        first.failures.record(sig, recovery: "refresh", succeeded: true)
        first.failures.record(sig, recovery: "refresh", succeeded: true)
        first.saveFailures()

        let second = AdaptiveLearning(directory: dir)
        XCTAssertEqual(second.failures.suggestion(for: sig)?.hint, "refresh")
        XCTAssertEqual(second.hints.recordFailure(sig, error: .notSent("busy")).localizedDescription, "busy\nHint: refresh.")
    }
}
