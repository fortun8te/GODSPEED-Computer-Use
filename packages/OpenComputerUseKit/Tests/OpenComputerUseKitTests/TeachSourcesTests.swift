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
