import JavaScriptCore
import XCTest
@testable import OpenComputerUseKit

final class BrowserTextWaitTests: XCTestCase {
    private func fixture() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var reads = 0, text = "", resolution = null, cleanup = 0;
        var observed = null, timeout = null;
        var document = {body: {get innerText() { reads++; return text; }}};
        class Promise {
          constructor(execute) { execute(result => { resolution = result; }); }
        }
        class MutationObserver {
          constructor(check) { observed = check; }
          observe() {}
          disconnect() { cleanup++; }
        }
        function setTimeout(check) { timeout = check; return 1; }
        function setInterval() { return 2; }
        function clearTimeout() { cleanup++; }
        function clearInterval() { cleanup++; }
        """)
        return context
    }

    func testImmediateTextWaitReadsVisibleTextOnlyOnce() throws {
        for (text, milliseconds, matched) in [("a needle", 500, true), ("absent", 0, false)] {
            let context = try fixture()
            context.setObject(text, forKeyedSubscript: "text" as NSString)
            _ = context.evaluateScript(BrowserPage.textWaitExpression("needle", milliseconds: milliseconds))
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("reads").toInt32(), 1)
            XCTAssertEqual(context.evaluateScript("resolution").toBool(), matched)
            XCTAssertTrue(context.evaluateScript("observed").isNull)
        }
    }

    func testTextWaitStillChecksFreshTextOnMutationAndTimeout() throws {
        for matchOnMutation in [true, false] {
            let context = try fixture()
            _ = context.evaluateScript(BrowserPage.textWaitExpression("needle", milliseconds: 500))
            XCTAssertTrue(context.evaluateScript("resolution").isNull)
            XCTAssertEqual(context.evaluateScript("reads").toInt32(), 1)
            _ = context.evaluateScript(matchOnMutation ? "text = 'needle'; observed();" : "timeout();")
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("resolution").toBool(), matchOnMutation)
            XCTAssertEqual(context.evaluateScript("reads").toInt32(), 2)
            XCTAssertEqual(context.evaluateScript("cleanup").toInt32(), 3)
        }
    }
}
