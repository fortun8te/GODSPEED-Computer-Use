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
        for i in 0...1_000 {
            let sig = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "button", targetLabel: "item \(i)")
            loaded.record(sig, recovery: nil, succeeded: false, now: base.addingTimeInterval(Double(i + 2)))
        }
        let oldest = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "button", targetLabel: "item 0")
        XCTAssertNil(loaded.suggestion(for: oldest))
    }

    func testConcurrentRecording() {
        let store = FailureSignatureStore()
        let sig = FailureSignature(appBundleID: "a", toolName: "read", failureCode: "x", targetRole: "button", targetLabel: "go")
        DispatchQueue.concurrentPerform(iterations: 100) { _ in store.record(sig, recovery: "refresh", succeeded: true) }
        XCTAssertEqual(store.suggestion(for: sig)?.hint, "refresh")
    }
}
