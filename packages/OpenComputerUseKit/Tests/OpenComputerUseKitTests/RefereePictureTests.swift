import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class RefereePictureTests: XCTestCase {
    func testOptionalPictureRequiresThinBoundWindowAndOptInLoopbackCapability() throws {
        let thin = "App=fixture.sketch (pid 1)\nWindow: Sketch\nWindow ID: 24\n0 canvas\n1 button"
        let rich = "App=fixture.Finder (pid 2)\nWindow: Finder\nWindow ID: 25\n1 button Back\n2 button Share\n3 button Search"
        let iconOnly = rich + "\n4 button (w:bool)"
        let emptyWebArea = rich + "\n5 web area"
        let healthy = try XCTUnwrap(URL(string: "http://127.0.0.1:8765"))
        let remote = try XCTUnwrap(URL(string: "https://example.invalid"))
        var captures = 0
        func attachment(_ url: URL, _ state: String, enabled: Bool = true, v1: Bool = true, remaining: Double = 3) -> String? {
            RefereePicture.attachment(url: url, visionEnabled: enabled, state: state, remaining: remaining,
                supportsPictures: { endpoint, _ in
                    XCTAssertEqual(endpoint.path, "/health")
                    return v1
                }, capture: {
                    captures += 1
                    return Data([1, 2, 3])
                })
        }
        XCTAssertNil(attachment(healthy, rich))
        XCTAssertNil(attachment(healthy, thin, enabled: false))
        XCTAssertNil(attachment(healthy, thin, v1: false))
        XCTAssertNil(attachment(healthy, thin, remaining: 0))
        XCTAssertNil(attachment(remote, thin))
        XCTAssertNil(attachment(healthy, "Page: Sketch\n(little readable text)"))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(attachment(healthy, thin), "AQID")
        XCTAssertEqual(attachment(healthy, iconOnly), "AQID")
        XCTAssertEqual(attachment(healthy, emptyWebArea), "AQID")
        XCTAssertEqual(captures, 3)
    }

    func testWindowPictureDownscalesAndDoesNotUpscale() throws {
        func image(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        let wide = try XCTUnwrap(LocalWindowImage.downscaled(image(2560, 1600)))
        XCTAssertEqual(wide.width, 1280)
        XCTAssertEqual(wide.height, 800)
        let tall = try XCTUnwrap(LocalWindowImage.downscaled(image(300, 1800)))
        XCTAssertEqual(tall.width, 213)
        XCTAssertEqual(tall.height, 1280)
        XCTAssertEqual(LocalWindowImage.downscaled(try image(600, 400))?.width, 600)
    }
}
