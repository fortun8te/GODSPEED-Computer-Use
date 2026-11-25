import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

final class UserKeyWindowTests: XCTestCase {
    func testCaptureUsesTheLiveOwnerAndWindow() {
        let value = UserKeyWindow.capture(excludingPID: 99, foregroundPID: { 11 }, focusedWindow: { pid in
            XCTAssertEqual(pid, 11)
            return 42
        })
        XCTAssertEqual(value, UserKeyWindow(pid: 11, windowID: 42))
    }

    func testCaptureDoesNotRecordTheAgentTargetOrUnknownOwner() {
        let excluded: [pid_t] = [0, -1, 99]
        for pid in excluded {
            XCTAssertNil(UserKeyWindow.capture(excludingPID: 99, foregroundPID: { pid }, focusedWindow: { _ in
                XCTFail("The excluded or unknown foreground should not be queried")
                return 42
            }))
        }
        XCTAssertNil(UserKeyWindow.capture(excludingPID: 99, foregroundPID: {
            throw ComputerUseError.stateUnavailable("No owner")
        }, focusedWindow: { _ in 42 }))
    }

    func testCaptureDiscardsAWindowReadAcrossAnAppSwitch() {
        var owner: pid_t = 11
        XCTAssertNil(UserKeyWindow.capture(excludingPID: 99, foregroundPID: { owner }, focusedWindow: { _ in
            owner = 12
            return 42
        }))
    }

    func testReturnFocusOnlyForTheUnchangedLiveOwnerAndWindow() {
        var returned = 0
        UserKeyWindow(pid: 11, windowID: 42).giveBack(foregroundPID: { 11 }, focusedWindow: { _ in 42 },
                                                    returnFocus: { returned += 1 })
        XCTAssertEqual(returned, 1)
    }

    func testReturnFocusLeavesAnotherAppOrWindowAlone() {
        let captured = UserKeyWindow(pid: 11, windowID: 42)
        let owners: [pid_t] = [0, 12]
        for owner in owners {
            captured.giveBack(foregroundPID: { owner }, focusedWindow: { _ in 42 },
                             returnFocus: { XCTFail("Restored focus after an app switch") })
        }
        let windows: [CGWindowID?] = [nil, 0, 43]
        for window in windows {
            captured.giveBack(foregroundPID: { 11 }, focusedWindow: { _ in window },
                             returnFocus: { XCTFail("Restored focus after a window switch") })
        }
    }

    func testReturnFocusRechecksAppAfterEachWindowRead() {
        for changedOnRead in [1, 2] {
            var owner: pid_t = 11
            var reads = 0
            UserKeyWindow(pid: 11, windowID: 42).giveBack(foregroundPID: { owner }, focusedWindow: { _ in
                reads += 1
                if reads == changedOnRead { owner = 12 }
                return 42
            }, returnFocus: { XCTFail("Restored focus after an app switch during an AX read") })
        }
    }

    func testReturnFocusRechecksWindowAndFailsClosedOnReadFailure() {
        var reads = 0
        let captured = UserKeyWindow(pid: 11, windowID: 42)
        captured.giveBack(foregroundPID: { 11 }, focusedWindow: { _ in
            reads += 1
            return reads == 1 ? 42 : 43
        }, returnFocus: { XCTFail("Restored an old window") })
        captured.giveBack(foregroundPID: { throw ComputerUseError.stateUnavailable("No owner") },
                         focusedWindow: { _ in 42 }, returnFocus: { XCTFail("Restored an unknown owner") })
    }
}
