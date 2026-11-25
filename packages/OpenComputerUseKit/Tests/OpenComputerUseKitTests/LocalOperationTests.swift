import AppKit
import XCTest
@testable import OpenComputerUseKit

final class LocalOperationTests: XCTestCase {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ value: Value) { storage = value }
        var value: Value {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private func assertFailure(_ error: Error, delivery: DeliveryState, code: TrajectoryLog.FailureCode? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        let result = ToolCallResult.failure(error)
        XCTAssertEqual(result.deliveryState, delivery, file: file, line: line)
        if let code { XCTAssertEqual(result.failureCode, code, file: file, line: line) }
    }

    func testCancelledWorkspaceRequestNeverDispatches() {
        let cancellation = RequestCancellation()
        cancellation.cancel()
        RequestCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try SmartSteps.openWorkspace { _ in XCTFail("Must not open after cancellation") }) {
                self.assertFailure($0, delivery: .notSent)
            }
        }
    }

    func testExpiredWorkspaceRequestNeverDispatches() {
        BrowserCallBudget.withDeadline(ProcessInfo.processInfo.systemUptime - 1) {
            XCTAssertThrowsError(try SmartSteps.openWorkspace { _ in XCTFail("Must not open after deadline") }) {
                self.assertFailure($0, delivery: .notSent, code: .timeout)
            }
        }
    }

    func testCancelledSaveStopsBeforeResolvingOrTouchingAnApplication() {
        let cancellation = RequestCancellation()
        cancellation.cancel()
        RequestCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try SmartSteps.saveAs(app: "no-running-application", path: "/tmp/test.txt",
                                                      service: ComputerUseService())) {
                XCTAssertTrue($0 is RequestCancellation.Cancelled)
                self.assertFailure($0, delivery: .notSent)
            }
        }
    }

    func testExpiredSaveStopsBeforeResolvingOrTouchingAnApplication() {
        BrowserCallBudget.withDeadline(ProcessInfo.processInfo.systemUptime - 1) {
            XCTAssertThrowsError(try SmartSteps.saveAs(app: "no-running-application", path: "/tmp/test.txt",
                                                      service: ComputerUseService())) {
                self.assertFailure($0, delivery: .notSent, code: .timeout)
            }
        }
    }

    func testWorkspaceCancellationRejectsEvenAnAvailableSuccess() {
        let cancellation = RequestCancellation()
        RequestCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try SmartSteps.openWorkspace { done in
                cancellation.cancel()
                done(nil)
            }) {
                self.assertFailure($0, delivery: .outcomeUnknown)
            }
        }
    }

    func testWorkspaceCallbackFailureKeepsUncertainDelivery() {
        XCTAssertThrowsError(try SmartSteps.openWorkspace { done in
            done(NSError(domain: "workspace", code: 1))
        }) {
            self.assertFailure($0, delivery: .outcomeUnknown)
        }
    }

    func testDuplicateWorkspaceCallbackCannotReplaceFirstCompletion() throws {
        try SmartSteps.openWorkspace { done in
            done(nil)
            done(NSError(domain: "late-callback", code: 2))
        }
    }

    func testInheritedDeadlineBoundsWorkspaceCallbackWait() {
        let began = ProcessInfo.processInfo.systemUptime
        BrowserCallBudget.withDeadline(began + 0.025) {
            XCTAssertThrowsError(try SmartSteps.openWorkspace(timeout: 5) { _ in }) {
                self.assertFailure($0, delivery: .outcomeUnknown, code: .timeout)
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1,
                          "A short enclosing budget must not wait for the five-second workspace timeout")
    }

    func testLocalOperationRejectsCompletionAtItsDeadline() throws {
        let clock = Box<TimeInterval>(100)
        let operation = try LocalOperation<String>(timeout: 1, action: "test", now: { clock.value })
        try operation.begin()
        clock.value = 101
        operation.complete(.success("late"))
        XCTAssertThrowsError(try operation.wait()) {
            self.assertFailure($0, delivery: .outcomeUnknown, code: .timeout)
        }
    }

    func testAppleEventPermissionPreparationCannotConsumeBudgetThenDispatch() {
        let cancellation = RequestCancellation()
        RequestCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try AppleEventsGate.send("return 1", bundle: "test", permission: { _ in
                cancellation.cancel()
                return true
            }, schedule: { _ in XCTFail("Cancelled permission preparation must not schedule work") })) {
                self.assertFailure($0, delivery: .notSent)
            }
        }
    }

    func testDeniedPermissionAfterCancellationCannotTriggerFallback() {
        let cancellation = RequestCancellation()
        RequestCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try AppleEventsGate.send("return 1", bundle: "test", permission: { _ in
                cancellation.cancel()
                return false
            }, schedule: { _ in XCTFail("Denied permission must not schedule work") })) {
                self.assertFailure($0, delivery: .notSent)
            }
        }
    }

    func testAppleEventWorkerCannotStartAfterCallerTimesOut() {
        let worker = Box<(@Sendable () -> Void)?>(nil)
        let executions = Box(0)
        XCTAssertThrowsError(try AppleEventsGate.send("return 1", bundle: "test", limit: 0.05,
            permission: { _ in true }, schedule: { worker.value = $0 }, execute: { _ in
                executions.value += 1
                return NSAppleEventDescriptor(int32: 1)
            })) {
            self.assertFailure($0, delivery: .notSent, code: .timeout)
        }
        XCTAssertNotNil(worker.value, "The regression must exercise a scheduled worker, not an earlier preparation timeout")
        worker.value?()
        XCTAssertEqual(executions.value, 0, "A delayed worker must not mutate an app after the request has ended")
    }

    func testAppleEventWorkerKeepsRequestContext() throws {
        let cancellation = RequestCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let reply = try RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_BACKGROUND_ONLY": "1"]) {
            try RequestCancellation.$current.withValue(cancellation) {
                try BrowserCallBudget.withDeadline(deadline) {
                    try AppleEventsGate.send("return 4", bundle: "test", permission: { _ in true }, execute: { source in
                        XCTAssertTrue(RequestCancellation.current === cancellation)
                        XCTAssertEqual(BrowserCallBudget.activeDeadline, deadline)
                        XCTAssertEqual(RequestConfiguration.environment["OPEN_COMPUTER_USE_BACKGROUND_ONLY"], "1")
                        XCTAssertTrue(source.hasPrefix("with timeout of "))
                        return NSAppleEventDescriptor(int32: 4)
                    })
                }
            }
        }
        XCTAssertEqual(reply?.int32Value, 4)
    }

    func testCancelledAppleEventSuccessIsUncertainAndNeverRetried() {
        let cancellation = RequestCancellation()
        let executions = Box(0)
        RequestCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try AppleEventsGate.send("return 1", bundle: "test", permission: { _ in true },
                schedule: { $0() }, execute: { _ in
                    executions.value += 1
                    cancellation.cancel()
                    return NSAppleEventDescriptor(int32: 1)
                })) {
                self.assertFailure($0, delivery: .outcomeUnknown)
            }
        }
        XCTAssertEqual(executions.value, 1)
    }

    func testInvalidAppleEventBudgetsDoNotConsultPermissionOrSchedule() {
        for limit in [0.0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try AppleEventsGate.send("return 1", bundle: "test", limit: limit,
                permission: { _ in XCTFail("Invalid budget must not ask for permission"); return true },
                schedule: { _ in XCTFail("Invalid budget must not schedule work") })) {
                self.assertFailure($0, delivery: .notSent, code: .timeout)
            }
        }
    }
}
