import Foundation
import XCTest
@testable import OpenComputerUseKit

final class LocalDecisionCancellationTests: XCTestCase {
    private let loopback = URL(string: "http://127.0.0.1:18765")!
    private let arguments: [String: Any] = [
        "role": "recover", "state": ["status": "synthetic transaction receipt"],
        "question": ["type": "choice", "instructions": "What evidence should be collected?",
                     "criteria": ["inspect": "Inspect the output", "pause": "Pause"]]
    ]
    private let goodScore: [String: Any] = [
        "model": "gsd1-recover", "probs": ["inspect": 0.95, "pause": 0.05]
    ]

    func testCancelledBeforeInferenceDoesNotCallScorer() throws {
        let cancel = RequestCancellation()
        cancel.cancel()
        var calls = 0
        XCTAssertThrowsError(try RequestCancellation.$current.withValue(cancel) {
            try LocalDecisionTool.run(arguments: arguments, baseURL: loopback, now: { 100 },
                                      recoverHelper: { _ in XCTFail("unexpected helper start") }) { _, _, _ in
                calls += 1
                return self.goodScore
            }
        }) {
            XCTAssertEqual(($0 as? RequestCancellation.Cancelled)?.deliveryState, .notSent)
        }
        XCTAssertEqual(calls, 0)
    }

    func testCancellationWhileScoringDiscardsAdviceOrUnavailableSideEffect() throws {
        for reply in [goodScore, nil] {
            let cancel = RequestCancellation()
            var calls = 0
            var recoveries = 0
            XCTAssertThrowsError(try RequestCancellation.$current.withValue(cancel) {
                try LocalDecisionTool.run(arguments: arguments, baseURL: loopback, now: { 100 },
                                          recoverHelper: { _ in recoveries += 1 }) { _, _, _ in
                    calls += 1
                    cancel.cancel()
                    return reply
                }
            }) {
                XCTAssertEqual(($0 as? RequestCancellation.Cancelled)?.deliveryState, .notSent)
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(recoveries, 0)
        }
    }

    func testExpiredScoreIsNotAdviceOrReasonToStartHelper() throws {
        for reply in [goodScore, nil] {
            var time: TimeInterval = 100
            var recoveries = 0
            let result = try LocalDecisionTool.run(arguments: arguments, baseURL: loopback, now: { time },
                                                   recoverHelper: { _ in recoveries += 1 }) { _, _, timeout in
                time += timeout + 0.001
                return reply
            }
            XCTAssertEqual(result.deliveryState, .notSent)
            XCTAssertTrue(result.primaryText?.hasPrefix("No local recommendation.") == true)
            XCTAssertTrue(result.primaryText?.contains("deadline") == true)
            XCTAssertEqual(recoveries, 0)
        }
    }

    func testTimelyAdviceAndUnavailableRecoveryRemainUnchanged() throws {
        var recoveries = 0
        let timely = try LocalDecisionTool.run(arguments: arguments, baseURL: loopback, now: { 100 },
                                               recoverHelper: { _ in recoveries += 1 }) { _, _, _ in goodScore }
        XCTAssertEqual(timely.primaryText, "GSD1 recover suggests inspect (95%).")
        XCTAssertEqual(timely.deliveryState, .notSent)
        XCTAssertEqual(recoveries, 0)
        _ = try LocalDecisionTool.run(arguments: arguments, baseURL: loopback, now: { 100 },
                                      recoverHelper: { _ in recoveries += 1 }) { _, _, _ in nil }
        XCTAssertEqual(recoveries, 1)
    }
}
