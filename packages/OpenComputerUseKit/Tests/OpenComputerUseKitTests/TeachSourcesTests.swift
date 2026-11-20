import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// The pure parts of the live teach source. No observer, event tap or hit test is installed here.
final class TeachSourcesTests: XCTestCase {
    func testAccessibilityRolesReadAsPlainWords() {
        XCTAssertEqual(TeachLive.roleWords("AXTextField"), "text field")
        XCTAssertEqual(TeachLive.roleWords("AXButton"), "button")
        XCTAssertEqual(TeachLive.roleWords("AXStaticText"), "static text")
        XCTAssertEqual(TeachLive.roleWords("AXPopUpButton"), "pop up button")
        XCTAssertEqual(TeachLive.roleWords(""), "")
    }

    func testOnlyPrintableCharactersBecomeTypedText() {
        XCTAssertEqual(TeachLive.printableText("a"), "a")
        XCTAssertEqual(TeachLive.printableText("sam@x.com"), "sam@x.com")
        XCTAssertEqual(TeachLive.printableText("é"), "é")
        XCTAssertNil(TeachLive.printableText("\r"))
        XCTAssertNil(TeachLive.printableText("\t"))
        XCTAssertNil(TeachLive.printableText(""))
    }

    func testKeyPressWithCommandIsAShortcutNotText() throws {
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        key.keyboardSetUnicodeString(stringLength: 1, unicodeString: Array("c".utf16))

        key.flags = []
        XCTAssertEqual(TeachLive.typedText(of: key), "c")

        key.flags = .maskCommand
        XCTAssertNil(TeachLive.typedText(of: key), "cmd+c is a shortcut; its letter is not typed text")

        key.flags = .maskControl
        XCTAssertNil(TeachLive.typedText(of: key))
    }

    func testTargetAppTerminationBecomesAnAppQuitInputOnlyForThatApp() {
        XCTAssertEqual(LiveTeachSource.terminationInput(terminated: 42, target: 42), TeachInput(pid: 42, event: .appQuit))
        XCTAssertNil(LiveTeachSource.terminationInput(terminated: 7, target: 42))
    }
}

final class TeachKeystrokePrivacyTests: XCTestCase {
    func testOnlyConfirmedPlainTextFieldsMayBeRecorded() {
        XCTAssertTrue(TeachLive.focusedFieldMayBeRecorded(role: "AXTextField", subrole: nil, label: "To", description: nil))
        XCTAssertTrue(TeachLive.focusedFieldMayBeRecorded(role: "AXTextArea", subrole: nil, label: "Message", description: nil))
    }

    func testSecretFieldsAreNeverRecorded() {
        XCTAssertFalse(TeachLive.focusedFieldMayBeRecorded(role: "AXSecureTextField", subrole: nil, label: "", description: nil))
        XCTAssertFalse(TeachLive.focusedFieldMayBeRecorded(role: "AXTextField", subrole: "AXSecureTextField", label: "x", description: nil))
        for label in ["Password", "Wachtwoord", "PIN code", "Verificatiecode", "API token", "CVV"] {
            XCTAssertFalse(TeachLive.focusedFieldMayBeRecorded(role: "AXTextField", subrole: nil, label: label, description: nil), label)
        }
        XCTAssertFalse(TeachLive.focusedFieldMayBeRecorded(role: "AXTextField", subrole: nil, label: "Code", description: "One-time OTP"))
    }

    func testUnknownOrNonTextFocusIsNeverRecorded() {
        XCTAssertFalse(TeachLive.focusedFieldMayBeRecorded(role: nil, subrole: nil, label: "To", description: nil))
        XCTAssertFalse(TeachLive.focusedFieldMayBeRecorded(role: "AXButton", subrole: nil, label: "Send", description: nil))
        XCTAssertFalse(TeachLive.focusedFieldMayBeRecorded(role: "AXWebArea", subrole: nil, label: "", description: nil))
    }
}
