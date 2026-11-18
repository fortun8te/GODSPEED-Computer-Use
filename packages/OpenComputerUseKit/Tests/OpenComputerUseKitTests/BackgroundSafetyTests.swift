import ApplicationServices
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Pure decision and wording tests for the background-only paths: key equivalents, the
/// "nothing changed" checks, scroll refusals and the messages that say which route works.
/// Nothing here touches accessibility, the screen or another process.
final class BackgroundSafetyTests: XCTestCase {
    private func equivalent(_ key: String) throws -> SkyMenuKeyEquivalent? {
        skyMenuKeyEquivalent(for: try KeyPressParser.parse(key))
    }

    // MARK: - Key equivalents

    func testCommandLetterMapsToMenuEquivalent() throws {
        XCTAssertEqual(try equivalent("cmd+s"), SkyMenuKeyEquivalent(character: "S", modifiers: 0))
        XCTAssertEqual(try equivalent("command+S"), SkyMenuKeyEquivalent(character: "S", modifiers: 0))
    }

    func testShiftAndOptionAndControlSetTheirMenuBits() throws {
        XCTAssertEqual(try equivalent("cmd+shift+s")?.modifiers, 1)
        XCTAssertEqual(try equivalent("cmd+option+c")?.modifiers, 2)
        XCTAssertEqual(try equivalent("cmd+control+a")?.modifiers, 4)
        XCTAssertEqual(try equivalent("cmd+shift+option+z")?.modifiers, 3)
    }

    func testChordsWithoutCommandOrWithMultiCharacterKeysHaveNoMenuEquivalent() throws {
        XCTAssertNil(try equivalent("s"), "a plain key is delivered as a key event")
        XCTAssertNil(try equivalent("ctrl+a"), "a non-command chord is delivered as a key event")
        XCTAssertNil(try equivalent("cmd+return"), "a named key is not a single character")
        XCTAssertNil(try equivalent("cmd+left"))
    }

