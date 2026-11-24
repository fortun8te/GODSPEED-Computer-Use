import JavaScriptCore
import XCTest
@testable import OpenComputerUseKit

final class BrowserCheckboxTests: XCTestCase {
    func testCheckedStateDistinguishesIndeterminateInputsAndARIA() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const input = {isConnected: true, tagName: 'INPUT', type: 'checkbox',
                       checked: false, indeterminate: true};
        const wrapper = {isConnected: true, getAttribute: () => null, querySelector: () => input};
        const staleWrapper = {...wrapper, getAttribute: () => 'false'};
        const aria = {isConnected: true, getAttribute: () => 'mixed'};
        """)
        let read = "(\(BrowserPage.checkedStateJS))"
        for target in ["input", "wrapper", "staleWrapper", "aria"] {
            XCTAssertEqual(context.evaluateScript("\(read).call(\(target))")?.toString(), "mixed")
        }
        XCTAssertEqual(context.evaluateScript("input.checked = true; \(read).call(input)")?.toString(), "mixed")
        XCTAssertEqual(context.evaluateScript("input.indeterminate = false; \(read).call(input)")?.toString(), "true")
        XCTAssertEqual(context.evaluateScript("input.checked = false; \(read).call(wrapper)")?.toString(), "false")
        XCTAssertEqual(context.evaluateScript("input.isConnected = false; \(read).call(input)")?.toString(), "unknown")
    }
}
