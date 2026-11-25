import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class LocalPerceptionTests: XCTestCase {
    func testModelFreeLabelMissKeepsOCRButNeverBroadensDelivery() {
        RequestConfiguration.withEnvironment(["OPEN_COMPUTER_USE_MODEL_HELPERS": "0"]) {
            XCTAssertFalse(VisionFallback.isEnabled)
            func allowed(_ error: ComputerUseError = .targetNotFound("no match"), strict: Bool = false,
                         pinned: Bool = false, count: Int = 1, button: String = "left") -> Bool {
                ComputerUseService.allowsLocalPerceptionFallback(error: error, strict: strict,
                    windowBound: pinned, clickCount: count, mouseButton: button)
            }
            XCTAssertTrue(allowed())
            XCTAssertFalse(allowed(.ambiguousTarget("several matches")))
            XCTAssertFalse(allowed(.staleTarget("changed")))
            XCTAssertFalse(allowed(strict: true))
            XCTAssertFalse(allowed(pinned: true))
            XCTAssertFalse(allowed(count: 2))
            XCTAssertFalse(allowed(button: "right"))
        }
    }

    func testFastOCRSkipsAccurateAndHelper() {
        let expected = CGPoint(x: 0.2, y: 0.3)
        let candidate = VisionFallback.candidate(scan: { accurate in
            XCTAssertFalse(accurate)
            return .point(expected)
        }, locate: { XCTFail("called model after OCR"); return nil })
        XCTAssertEqual(candidate?.evidence, .ocr)
        XCTAssertEqual(candidate?.fraction, expected)
    }

    func testAccurateThenHelperOnlyOnMissingText() {
        var order: [String] = []
        let point = CGPoint(x: 0.2, y: 0.3)
        func find(accurateResult: LocalOCR.Scan) -> VisionFallback.Candidate? {
            VisionFallback.candidate(scan: { accurate in
                order.append(accurate ? "accurate" : "fast")
                return accurate ? accurateResult : .missing
            }, locate: { order.append("model"); return point })
        }
        XCTAssertEqual(find(accurateResult: .point(point))?.evidence, .ocr)
        XCTAssertEqual(order, ["fast", "accurate"])
        order.removeAll()
        XCTAssertEqual(find(accurateResult: .missing)?.evidence, .model)
        XCTAssertEqual(order, ["fast", "accurate", "model"])
        order.removeAll()
        XCTAssertNil(find(accurateResult: .ambiguous))
        XCTAssertEqual(order, ["fast", "accurate"])
    }

    func testTextMustMatchExactlyAndMapFromImageToWindow() throws {
        let match = LocalOCR.Match(text: "Résumé", bounds: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25))
        guard case .point(let fraction) = LocalOCR.match([match], label: "resume") else { return XCTFail() }
        let bounds = CGRect(x: -280, y: 80, width: 800, height: 400)
        XCTAssertEqual(VisionFallback.windowPoint(fraction, bounds: bounds), CGPoint(x: 300, y: 150))
        XCTAssertNil(VisionFallback.windowPoint(CGPoint(x: 1, y: 0.3), bounds: bounds))
        XCTAssertNil(VisionFallback.windowPoint(CGPoint(x: CGFloat.nan, y: 0.3), bounds: bounds))
        guard case .ambiguous = LocalOCR.match([match, match], label: "Résumé") else { return XCTFail() }
        guard case .missing = LocalOCR.match([match], label: "sum") else { return XCTFail() }
    }

    func testRiskAndLiveHitEvidenceGateThePoint() {
        let point = CGPoint(x: 0.5, y: 0.5)
        let model = VisionFallback.Candidate(fraction: point, evidence: .model)
        let ocr = VisionFallback.Candidate(fraction: point, evidence: .ocr)
        XCTAssertFalse(VisionFallback.allowsHit(candidate: model, label: "Overview", hitNames: []))
        XCTAssertFalse(VisionFallback.allowsHit(candidate: model, label: "Overview", hitNames: ["Other"]))
        XCTAssertTrue(VisionFallback.allowsHit(candidate: model, label: "Overview", hitNames: ["Overview"]))
        XCTAssertTrue(VisionFallback.allowsHit(candidate: ocr, label: "Overview", hitNames: []))
        for risk in ["Send now", "Pay", "Delete draft"] {
            XCTAssertFalse(VisionFallback.allowsHit(candidate: ocr, label: risk, hitNames: []))
            XCTAssertFalse(VisionFallback.allowsHit(candidate: model, label: "Overview", hitNames: ["Overview", risk]))
        }
        XCTAssertNil(VisionFallback.localURL(nil))
        XCTAssertNil(VisionFallback.localURL("https://example.invalid"))
        XCTAssertNotNil(VisionFallback.localURL("http://127.0.0.1:8765"))
    }

    func testRedrawnPixelsInvalidateTheCapture() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let first = try XCTUnwrap(context.makeImage())
        XCTAssertTrue(VisionFallback.sameCapture(first, try XCTUnwrap(context.makeImage())))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 14, y: 12, width: 2, height: 2))
        XCTAssertFalse(VisionFallback.sameCapture(first, try XCTUnwrap(context.makeImage())))
    }
}