    func testMenuItemMatchesCharacterCaseInsensitivelyAndModifiers() {
        let save = SkyMenuKeyEquivalent(character: "S", modifiers: 0)
        XCTAssertTrue(skyMenuItemMatches(cmdChar: "s", cmdModifiers: nil, enabled: true, equivalent: save),
                      "a missing modifier mask means plain Command")
        XCTAssertTrue(skyMenuItemMatches(cmdChar: "S", cmdModifiers: 0, enabled: nil, equivalent: save))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "s", cmdModifiers: 1, enabled: true, equivalent: save),
                       "Save As (shift) must not answer for Save")
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "s", cmdModifiers: 8, enabled: true, equivalent: save),
                       "a no-command equivalent is not a command chord")
        XCTAssertFalse(skyMenuItemMatches(cmdChar: nil, cmdModifiers: 0, enabled: true, equivalent: save))
    }

    func testMenuItemThatIsReallyDisabledDoesNotMatchWhileStaleDisabledIsStillAcceptedByTheFallback() {
        let save = SkyMenuKeyEquivalent(character: "S", modifiers: 0)
        // The first lookup trusts the enabled flag, so a really disabled item is skipped.
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "S", cmdModifiers: 0, enabled: false, equivalent: save))
        // The fallback passes enabled as true, which is how a stale-disabled Save is still found.
        XCTAssertTrue(skyMenuItemMatches(cmdChar: "S", cmdModifiers: 0, enabled: true, equivalent: save))
    }

    // MARK: - Messages that name the working route

    func testKeyUnavailableMessageNamesTheActionReasonAndPressMenu() {
        let message = backgroundKeyUnavailableMessage(action: "press_key 'x'", reason: "the private API is missing")
        XCTAssertTrue(message.contains("press_key 'x' could not reach the background app"))
        XCTAssertTrue(message.contains("the private API is missing"))
        XCTAssertTrue(message.contains("press_menu"))
    }

    func testDisabledMenuNoteSaysTheStateMayNotHaveChanged() {
        XCTAssertTrue(disabledMenuKeyNote.contains("listed it as disabled"))
        XCTAssertTrue(disabledMenuKeyNote.contains("check the state"))
    }

    func testBusyPressIsReportedAsNotConfirmed() {
        XCTAssertNil(menuPressError(.success, path: "File > Save"))

        let busy = menuPressError(.cannotComplete, path: "File > Save")
        guard case .stateUnavailable(let text)? = busy else {
            return XCTFail("a busy app must be reported as not confirmed, got \(String(describing: busy))")
        }
        XCTAssertTrue(text.contains("File > Save was sent"))
        XCTAssertTrue(text.contains("may still run"))

        guard case .message(let other)? = menuPressError(.invalidUIElement, path: "File > Save") else {
            return XCTFail("an unrecognised AXError is a plain failure")
        }
        XCTAssertTrue(other.hasPrefix("Could not press File > Save"))
    }

    func testNonSettableSetValueSuggestsTheWorkingAlternatives() {
        let message = nonSettableSetValueErrorMessage + setValueFallbackHint
        XCTAssertTrue(message.hasPrefix("Cannot set a value for an element that is not settable"))
        XCTAssertTrue(message.contains("type_text"))
        XCTAssertTrue(message.contains("press_menu"))
    }

    func testUnreadableFocusMessageSaysWhereSavePanelsGoWrong() {
        XCTAssertTrue(focusedElementUnreadableMessage.contains("save, open or print panel"))
        XCTAssertTrue(focusedElementUnreadableMessage.contains("press_menu"))
        XCTAssertTrue(focusedElementUnreadableMessage.contains("command line or URL"))
    }

    // MARK: - type_text: did the keys reach the field?

    func testUnchangedTextIsReportedAsNotApplied() {
        XCTAssertTrue(typedTextWasNotApplied(before: "hello", after: "hello", text: "x", isSecureField: false))
        XCTAssertTrue(typedTextWasNotApplied(before: "", after: "", text: "x", isSecureField: false))
    }

    func testChangedTextIsApplied() {
        XCTAssertFalse(typedTextWasNotApplied(before: "hello", after: "hello x", text: "x", isSecureField: false))
    }

    func testUnknownValueOrSecureFieldNeverCountsAsUnchanged() {
        XCTAssertFalse(typedTextWasNotApplied(before: nil, after: nil, text: "x", isSecureField: false),
                       "an unreadable value proves nothing")
        XCTAssertFalse(typedTextWasNotApplied(before: "", after: "", text: "x", isSecureField: true),
                       "a password field answers an empty value whatever it holds")
        XCTAssertFalse(typedTextWasNotApplied(before: "a", after: "a", text: "", isSecureField: false),
                       "empty text has nothing to apply")
    }

    func testNotAppliedMessageSaysNothingWasTypedAndWarnsAboutRepeats() {
        XCTAssertTrue(typedTextNotAppliedMessage.contains("did not change"))
        XCTAssertTrue(typedTextNotAppliedMessage.contains("type twice"))
    }

    // MARK: - scroll: refusals are reported with how far it got

    func testPartialScrollReportsPagesMovedAndTheAXError() {
        let message = scrollPagesRefusedMessage(done: 2, requested: 5, error: .cannotComplete)
        XCTAssertTrue(message.contains("moved 2 of 5 pages"))
        XCTAssertTrue(message.contains("AXError \(AXError.cannotComplete.rawValue)"))
        XCTAssertTrue(message.contains("Read the app state"))
    }

    // MARK: - Note placement

    func testNoteGoesAfterTheTextAndBeforeTheScreenshot() {
        let result = ToolCallResult(content: [
            .text("state"),
            .pngImage(Data([0x89, 0x50])),
        ])
        let withNote = insertingNote("note", into: result)
        XCTAssertEqual(withNote.content.count, 3)
        XCTAssertEqual(withNote.content[0].dictionary["text"] as? String, "state")
        XCTAssertEqual(withNote.content[1].dictionary["text"] as? String, "note")
        XCTAssertEqual(withNote.content[2].dictionary["type"] as? String, "image")
    }

    func testNoteIsAppendedWhenThereIsNoScreenshot() {
        let withNote = insertingNote("note", into: .text("state"))
        XCTAssertEqual(withNote.content.count, 2)
        XCTAssertEqual(withNote.content[1].dictionary["text"] as? String, "note")
    }

    // MARK: - Background-only switch

    func testBackgroundOnlyReadsTheEnvironmentSwitch() {
        XCTAssertTrue(backgroundOnlyMode(environment: ["OPEN_COMPUTER_USE_BACKGROUND_ONLY": "1"]))
        XCTAssertTrue(backgroundOnlyMode(environment: ["OPEN_COMPUTER_USE_BACKGROUND_ONLY": " On "]))
        XCTAssertFalse(backgroundOnlyMode(environment: ["OPEN_COMPUTER_USE_BACKGROUND_ONLY": "0"]))
        XCTAssertFalse(backgroundOnlyMode(environment: [:]))
    }
}
