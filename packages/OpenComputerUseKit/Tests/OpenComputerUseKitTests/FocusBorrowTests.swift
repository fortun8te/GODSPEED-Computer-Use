import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure tests for the focus borrow: which menu titles open a dialog, the on/off setting, and the
/// nesting and restore bookkeeping with a fake activator. Nothing here activates an app or touches the screen.
final class FocusBorrowTests: XCTestCase {
    override func setUp() { FocusBorrowController.idleSecondsForTests = .infinity }
    override func tearDown() { FocusBorrowController.idleSecondsForTests = nil }

    /// Records activations and simulates the frontmost app.
    private final class FakeActivator: FocusActivating {
        var front: pid_t?
        var alive: Set<pid_t>
        var refuse: Set<pid_t> = []
        private(set) var activations: [pid_t] = []

        init(front: pid_t?, alive: Set<pid_t>) {
            self.front = front
            self.alive = alive
        }

        func frontmostPID() -> pid_t? { front }

        func isAlive(pid: pid_t) -> Bool { alive.contains(pid) }

        var typing = false

        func activate(pid: pid_t) -> Bool {
            activations.append(pid)
            guard !refuse.contains(pid) else { return false }
            front = pid
            return true
        }

        func waitForTypingPause() -> Bool { !typing }
    }

    private let user: pid_t = 100
    private let appA: pid_t = 200
    private let appB: pid_t = 300

    // MARK: - Which titles open a dialog

    func testDialogTitlesWithEllipsisOrNamedDialogs() {
        for title in ["Save…", "Save...", "Save As…", "Export", "Rename", "New Folder", "Open", "Print…",
                      "Duplicate", "Move To…", "save as", "  Save  "] {
            XCTAssertTrue(FocusBorrow.menuTitleOpensDialog(title), "\(title) should borrow focus")
        }
    }

    func testOrdinaryTitlesDoNotBorrowFocus() {
        for title in ["Copy", "Paste", "Saved Searches", "Save All", "Open Recent", "Opening Hours", "Undo", ""] {
            XCTAssertFalse(FocusBorrow.menuTitleOpensDialog(title), "\(title) should not borrow focus")
        }
    }

    func testMenuPathUsesItsLastTitle() {
        XCTAssertTrue(FocusBorrow.menuPathOpensDialog(["File", "Save…"]))
        XCTAssertTrue(FocusBorrow.menuPathOpensDialog(["File", "Export"]))
        XCTAssertFalse(FocusBorrow.menuPathOpensDialog(["File", "Save", "Copy"]))
        XCTAssertFalse(FocusBorrow.menuPathOpensDialog(["Edit", "Copy"]))
        XCTAssertFalse(FocusBorrow.menuPathOpensDialog([]))
    }

    // MARK: - The setting

    func testSettingIsOnByDefaultAndZeroDisables() {
        XCTAssertFalse(FocusBorrow.isEnabled(environment: [:]))
        XCTAssertTrue(FocusBorrow.isEnabled(environment: ["OPEN_COMPUTER_USE_FOCUS_BORROW": "1"]))
        XCTAssertTrue(FocusBorrow.isEnabled(environment: ["OPEN_COMPUTER_USE_FOCUS_BORROW": "yes"]))
        XCTAssertFalse(FocusBorrow.isEnabled(environment: ["OPEN_COMPUTER_USE_FOCUS_BORROW": "typo"]))
        XCTAssertFalse(FocusBorrow.isEnabled(environment: ["OPEN_COMPUTER_USE_FOCUS_BORROW": "0"]))
        XCTAssertFalse(FocusBorrow.isEnabled(environment: ["OPEN_COMPUTER_USE_FOCUS_BORROW": " off "]))
    }

    // MARK: - Bookkeeping

    func testBorrowActivatesAndReleaseRestoresPreviousApp() {
        let activator = FakeActivator(front: user, alive: [user, appA])
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        XCTAssertTrue(lease.activated)
        XCTAssertEqual(activator.front, appA)
        XCTAssertTrue(controller.isBorrowed(pid: appA))

        controller.release(lease)
        XCTAssertEqual(activator.front, user)
        XCTAssertFalse(controller.isBorrowed(pid: appA))
        XCTAssertEqual(activator.activations, [appA, user])
    }

    func testNestedBorrowRestoresOnlyOnce() {
        let activator = FakeActivator(front: user, alive: [user, appA])
        let controller = FocusBorrowController(activator: activator)

        let outer = controller.acquire(pid: appA)
        let inner = controller.acquire(pid: appA)
        XCTAssertEqual(controller.openCount, 2)

        controller.release(inner)
        XCTAssertEqual(activator.front, appA, "an inner borrow must not give focus back")
        XCTAssertEqual(controller.openCount, 1)

        controller.release(outer)
        XCTAssertEqual(activator.activations, [appA, user], "restore happens once, at the outermost release")
    }

    func testReleasingTwiceDoesNothingTheSecondTime() {
        let activator = FakeActivator(front: user, alive: [user, appA])
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        controller.release(lease)
        controller.release(lease)
        XCTAssertEqual(activator.activations, [appA, user])
        XCTAssertEqual(controller.openCount, 0)
    }

    func testUserSwitchingAppsMeanwhileIsNotOverridden() {
        let activator = FakeActivator(front: user, alive: [user, appA, appB])
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        activator.front = appB // the user clicked into another app during the work
        controller.release(lease)

        XCTAssertEqual(activator.front, appB)
        XCTAssertEqual(activator.activations, [appA], "no restore once the user has moved focus")
    }

