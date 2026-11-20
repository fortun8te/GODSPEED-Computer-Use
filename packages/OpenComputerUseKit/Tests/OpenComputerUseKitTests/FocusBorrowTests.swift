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

    // MARK: - Workflows that needed focus borrowing (background first, then the typed reply)

    private let needsBorrowing = "BACKGROUND_UNSUPPORTED: This needs focus borrowing: set OPEN_COMPUTER_USE_FOCUS_BORROW=1 or allow it in Settings"

    private func replyText(_ result: ToolCallResult) -> String {
        result.content.compactMap { $0.dictionary["type"] as? String == "text" ? $0.dictionary["text"] as? String : nil }
            .joined(separator: "\n")
    }

    /// A background press that the app refused because its menu item needs the app in front.
    private func backgroundMenuFailure() -> ToolCallResult {
        .failure(ComputerUseError.notSent("The menu item is disabled in the background."))
    }

    /// Save from the File menu (press_menu) with borrowing off: the typed sentence, not the bare failure.
    func testSaveMenuPressWithBorrowingOffSaysItNeedsBorrowing() {
        let opens = FocusBorrow.menuPathOpensDialog(["File", "Save…"])
        let reply = FocusBorrow.dialogStepReply(backgroundMenuFailure(), opensDialog: opens, appIsFrontmost: false, enabled: false)
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(replyText(reply), needsBorrowing)
    }

    /// Export, Open, Print, Duplicate, Move To, New Folder and Rename are the other dialog menu items.
    func testExportOpenPrintAndFileDialogItemsSayItNeedsBorrowing() {
        for title in ["Export", "Open…", "Print…", "Duplicate", "Move To…", "New Folder", "Rename"] {
            let reply = FocusBorrow.dialogStepReply(backgroundMenuFailure(), opensDialog: FocusBorrow.menuTitleOpensDialog(title),
                                                    appIsFrontmost: false, enabled: false)
            XCTAssertEqual(replyText(reply), needsBorrowing, "\(title) should say it needs focus borrowing")
        }
    }

    /// A save chord (cmd+s) presses the Save item: the same reply as the menu press.
    func testSaveKeyChordWithBorrowingOffSaysItNeedsBorrowing() {
        let opens = FocusBorrow.menuTitleOpensDialog("Save")
        let reply = FocusBorrow.dialogStepReply(backgroundMenuFailure(), opensDialog: opens, appIsFrontmost: false, enabled: false)
        XCTAssertEqual(replyText(reply), needsBorrowing)
    }

    /// Saving through the save panel (save_as) when neither File > Save As nor File > Save can be pressed in the background.
    func testSaveAsMenusUnavailableInBackgroundIsTyped() {
        let error = FocusBorrow.focusRequiredError("The File menu's Save As and Save items did not take a press in the background.",
                                                   enabled: false, borrowed: false)
        guard case .backgroundUnsupported(let message) = error else { return XCTFail("expected BACKGROUND_UNSUPPORTED, got \(error)") }
        XCTAssertEqual(message, FocusBorrow.needsBorrowingMessage)
    }

    /// Typing into the Go to Folder editor (keys, modal path) that could not be found in the background.
    func testModalEditorTypingWithBorrowingOffIsTyped() {
        let error = FocusBorrow.focusRequiredError("The Go to Folder dialog did not expose a focused text field.",
                                                   enabled: false, borrowed: false, unsent: false)
        guard case .backgroundUnsupported(let message) = error else { return XCTFail("expected BACKGROUND_UNSUPPORTED, got \(error)") }
        XCTAssertEqual(message, FocusBorrow.needsBorrowingMessage)
    }

    /// Typing when no focused field can be read in the background: the same typed reply.
    func testUnreadableFocusedFieldWithBorrowingOffIsTyped() {
        let error = FocusBorrow.focusRequiredError("type_text requires a focused editable text element.", enabled: false, borrowed: false)
        guard case .backgroundUnsupported(let message) = error else { return XCTFail("expected BACKGROUND_UNSUPPORTED, got \(error)") }
        XCTAssertEqual(message, FocusBorrow.needsBorrowingMessage)
    }

    /// A foreground batch that fails with borrowing off names the sentence; one that succeeds, or borrowing on, does not.
    func testForegroundBatchFailureNamesTheSentenceOnlyWhenOff() {
        XCTAssertEqual(FocusBorrow.foregroundBatchNote(foreground: true, failed: true, enabled: false), FocusBorrow.needsBorrowingMessage)
        XCTAssertNil(FocusBorrow.foregroundBatchNote(foreground: true, failed: false, enabled: false))
        XCTAssertNil(FocusBorrow.foregroundBatchNote(foreground: true, failed: true, enabled: true))
        XCTAssertNil(FocusBorrow.foregroundBatchNote(foreground: false, failed: true, enabled: false))
    }

    /// With borrowing on, the same failures keep the ordinary refusal and the retry hint, and never the typed sentence.
    func testBorrowingOnKeepsTheRetryHintInsteadOfTheSentence() {
        let reply = FocusBorrow.dialogStepReply(backgroundMenuFailure(), opensDialog: true, appIsFrontmost: false, enabled: true)
        XCTAssertEqual(replyText(reply), "The menu item is disabled in the background.")
        let error = FocusBorrow.focusRequiredError("Focus an editable field.", enabled: true, borrowed: false)
        guard case .notSent(let text) = error else { return XCTFail("expected notSent, got \(error)") }
        XCTAssertTrue(text.contains("foreground"))
        XCTAssertFalse(text.contains("This needs focus borrowing"))
    }

    /// The app already in front, a step that does not open a dialog, and a policy refusal keep their own reply.
    func testOnlyAFailedBackgroundDialogStepIsReplaced() {
        let failure = backgroundMenuFailure()
        XCTAssertEqual(replyText(FocusBorrow.dialogStepReply(failure, opensDialog: true, appIsFrontmost: true, enabled: false)),
                       "The menu item is disabled in the background.")
        XCTAssertEqual(replyText(FocusBorrow.dialogStepReply(failure, opensDialog: false, appIsFrontmost: false, enabled: false)),
                       "The menu item is disabled in the background.")
        let refused: ToolCallResult = .failure(ComputerUseError.approvalRequired("Confirm the save."))
        XCTAssertEqual(replyText(FocusBorrow.dialogStepReply(refused, opensDialog: true, appIsFrontmost: false, enabled: false)),
                       "APPROVAL_REQUIRED: Confirm the save.")
        let success = ToolCallResult.text("ok")
        XCTAssertFalse(FocusBorrow.dialogStepReply(success, opensDialog: true, appIsFrontmost: false, enabled: false).isError)
    }

    /// The no-effect retry is a borrow: with borrowing off it is never tried, so the step is not sent twice in the background.
    func testNoEffectRetryIsNotTriedWhileBorrowingIsOff() {
        let off = FocusBorrow.isEnabled(environment: [:])
        XCTAssertFalse(SmartSteps.shouldRetryWithoutEffect(actionSucceeded: true, before: ["a"], after: ["a"],
                                                           appIsFrontmost: false, borrowingAllowed: off, alreadyBorrowed: false))
        XCTAssertTrue(SmartSteps.shouldRetryWithoutEffect(actionSucceeded: true, before: ["a"], after: ["a"],
                                                          appIsFrontmost: false, borrowingAllowed: true, alreadyBorrowed: false))
    }
}
