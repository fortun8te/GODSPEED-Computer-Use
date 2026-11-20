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
}