    func testNothingToRestoreWhenTargetWasAlreadyFrontmost() {
        let activator = FakeActivator(front: appA, alive: [appA])
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        XCTAssertTrue(lease.activated)
        controller.release(lease)
        XCTAssertEqual(activator.activations, [], "no activation at all when the app was already in front")
        XCTAssertEqual(activator.front, appA)
    }

    func testRestoreSkipsAQuitPreviousApp() {
        let activator = FakeActivator(front: user, alive: [appA])
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        controller.release(lease)
        XCTAssertEqual(activator.activations, [appA], "the previous app has quit, so nothing is activated for it")
    }

    func testRefusedActivationIsReportedButReleaseStillBalances() {
        let activator = FakeActivator(front: user, alive: [user, appA])
        activator.refuse = [appA]
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        XCTAssertFalse(lease.activated)
        controller.release(lease)
        XCTAssertEqual(controller.openCount, 0)
        XCTAssertFalse(controller.isBorrowed(pid: appA))
    }

    func testReleaseDoesNotRestorePreviousAppWhileTheUserIsTyping() {
        let activator = FakeActivator(front: user, alive: [user, appA])
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        XCTAssertTrue(lease.activated)
        activator.typing = true
        controller.release(lease)

        XCTAssertEqual(activator.activations, [appA], "focus must not move away from the user's typing")
        XCTAssertEqual(activator.front, appA)
        XCTAssertEqual(controller.openCount, 0)
    }

    func testStillTypingAtTheEndOfTheWaitDoesNotTakeFocus() {
        let activator = FakeActivator(front: user, alive: [user, appA])
        activator.typing = true
        let controller = FocusBorrowController(activator: activator)

        let lease = controller.acquire(pid: appA)
        XCTAssertFalse(lease.activated, "the user is still typing, so focus must not be taken")
        XCTAssertEqual(activator.activations, [])
        XCTAssertEqual(activator.front, user)

        controller.release(lease)
        XCTAssertEqual(activator.activations, [], "nothing was borrowed, so nothing is restored")
        XCTAssertEqual(controller.openCount, 0)
    }

    func testSessionHandsFocusBackAfterTwoApps() {
        let activator = FakeActivator(front: user, alive: [user, appA, appB])
        let controller = FocusBorrowController(activator: activator)
        let session = FocusBorrowSession(controller: controller, enabled: true)

        XCTAssertTrue(session.ensure(pid: appA))
        XCTAssertTrue(session.ensure(pid: appA), "the same app again keeps its one lease")
        XCTAssertTrue(session.ensure(pid: appB))
        XCTAssertEqual(controller.openCount, 2)
        XCTAssertEqual(activator.front, appB)

        session.close()
        XCTAssertEqual(controller.openCount, 0)
        XCTAssertEqual(activator.front, user)
        XCTAssertEqual(activator.activations.last, user)
    }

    func testDisabledSessionNeverTouchesFocus() {
        let activator = FakeActivator(front: user, alive: [user, appA])
        let controller = FocusBorrowController(activator: activator)
        let session = FocusBorrowSession(controller: controller, enabled: false)

        XCTAssertFalse(session.ensure(pid: appA))
        session.close()
        XCTAssertEqual(activator.activations, [])
        XCTAssertEqual(activator.front, user)
    }

    // MARK: - Hidden apps and sky teardown

    func testAppTheBorrowUnhidesIsHiddenAgainAtRelease() {
        var ledger = UnhiddenAppLedger()
        ledger.recordUnhide(pid: appA)
        XCTAssertTrue(ledger.takeRehideNeeded(pid: appA))
        XCTAssertFalse(ledger.takeRehideNeeded(pid: appA), "the record is used once")
    }

    func testAppTheUserHidesDuringTheBorrowIsNotHiddenAgain() {
        var ledger = UnhiddenAppLedger()
        ledger.recordUnhide(pid: appA)
        ledger.recordUserHide(pid: appA)
        XCTAssertFalse(ledger.takeRehideNeeded(pid: appA), "the user hid it, so the release must not re-hide or override it")
        XCTAssertFalse(ledger.takeRehideNeeded(pid: appA))
    }

    func testUserHidingAnAppThisProcessDidNotUnhideChangesNothing() {
        var ledger = UnhiddenAppLedger()
        ledger.recordUserHide(pid: appB)
        ledger.recordUnhide(pid: appA)
        XCTAssertFalse(ledger.takeRehideNeeded(pid: appB))
        XCTAssertTrue(ledger.takeRehideNeeded(pid: appA))
    }

    func testSyntheticTeardownSucceedsWithoutRetry() throws {
        var calls = 0
        try SyntheticFocusTeardown.endAfterDelivery { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    func testSyntheticTeardownRetriesOnceAndStaysSilentWhenTheRetryWorks() throws {
        var calls = 0
        try SyntheticFocusTeardown.endAfterDelivery {
            calls += 1
            if calls == 1 { throw ComputerUseError.message("transient") }
        }
        XCTAssertEqual(calls, 2)
    }

    func testSyntheticTeardownFailingTwiceSaysTheInputWasDelivered() {
        var calls = 0
        XCTAssertThrowsError(try SyntheticFocusTeardown.endAfterDelivery {
            calls += 1
            throw ComputerUseError.message("gone")
        }) { error in
            guard case ComputerUseError.message(let text) = error else {
                return XCTFail("expected a message error, got \(error)")
            }
            XCTAssertTrue(text.contains("delivered"))
            XCTAssertTrue(text.contains("Do not send this step again"))
        }
        XCTAssertEqual(calls, 2)
    }
}
