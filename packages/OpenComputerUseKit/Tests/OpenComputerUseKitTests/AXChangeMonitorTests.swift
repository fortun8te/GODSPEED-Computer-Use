import ApplicationServices
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Uses a fake notification source only. No real AXObserver is created and no input is posted.
final class AXChangeMonitorTests: XCTestCase {
    private final class FakeSource: AXChangeMonitor.NotificationSource, @unchecked Sendable {
        private final class Sub: AXChangeMonitor.Subscription {
            private let lock = NSLock()
            private var done = false
            var cancelled: Bool { lock.withLock { done } }
            func cancel() { lock.withLock { done = true } }
        }

        private let lock = NSLock()
        private var handlers: [pid_t: [(String) -> Void]] = [:]
        private var subs: [pid_t: [Sub]] = [:]
        private(set) var subscribeCount = 0
        var refuses = false
        var afterSubscribe: (() -> Void)?

        func subscribe(pid: pid_t, names: [String], handler: @escaping (String) -> Void) -> AXChangeMonitor.Subscription? {
            let subscription: AXChangeMonitor.Subscription? = lock.withLock {
                subscribeCount += 1
                guard !refuses else { return nil }
                handlers[pid, default: []].append(handler)
                let sub = Sub()
                subs[pid, default: []].append(sub)
                return sub
            }
            let hook = afterSubscribe
            afterSubscribe = nil
            hook?()
            return subscription
        }

        func emit(_ pid: pid_t, _ name: String = kAXValueChangedNotification, subscription: Int? = nil) {
            let handler = lock.withLock { () -> ((String) -> Void)? in
                guard let registered = handlers[pid] else { return nil }
                return subscription.map { registered[$0] } ?? registered.last
            }
            handler?(name)
        }

        func cancelledCount(_ pid: pid_t) -> Int {
            lock.withLock { subs[pid, default: []].filter(\.cancelled).count }
        }
    }

    private final class Clock {
        var time: TimeInterval = 0
    }

    private func makeMonitor() -> (AXChangeMonitor, FakeSource, Clock) {
        let source = FakeSource()
        let clock = Clock()
        return (AXChangeMonitor(source: source, now: { clock.time }), source, clock)
    }

