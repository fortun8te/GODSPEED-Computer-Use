import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Teach mode turns fake observed inputs into batch steps and slots. No accessibility or event APIs run here.
final class TeachRecorderTests: XCTestCase {
    private let mailPID: pid_t = 4242
    private let otherPID: pid_t = 9999
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private let to = TeachTarget(role: "text field", label: "To")
    private let send = TeachTarget(role: "button", label: "Send")
    private let password = TeachTarget(role: "secure text field", label: "Password", secure: true)

    private func recorder() -> TeachRecorder {
        TeachRecorder(app: "Mail", goal: "Email Sam the report", pid: mailPID, window: nil, startedAt: t0)
    }

    private func input(_ event: TeachEvent, pid: pid_t? = nil) -> TeachInput {
        TeachInput(pid: pid ?? mailPID, event: event)
    }

    private func tools(_ steps: [Any]) -> [String] {
        steps.compactMap { ($0 as? [String: Any])?["tool"] as? String }
    }

    private func json(_ steps: [Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: steps)) ?? Data(), as: UTF8.self)
    }

    func testClickAndTypedFieldBecomeLabelledStepsWithASlot() {
        let r = recorder()
        r.handle(input(.focus(to)), now: t0)
        r.handle(input(.typed("sam@")), now: t0)
        r.handle(input(.typed("x.com")), now: t0)
        r.handle(input(.press(send)), now: t0)
        let out = r.finish()

        XCTAssertEqual(tools(out.steps), ["set_value", "click"])
        let first = out.steps[0] as? [String: Any]
        XCTAssertEqual(first?["label"] as? String, "To")
        XCTAssertEqual(first?["value"] as? String, "{{to}}")
        XCTAssertEqual((first?["_loc"] as? [String: Any])?["role"] as? String, "text field")
        XCTAssertEqual(out.params, ["to": "sam@x.com"])
        XCTAssertEqual(out.kinds["to"], .recipient)
        XCTAssertEqual((out.steps[1] as? [String: Any])?["label"] as? String, "Send")
    }

    func testMenuPathBecomesPressMenu() {
        let r = recorder()
        r.handle(input(.menu(["File", "Save"])), now: t0)
        let out = r.finish()
        XCTAssertEqual(tools(out.steps), ["press_menu"])
        XCTAssertEqual((out.steps[0] as? [String: Any])?["path"] as? String, "File > Save")
    }

    func testFilledValueIsUsedWhenNoKeystrokesWereSeen() {
        let r = recorder()
        r.handle(input(.value(to, "sam@x.com")), now: t0)
        r.handle(input(.press(send)), now: t0)
        let out = r.finish()
        XCTAssertEqual(out.params, ["to": "sam@x.com"])
        XCTAssertEqual(tools(out.steps), ["set_value", "click"])
    }

    func testSecureFieldTypingIsNeverStoredAndMarksTheRecipeAsNeedingTheValue() {
        let r = recorder()
        r.handle(input(.focus(password)), now: t0)
        r.handle(input(.typed("hunter2")), now: t0)
        r.handle(input(.value(password, "hunter2")), now: t0)
        r.handle(input(.press(send)), now: t0)
        let out = r.finish()

        XCTAssertFalse(json(out.steps).contains("hunter2"))
        XCTAssertTrue(out.params.isEmpty)
        XCTAssertEqual(out.needsValue, ["Password"])
        let placeholder = out.steps[0] as? [String: Any]
        XCTAssertEqual(placeholder?["label"] as? String, "Password")
        XCTAssertEqual(placeholder?["_needs_value"] as? Bool, true)
        XCTAssertNil(placeholder?["value"])
        XCTAssertEqual(tools(out.steps), ["set_value", "click"])
    }

    func testOtherAppInputIsIgnored() {
        let r = recorder()
        XCTAssertFalse(r.handle(input(.focus(to), pid: otherPID), now: t0))
        XCTAssertFalse(r.handle(input(.typed("secret"), pid: otherPID), now: t0))
        XCTAssertFalse(r.handle(input(.press(send), pid: otherPID), now: t0))
        XCTAssertFalse(r.handle(input(.menu(["File", "Quit"]), pid: otherPID), now: t0))
        let out = r.finish()
        XCTAssertTrue(out.steps.isEmpty)
        XCTAssertTrue(out.params.isEmpty)
    }

    func testTypingWithNoFocusedFieldIsNotStoredAndIsNoted() {
        let r = recorder()
        r.handle(input(.typed("hello")), now: t0)
        let out = r.finish()
        XCTAssertTrue(out.steps.isEmpty)
        XCTAssertEqual(out.notes, [TeachRecorder.noFocusNote])
    }

    func testUnlabelledClickIsNotRecorded() {
        let r = recorder()
        r.handle(input(.press(TeachTarget(role: "button", label: ""))), now: t0)
        let out = r.finish()
        XCTAssertTrue(out.steps.isEmpty)
        XCTAssertEqual(out.notes, [TeachRecorder.unlabelledNote])
    }

    func testRecordingEndsAfterTenMinutesAndKeepsWhatCameBefore() {
        let r = recorder()
        r.handle(input(.focus(to)), now: t0)
        r.handle(input(.typed("ok")), now: t0)
        XCTAssertFalse(r.handle(input(.press(send)), now: t0.addingTimeInterval(601)))
        XCTAssertEqual(r.ended, "10-minute limit")
        let out = r.finish()
        XCTAssertEqual(tools(out.steps), ["set_value"])
        XCTAssertEqual(out.params, ["to": "ok"])
    }

    func testTargetAppQuitEndsRecording() {
        let r = recorder()
        r.handle(input(.focus(to)), now: t0)
        r.handle(input(.typed("draft")), now: t0)
        XCTAssertTrue(r.handle(input(.appQuit), now: t0))
        XCTAssertEqual(r.ended, "app quit")
        XCTAssertFalse(r.handle(input(.press(send)), now: t0))
        XCTAssertEqual(tools(r.finish().steps), ["set_value"])
    }

    func testOtherAppQuitDoesNotEndRecording() {
        let r = recorder()
        r.handle(input(.appQuit, pid: otherPID), now: t0)
        XCTAssertNil(r.ended)
    }
}
