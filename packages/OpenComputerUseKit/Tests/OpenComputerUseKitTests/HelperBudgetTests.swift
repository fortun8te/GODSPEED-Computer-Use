import Foundation
import XCTest
@testable import OpenComputerUseKit

final class HelperBudgetTests: XCTestCase {
    private let url = URL(string: "http://127.0.0.1:8765")!
    private let enabled = [ModelHelperPolicy.environmentKey: "1"]
    private let answer = Data(#"{"ok":true}"#.utf8)

    // All callbacks in these tests run synchronously. The reference also permits
    // the production @Sendable admission/scheduling interfaces without globals.
    private final class Probe: @unchecked Sendable {
        var time: TimeInterval = 100
        var released = 0
        var reacquired = 0
        var sends = 0
        var queued = 0
        var healthChecks = 0
    }

    private func starter() -> HelperAutoStarter {
        HelperAutoStarter(launcher: URL(fileURLWithPath: "/nonexistent/godspeed-budget-launcher"),
                          log: URL(fileURLWithPath: "/nonexistent/godspeed-budget-log"), managedPort: 8765)
    }

    func testBudgetRejectsInvalidTimeoutsAndExpiredInheritedDeadlines() {
        for timeout in [0, -1, Double.infinity, Double.nan] {
            XCTAssertNil(HelperHTTP.Budget(timeout: timeout, now: 100, inheritedDeadline: nil))
        }
        for deadline in [99, 100, Double.infinity, Double.nan] {
            XCTAssertNil(HelperHTTP.Budget(timeout: 5, now: 100, inheritedDeadline: deadline))
        }
        XCTAssertEqual(HelperHTTP.Budget(timeout: 8, now: 100, inheritedDeadline: 102)?.deadline, 102)
        XCTAssertEqual(HelperHTTP.Budget(timeout: 1, now: 100, inheritedDeadline: 102)?.deadline, 101)
    }

    func testExpiredPostDoesNotReleaseAdmissionOrSubmitHTTP() {
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(100) {
                RequestInferenceAdmission.$withoutExclusive.withValue({ _ in
                    XCTFail("Expired helper work must retain admission")
                    return nil
                }) {
                    XCTAssertNil(HelperHTTP.postJSON(url, body: ["goal": "Fixture"], timeout: 8,
                        now: { 100 }, transport: { _, _, _, _ in
                            XCTFail("Expired helper work must not send HTTP")
                            return nil
                        }))
                }
            }
        }
    }

    func testEncodingTimeIsIncludedBeforeAdmissionRelease() {
        var clockReads = 0
        RequestConfiguration.withEnvironment(enabled) {
            RequestInferenceAdmission.$withoutExclusive.withValue({ _ in
                XCTFail("The budget ended during request preparation")
                return nil
            }) {
                XCTAssertNil(HelperHTTP.postJSON(url, body: ["goal": "Fixture"], timeout: 5,
                    now: { clockReads += 1; return clockReads == 1 ? 100 : 105 },
                    transport: { _, _, _, _ in XCTFail("Late preparation must not send"); return nil }))
            }
        }
    }

