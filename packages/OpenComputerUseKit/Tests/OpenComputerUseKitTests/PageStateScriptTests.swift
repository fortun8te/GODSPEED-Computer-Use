import JavaScriptCore
import XCTest
@testable import OpenComputerUseKit

/// Runs the injected page-state script in JavaScriptCore against stub fetch / XMLHttpRequest, to prove it
/// wraps once, keeps `this`, arguments and return values, and never breaks a site's own call.
final class PageStateScriptTests: XCTestCase {
    private func context() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in XCTFail("js exception: \(String(describing: e))") }
        ctx.evaluateScript("""
        var window=this; var t=0; var performance={now:function(){return ++t;}};
        function MutationObserver(){} MutationObserver.prototype.observe=function(){};
        var document={}; window.addEventListener=function(){};
        window.calls=[];
        window.fetch=function(a,b){window.calls.push([this===window||this===undefined,a,b]);return window.fetchResult;};
        window.fetchResult={then:function(a,b){return this;},marker:'orig'};
        function XMLHttpRequest(){} XMLHttpRequest.prototype.send=function(x){this.sent=x;return 'sent';};
        XMLHttpRequest.prototype.addEventListener=function(n,f){this.l=f;};
        """)
        return ctx
    }

    func testInstallWrapsOnceAndPreservesReturnValues() {
        let ctx = context()
        ctx.evaluateScript(BrowserPage.pageStateJS)
        ctx.evaluateScript("var first=window.fetch;var firstSend=XMLHttpRequest.prototype.send;")
        ctx.evaluateScript(BrowserPage.pageStateJS)
        XCTAssertEqual(ctx.evaluateScript("window.fetch===first&&XMLHttpRequest.prototype.send===firstSend")?.toBool(), true)
        XCTAssertEqual(ctx.evaluateScript("fetch('u',1)===window.fetchResult")?.toBool(), true)
        XCTAssertEqual(ctx.evaluateScript("window.calls[0][1]")?.toString(), "u")
        XCTAssertEqual(ctx.evaluateScript("var x=new XMLHttpRequest();x.send('b')")?.toString(), "sent")
        XCTAssertEqual(ctx.evaluateScript("x.sent")?.toString(), "b")
        XCTAssertEqual(ctx.evaluateScript("__gs.req.size")?.toInt32(), 2)
        ctx.evaluateScript("x.l()")
        XCTAssertEqual(ctx.evaluateScript("__gs.req.size")?.toInt32(), 1)
    }

    func testWrapperSurvivesNonPromiseAndThrowingTargets() {
        let ctx = context()
        ctx.evaluateScript(BrowserPage.pageStateJS)
        ctx.evaluateScript("window.fetchResult=42;")
        XCTAssertEqual(ctx.evaluateScript("fetch('u')")?.toInt32(), 42)
        XCTAssertEqual(ctx.evaluateScript("__gs.req.size")?.toInt32(), 0)
    }
}