    func testNotificationEndsAWaitBeforeItsCap() {
        let (monitor, source, _) = makeMonitor()
        let token = monitor.track(42)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { source.emit(42) }
        let start = Date()
        let woke = monitor.awaitChange(pid: 42, since: token, upTo: 2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(woke)
        XCTAssertLessThan(elapsed, 1.0, "A notification should wake the wait well before its 2 s cap")
    }

    func testUntrackedAppNeverReportsAChangeOrWaitsForTheCap() {
        let (monitor, _, _) = makeMonitor()
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(monitor.awaitChange(pid: 42, since: 0, upTo: 1))
        XCTAssertFalse(monitor.awaitChange(pid: 42, since: 12, upTo: 1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.25)
    }

    func testCancellationInterruptsANotificationWaitWithoutReplacingItsCallback() {
        let (monitor, _, _) = makeMonitor()
        let token = monitor.track(42)
        let cancellation = RequestCancellation()
        let callback = expectation(description: "existing cancellation callback")
        cancellation.onCancel { _ in callback.fulfill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let changed = RequestCancellation.$current.withValue(cancellation) {
            monitor.awaitChange(pid: 42, since: token, upTo: 2)
        }
        XCTAssertFalse(changed)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.6)
        wait(for: [callback], timeout: 0.5)
    }

    func testLateObserverRegistrationAndCallbacksCannotReplaceARetrackedPID() {
        let (monitor, source, clock) = makeMonitor()
        source.afterSubscribe = {
            clock.time = 61
            monitor.sweepIdle()
            monitor.track(9)
        }
        let oldToken = monitor.track(9)
        let replacementToken = monitor.generation(9)
        XCTAssertNotEqual(oldToken, replacementToken)
        XCTAssertEqual(source.subscribeCount, 2)
        XCTAssertEqual(source.cancelledCount(9), 1, "The late old registration must be cancelled")

        source.emit(9, subscription: 0)
        XCTAssertEqual(monitor.generation(9), replacementToken)
        XCTAssertEqual(monitor.snapshot(9)?.notifications, 0)
        source.emit(9)
        XCTAssertEqual(monitor.snapshot(9)?.notifications, 1)

        clock.time = 122
        monitor.sweepIdle()
        XCTAssertEqual(source.cancelledCount(9), 2, "The replacement subscription must remain owned until its own sweep")
    }

    func testReadFromExpiredObserverCannotCleanAReplacementObserver() {
        let (monitor, source, clock) = makeMonitor()
        monitor.track(9)
        source.emit(9)
        let oldRead = monitor.generation(9)
        clock.time = 61
        monitor.track(9)
        source.emit(9)
        let newGeneration = monitor.generation(9)
        XCTAssertNotEqual(oldRead, newGeneration)
        monitor.finishRead(pid: 9, startedAt: oldRead, complete: true)
        XCTAssertEqual(monitor.snapshot(9)?.dirtySince, newGeneration)
        XCTAssertFalse(monitor.mayReuseQuietRead(pid: 9, purpose: .effectCheck))
    }

    func testReadinessPollWakesOnNotificationInsteadOfItsInterval() {
        let (monitor, source, _) = makeMonitor()
        monitor.track(77)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { source.emit(77) }
        var reads = 0
        let start = Date()
        let value = ReadinessPoll.first(timeout: 3, interval: 1, pid: 77, monitor: monitor) { () -> String? in
            reads += 1
            return reads == 2 ? "ready" : nil
        }
        XCTAssertEqual(value, "ready")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6, "A 1 s poll interval should end at the notification")
    }

    func testCancellationDuringObserverSetupSkipsReadinessAndSettleReads() {
        let (monitor, source, _) = makeMonitor()
        let cancellation = RequestCancellation()
        source.afterSubscribe = { cancellation.cancel() }
        var reads = 0
        let value: String? = RequestCancellation.$current.withValue(cancellation) {
            ReadinessPoll.first(timeout: 1, pid: 77, monitor: monitor) {
                reads += 1
                return "ready"
            }
        }
        XCTAssertNil(value)
        XCTAssertEqual(reads, 0)

        let settleCancellation = RequestCancellation()
        source.afterSubscribe = { settleCancellation.cancel() }
        let settled = RequestCancellation.$current.withValue(settleCancellation) {
            WindowSettle.wait(timeout: 1, pid: 78, monitor: monitor) {
                reads += 1
                return false
            }
        }
        XCTAssertFalse(settled)
        XCTAssertEqual(reads, 0)
    }

    func testSilentAppFallsBackToPollingWithTheSameCap() {
        let (monitor, _, clock) = makeMonitor()
        let token = monitor.track(7)
        monitor.noteAction(7)
        clock.time = 1
        XCTAssertEqual(monitor.support(7), .unknown, "Still inside the 2 s grace window")
        clock.time = 2.5
        XCTAssertEqual(monitor.support(7), .silent)
        let start = Date()
        XCTAssertFalse(monitor.awaitChange(pid: 7, since: token, upTo: 0.1))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09, "A silent app keeps its full poll sleep")
        XCTAssertFalse(monitor.mayReuseQuietRead(pid: 7, purpose: .effectCheck), "A silent app is never trusted as quiet")
    }

    func testNotifyingAppKeepsNotifyingWhenItAnswersWithinTheGrace() {
        let (monitor, source, clock) = makeMonitor()
        monitor.track(8)
        monitor.noteAction(8)
        clock.time = 0.5
        source.emit(8)
        clock.time = 5
        XCTAssertEqual(monitor.support(8), .notifying)
    }

    func testDispatchNotificationPreservesSupportButRequiresAReadAfterDelivery() {
        let (monitor, source, clock) = makeMonitor()
        let beforeAction = monitor.track(8)
        // Dispatch includes preparation: this event and tracked read can precede
        // the actual input, so neither establishes its later visible effects.
        source.emit(8)
        let observedAfter = monitor.generation(8)
        monitor.finishRead(pid: 8, startedAt: observedAfter, complete: true)
        monitor.noteAction(8, startedAt: beforeAction, deliveryState: .acknowledged)
        XCTAssertFalse(monitor.mayReuseQuietRead(pid: 8, purpose: .effectCheck),
                       "A delivered action invalidates a clean read made before noteAction")
        monitor.finishRead(pid: 8, startedAt: observedAfter, complete: true)
        XCTAssertTrue(monitor.mayReuseQuietRead(pid: 8, purpose: .effectCheck),
                      "A fresh read after delivery may be reused without another notification")
        clock.time = 3
        XCTAssertEqual(monitor.support(8), .notifying,
                       "A synchronous event must not be forgotten when dispatch returns")
    }

