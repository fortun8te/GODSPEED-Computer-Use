import XCTest
@testable import OpenComputerUseKit

final class BrowserFormattedPasteTests: XCTestCase {
    func testSuppliedPasteTextDoesNotUseTheClipboard() throws {
        let payload = try XCTUnwrap(BrowserFormattedPaste.directPayload(["text": "fresh draft"]))
        XCTAssertEqual(payload.format, "text")
        XCTAssertEqual(payload.text, "fresh draft")
        XCTAssertNil(try BrowserFormattedPaste.directPayload([:]))
        XCTAssertThrowsError(try BrowserFormattedPaste.directPayload(["text": ""]))
        XCTAssertThrowsError(try BrowserFormattedPaste.directPayload(["format": "html"]))
    }

    func testMarkdownPreservesHeadingsInlineFormattingAndLists() throws {
        let html = try BrowserFormattedPaste.markdownHTML("# Draft\n\n**Bold** and *italic*\n\n- One\n- Two")
        XCTAssertTrue(html.contains("<h1>Draft</h1>"), html)
        XCTAssertTrue(html.contains("<strong>Bold</strong>"), html)
        XCTAssertTrue(html.contains("<em>italic</em>"), html)
        XCTAssertTrue(html.contains("<ul><li>"), html)
        XCTAssertTrue(html.contains("</li></ul>"), html)
    }

    func testMarkdownEscapesCodeAsText() throws {
        let html = try BrowserFormattedPaste.markdownHTML("`<b>&</b>`")
        XCTAssertTrue(html.contains("<code>&lt;b&gt;&amp;&lt;/b&gt;</code>"), html)
    }
}
