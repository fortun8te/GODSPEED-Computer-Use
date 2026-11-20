import XCTest
@testable import OpenComputerUseKit

final class FocusTransitionTests: XCTestCase {
    func testMatchesAndWhitespaceCaseInsensitively() {
        XCTAssertEqual(FocusTransition.check(target: .init(windowID: 4, elementRole: "TextField", label: "Email"), observed: .init(windowID: 4, elementRole: "textfield", label: "  eMAIL ")), .ok)
    }

    func testWrongWindowAndElement() {
        let target = FocusTarget(windowID: 4, elementRole: "TextField", label: "Email")
        XCTAssertEqual(FocusTransition.check(target: target, observed: .init(windowID: 5, elementRole: "TextField", label: "Email")), .wrongWindow)
        XCTAssertEqual(FocusTransition.check(target: target, observed: .init(windowID: 4, elementRole: "Button", label: "Send")), .wrongElement(expected: "TextField: Email", observed: "Button: Send"))
    }

    func testDialogAndMissingData() {
        let target = FocusTarget(windowID: 4, elementRole: "TextField", label: "Name")
        XCTAssertEqual(FocusTransition.check(target: target, observed: .init(windowID: 4, elementRole: "TextField", label: "Name", dialogTitle: "Save")), .unexpectedDialog(title: "Save"))
        XCTAssertEqual(FocusTransition.check(target: target, observed: .init(windowID: nil, elementRole: "TextField", label: "Name")), .unknown)
    }

    func testSecureAndPredictions() {
        let secure = FocusTarget(windowID: 1, elementRole: "SecureTextField", label: "Password")
        XCTAssertEqual(FocusTransition.check(target: secure, observed: .init(windowID: 1, elementRole: "SecureTextField", label: "Password")), .ok)
        XCTAssertEqual(FocusTransition.predictedFocusAfter(action: .openSaveDialog), "Name")
        XCTAssertEqual(FocusTransition.predictedFocusAfter(action: .tab(currentLabel: "Name", orderedLabels: ["Name", "Tags"])), "Tags")
    }

    func testExpectedDialogAbsentIsUnknownNeverOK() {
        let target = FocusTarget(windowID: 4, elementRole: "TextField", label: "Name", dialogTitle: "Save")
        let matching = ObservedFocus(windowID: 4, elementRole: "TextField", label: "Name")
        XCTAssertEqual(FocusTransition.check(target: target, observed: matching), .unknown)
        let wrongElement = ObservedFocus(windowID: 4, elementRole: "Button", label: "Send")
        XCTAssertEqual(FocusTransition.check(target: target, observed: wrongElement), .unknown)
    }

    func testDialogInFrontThatTargetDoesNotNameIsUnexpected() {
        let target = FocusTarget(windowID: 4, elementRole: "TextField", label: "Name")
        let sheet = ObservedFocus(windowID: 4, elementRole: "TextField", label: "Name", dialogTitle: "Confirm Delete")
        XCTAssertEqual(FocusTransition.check(target: target, observed: sheet), .unexpectedDialog(title: "Confirm Delete"))
    }

    /// The gate both keyboard paths (sky_key and the plain fallback) use before any key is sent.
    func testWrongFocusTypingIsRefusedWithNotSent() {
        let read = ObservedFocus(windowID: 4, elementRole: "AXTextField", label: "Email")
        XCTAssertNil(ComputerUseService.keyboardFocusRefusal(read: read, observed: read), "the field that was read may take keys")

        let moved = ObservedFocus(windowID: 4, elementRole: "AXButton", label: "Send")
        guard case .notSent(let message)? = ComputerUseService.keyboardFocusRefusal(read: read, observed: moved) else {
            return XCTFail("focus on another control must refuse with notSent")
        }
        XCTAssertEqual(message, "Typing would go to Send; read the app and target the field.")

        let unknownNow = ObservedFocus(windowID: 4, elementRole: nil, label: nil)
        XCTAssertNotNil(ComputerUseService.keyboardFocusRefusal(read: read, observed: unknownNow), "unknown focus is never typed into")
        let unknownRead = ObservedFocus(windowID: 4, elementRole: nil, label: nil)
        XCTAssertNotNil(ComputerUseService.keyboardFocusRefusal(read: unknownRead, observed: read), "an unread focus is never typed into")
    }

    func testDifferentDialogThanNamedIsUnexpectedAndNamedDialogIsOK() {
        let target = FocusTarget(windowID: 4, elementRole: "TextField", label: "Name", dialogTitle: "Save")
        let other = ObservedFocus(windowID: 4, elementRole: "TextField", label: "Name", dialogTitle: "Replace")
        XCTAssertEqual(FocusTransition.check(target: target, observed: other), .unexpectedDialog(title: "Replace"))
        let named = ObservedFocus(windowID: 4, elementRole: "TextField", label: "Name", dialogTitle: " save ")
        XCTAssertEqual(FocusTransition.check(target: target, observed: named), .ok)
    }
}