    func testUnsentOrUncertainActionDoesNotStartANotificationGraceWait() {
        let (monitor, source, clock) = makeMonitor()
        monitor.track(8)
        source.emit(8)
        let token = monitor.generation(8)
        monitor.finishRead(pid: 8, startedAt: token, complete: true)
        for delivery in [DeliveryState.notSent, .outcomeUnknown] {
            monitor.noteAction(8, startedAt: token, deliveryState: delivery)
            XCTAssertTrue(monitor.mayReuseQuietRead(pid: 8, purpose: .effectCheck))
        }
        clock.time = 3
        XCTAssertEqual(monitor.support(8), .notifying)
    }

    func testIdleAppLosesItsObserverAfterSixtySeconds() {
        let (monitor, source, clock) = makeMonitor()
        monitor.track(9)
        XCTAssertEqual(source.subscribeCount, 1)
        clock.time = 59
        monitor.sweepIdle()
        XCTAssertEqual(source.cancelledCount(9), 0)
        monitor.track(9)
        clock.time = 118
        monitor.sweepIdle()
        XCTAssertEqual(source.cancelledCount(9), 0, "Use at 59 s counts as activity")
        clock.time = 120
        monitor.sweepIdle()
        XCTAssertEqual(source.cancelledCount(9), 1)
        XCTAssertNil(monitor.snapshot(9))
        monitor.track(9)
        XCTAssertEqual(source.subscribeCount, 2, "A returning app gets a fresh observer")
    }

    func testDirtyFlagResetsOnlyForAReadThatSawTheGeneration() {
        let (monitor, source, _) = makeMonitor()
        let token = monitor.track(5)
        XCTAssertEqual(token, 0)
        source.emit(5, kAXValueChangedNotification)
        var snapshot = monitor.snapshot(5)
        XCTAssertEqual(snapshot?.generation, 1)
        XCTAssertEqual(snapshot?.dirtySince, 1)
        XCTAssertEqual(snapshot?.reason, "value")

        // A read that started before the notification does not clear it.
        monitor.finishRead(pid: 5, startedAt: 0, complete: true)
        XCTAssertEqual(monitor.snapshot(5)?.dirtySince, 1)

        monitor.finishRead(pid: 5, startedAt: 1, complete: true)
        snapshot = monitor.snapshot(5)
        XCTAssertNil(snapshot?.dirtySince)
        XCTAssertNil(snapshot?.reason)

        // A read started at generation 1 that finishes after a second notification stays dirty.
        source.emit(5, kAXFocusedUIElementChangedNotification)
        monitor.finishRead(pid: 5, startedAt: 1, complete: true)
        snapshot = monitor.snapshot(5)
        XCTAssertEqual(snapshot?.dirtySince, 2)
        XCTAssertEqual(snapshot?.reason, "focus")
        XCTAssertEqual(snapshot?.notifications, 2)
    }

    func testQuietRemainsReusableOnlyForEffectChecksAfterACompleteRead() {
        let (monitor, source, _) = makeMonitor()
        monitor.track(3)
        source.emit(3)
        let token = monitor.generation(3)
        monitor.finishRead(pid: 3, startedAt: token, complete: true)
        XCTAssertTrue(monitor.mayReuseQuietRead(pid: 3, purpose: .effectCheck))
        XCTAssertFalse(monitor.mayReuseQuietRead(pid: 3, purpose: .doneProof),
                       "A done_when proof always reads the app")

        source.emit(3)
        XCTAssertFalse(monitor.mayReuseQuietRead(pid: 3, purpose: .effectCheck), "A notification since the read")
    }

    func testIncompleteReadIsNeverReused() {
        let (monitor, source, _) = makeMonitor()
        monitor.track(4)
        source.emit(4)
        monitor.finishRead(pid: 4, startedAt: monitor.generation(4), complete: false)
        XCTAssertFalse(monitor.mayReuseQuietRead(pid: 4, purpose: .effectCheck))
    }

    func testRefusedSubscriptionStaysOnPolling() {
        let (monitor, source, _) = makeMonitor()
        source.refuses = true
        let token = monitor.track(11)
        XCTAssertEqual(monitor.support(11), .unknown)
        XCTAssertFalse(monitor.awaitChange(pid: 11, since: token, upTo: 0.05))
        XCTAssertFalse(monitor.mayReuseQuietRead(pid: 11, purpose: .effectCheck))
    }

    func testNotificationReasonsAreCoarse() {
        XCTAssertEqual(AXChangeMonitor.reason(for: kAXSheetCreatedNotification), "sheet")
        XCTAssertEqual(AXChangeMonitor.reason(for: kAXMainWindowChangedNotification), "window")
        XCTAssertEqual(AXChangeMonitor.reason(for: "AXSomethingElse"), "other")
    }
}
