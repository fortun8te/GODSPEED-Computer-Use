import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

final class VisualSearchTests: XCTestCase {
    func testDescriptionsAreBoundedAndExplicit() throws {
        XCTAssertEqual(try VisualSearch.queries(nil), [])
        XCTAssertEqual(try VisualSearch.queries(["  blue circle  ", "arrow icon"]), ["blue circle", "arrow icon"])
        for invalid in [[], ["a", "b", "c"], [""], ["one\ntwo"], [String(repeating: "x", count: 241)]] {
            XCTAssertThrowsError(try VisualSearch.queries(invalid))
        }
        XCTAssertThrowsError(try VisualSearch.queries("icon"))
    }

    func testRegionsRejectMalformedAndOutsideCoordinates() throws {
        XCTAssertNil(try VisualSearch.region(nil))
        XCTAssertEqual(try VisualSearch.region([0.25, 0.5, 0.5, 0.5]), CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertThrowsError(try VisualSearch.region([0.8, 0, 0.3, 1]))
        XCTAssertThrowsError(try VisualSearch.region([0, 0, 0, 1]))
        XCTAssertThrowsError(try VisualSearch.region([0.0, 0.0, Double.nan, 1.0]))
        XCTAssertThrowsError(try VisualSearch.region([true, 0, 1, 1] as [Any]))
    }

    func testCoordinatesMapToDeliveredImageNotModelInput() {
        XCTAssertEqual(VisualSearch.pixel(CGPoint(x: 0.5, y: 0.5), width: 2561, height: 1601),
                       CGPoint(x: 1280, y: 800))
        XCTAssertEqual(VisualSearch.cropPixel(CGPoint(x: 0.5, y: 0.5), crop: CGRect(x: 600, y: 200, width: 800, height: 600),
                                               width: 2561, height: 1601), CGPoint(x: 1000, y: 500))
        XCTAssertNil(VisualSearch.pixel(CGPoint(x: 1, y: 0.2), width: 2561, height: 1601))
        XCTAssertNil(VisualSearch.pixel(CGPoint(x: CGFloat.nan, y: 0.2), width: 2561, height: 1601))
        XCTAssertNil(VisualSearch.cropPixel(CGPoint(x: 0.5, y: 0.5), crop: CGRect(x: -1, y: 0, width: 10, height: 10),
                                             width: 2561, height: 1601))
    }

    func testNoScreenshotDoesNotInvokeHelper() throws {
        let state = ToolCallResult.text("Window ID: 42")
        let result = try VisualSearch.annotate(state, queries: ["icon"], region: nil, windowID: 42)
        XCTAssertTrue(result.textContent.contains("no delivered window screenshot"))
        XCTAssertEqual(result.primaryText, state.primaryText)
    }
}