    func testExpiryInsideAdmissionHandoffSkipsTransportAndBalancesTheGate() {
        let probe = Probe()
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(105) {
                RequestInferenceAdmission.$withoutExclusive.withValue({ work in
                    probe.released += 1
                    defer { probe.reacquired += 1 }
                    probe.time = 105
                    return work()
                }) {
                    XCTAssertNil(HelperHTTP.postJSON(url, body: [:], timeout: 8, now: { probe.time },
                        transport: { _, _, _, _ in probe.sends += 1; return self.answer }))
                }
            }
        }
        XCTAssertEqual(probe.released, 1)
        XCTAssertEqual(probe.reacquired, 1)
        XCTAssertEqual(probe.sends, 0)
    }

    func testAdmissionTimeReducesTheActualHTTPTimeout() {
        let probe = Probe()
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(105) {
                RequestInferenceAdmission.$withoutExclusive.withValue({ work in
                    probe.time = 103
                    return work()
                }) {
                    let reply = HelperHTTP.postJSON(url, body: [:], timeout: 8, followRedirects: false,
                        now: { probe.time }, transport: { request, remaining, protected, busy in
                            probe.sends += 1
                            XCTAssertEqual(remaining, 2, accuracy: 0.001)
                            XCTAssertEqual(request.timeoutInterval, remaining)
                            XCTAssertTrue(protected)
                            XCTAssertTrue(busy)
                            return self.answer
                        })
                    XCTAssertEqual(reply?["ok"] as? Bool, true)
                }
            }
        }
        XCTAssertEqual(probe.sends, 1)
    }

    func testReplyIsDiscardedWhenAdmissionReacquisitionEndsTheBudget() {
        let probe = Probe()
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(105) {
                RequestInferenceAdmission.$withoutExclusive.withValue({ work in
                    let result = work()
                    probe.time = 105
                    probe.reacquired += 1
                    return result
                }) {
                    XCTAssertNil(HelperHTTP.postJSON(url, body: [:], timeout: 8, now: { probe.time },
                        transport: { _, _, _, _ in probe.sends += 1; return self.answer }))
                }
            }
        }
        XCTAssertEqual(probe.sends, 1)
        XCTAssertEqual(probe.reacquired, 1)
    }

    func testCancellationDuringTransportDiscardsReplyAndBalancesTheGate() {
        let probe = Probe()
        let cancellation = RequestCancellation()
        RequestConfiguration.withEnvironment(enabled) {
            RequestCancellation.$current.withValue(cancellation) {
                RequestInferenceAdmission.$withoutExclusive.withValue({ work in
                    probe.released += 1
                    defer { probe.reacquired += 1 }
                    return work()
                }) {
                    XCTAssertNil(HelperHTTP.postJSON(url, body: [:], timeout: 8, now: { probe.time },
                        transport: { _, _, _, _ in cancellation.cancel(); return self.answer }))
                }
            }
        }
        XCTAssertEqual(probe.released, 1)
        XCTAssertEqual(probe.reacquired, 1)
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testExpiredGETAndHealthCheckReturnWithoutTransport() {
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(0) {
                XCTAssertNil(HelperHTTP.getJSON(url, timeout: 8))
                XCTAssertFalse(HelperHTTP.isHealthy(url, timeout: 8))
            }
        }
    }

    func testExpiredRecoveryDoesNotScheduleOrConsumeCooldown() {
        let starter = starter()
        let probe = Probe()
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(100) {
                starter.helperUnreachable(url, now: 10, schedule: { _ in probe.queued += 1 },
                                          requestClock: { probe.time })
            }
            starter.helperUnreachable(url, now: 10, schedule: { _ in probe.queued += 1 })
        }
        XCTAssertEqual(probe.queued, 1, "The expired call must not consume the first probe's cooldown")
    }

    func testQueuedRecoveryExpiryRestoresItsCooldownAndNeverProbes() {
        let starter = starter()
        let probe = Probe()
        var work: (@Sendable () -> Void)?
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(105) {
                starter.helperUnreachable(url, now: 10, schedule: { work = $0 }, healthCheck: { _ in
                    probe.healthChecks += 1
                    return true
                }, requestClock: { probe.time })
            }
            XCTAssertNotNil(work)
            probe.time = 105
            work?()
            starter.helperUnreachable(url, now: 10, schedule: { _ in probe.queued += 1 })
        }
        XCTAssertEqual(probe.healthChecks, 0)
        XCTAssertEqual(probe.queued, 1, "A probe that never started must release its cooldown reservation")
    }

    func testWorkerRestoresInheritedDeadlineAndKeepsCooldownOnceProbeStarts() {
        let starter = starter()
        let probe = Probe()
        var work: (@Sendable () -> Void)?
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(105) {
                starter.helperUnreachable(url, now: 10, schedule: { work = $0 }, healthCheck: { _ in
                    XCTAssertEqual(BrowserCallBudget.activeDeadline, 105)
                    probe.healthChecks += 1
                    probe.time = 105
                    return false
                }, requestClock: { probe.time })
            }
            BrowserCallBudget.withDeadline(200) {
                work?()
                XCTAssertEqual(BrowserCallBudget.activeDeadline, 200)
            }
            starter.helperUnreachable(url, now: 10, schedule: { _ in probe.queued += 1 })
        }
        XCTAssertEqual(probe.healthChecks, 1)
        XCTAssertEqual(probe.queued, 0, "A health request actually ran, so its cooldown remains")
    }

    func testAnExpiredOldWorkerCannotClearANewerProbeReservation() {
        let starter = starter()
        let probe = Probe()
        var oldWork: (@Sendable () -> Void)?
        var newWork: (@Sendable () -> Void)?
        RequestConfiguration.withEnvironment(enabled) {
            BrowserCallBudget.withDeadline(105) {
                starter.helperUnreachable(url, now: 10, schedule: { oldWork = $0 }, requestClock: { probe.time })
            }
            starter.helperUnreachable(url, now: 70, schedule: { newWork = $0 }, healthCheck: { _ in
                probe.healthChecks += 1
                return true
            })
            probe.time = 105
            oldWork?()
            starter.helperUnreachable(url, now: 70, schedule: { _ in probe.queued += 1 })
            newWork?()
        }
        XCTAssertEqual(probe.queued, 0)
        XCTAssertEqual(probe.healthChecks, 1)
    }

    func testExpiredWarmupDoesNotReserveCooldownOrSend() {
        var environment = enabled
        environment["OPEN_COMPUTER_USE_REFEREE_URL"] = url.absoluteString
        RequestConfiguration.withEnvironment(environment) {
            BrowserCallBudget.withDeadline(100) {
                Referee.warmInBackground(now: 10, requestClock: { 100 }, reserveWarmup: { _ in
                    XCTFail("An expired warmup must not consume cooldown")
                    return true
                }, send: { _, _ in XCTFail("An expired warmup must not send") })
            }
        }
    }

    func testWarmupUsesInheritedRemainderAndRestoresCallbackDeadline() {
        let probe = Probe()
        let cancellation = RequestCancellation()
        var environment = enabled
        environment["OPEN_COMPUTER_USE_REFEREE_URL"] = url.absoluteString
        var completion: (@Sendable (Bool) -> Void)?
        RequestConfiguration.withEnvironment(environment) {
            RequestCancellation.$current.withValue(cancellation) {
                BrowserCallBudget.withDeadline(100.25) {
                    Referee.warmInBackground(now: 10, requestClock: { probe.time }, reserveWarmup: { _ in true },
                        recoverHelper: { _ in
                            XCTAssertEqual(BrowserCallBudget.activeDeadline, 100.25)
                            XCTAssertTrue(RequestCancellation.current === cancellation)
                            XCTAssertTrue(ModelHelperPolicy.isEnabled)
                            probe.healthChecks += 1
                        }, send: { request, done in
                            XCTAssertEqual(request.timeoutInterval, 0.25, accuracy: 0.001)
                            XCTAssertEqual(request.url?.path, "/warm")
                            completion = done
                        })
                }
            }
        }
        RequestConfiguration.withEnvironment([ModelHelperPolicy.environmentKey: "0"]) {
            BrowserCallBudget.withDeadline(200) {
                completion?(false)
                XCTAssertEqual(BrowserCallBudget.activeDeadline, 200)
                XCTAssertNil(RequestCancellation.current)
                XCTAssertFalse(ModelHelperPolicy.isEnabled)
                probe.time = 100.25
                completion?(false)
            }
        }
        XCTAssertEqual(probe.healthChecks, 1, "A failure callback after the originating deadline must not recover")
    }
}
