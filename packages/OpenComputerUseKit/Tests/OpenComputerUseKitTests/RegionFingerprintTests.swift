import CoreGraphics
import Dispatch
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Tests use synthetic images only. Nothing here captures the screen.
final class RegionFingerprintTests: XCTestCase {
    /// Builds an RGB image from a gray value per pixel.
    private func image(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// A textured base: random-looking gray blocks, so no cell is flat.
    private func textureValue(_ x: Int, _ y: Int) -> UInt8 {
        var h = UInt32(truncatingIfNeeded: (x / 10) &* 73_856_093) ^ UInt32(truncatingIfNeeded: (y / 10) &* 19_349_663)
        h = (h ^ (h >> 13)) &* 0x5bd1_e995
        return UInt8(truncatingIfNeeded: h >> 8)
    }

    private func texture(width: Int = 1440, height: Int = 900) -> CGImage {
        image(width: width, height: height) { x, y in textureValue(x, y) }
    }

    /// Same texture, with a small deterministic offset of -2...2 per pixel.
    private func noisyTexture(width: Int = 1440, height: Int = 900) -> CGImage {
        image(width: width, height: height) { x, y in
            let offset = Int((x &* 31 &+ y &* 17) % 5) - 2
            return UInt8(max(0, min(255, Int(textureValue(x, y)) + offset)))
        }
    }

    /// Texture with a black rectangle drawn over it.
    private func texture(blackRect rect: CGRect) -> CGImage {
        image(width: 1440, height: 900) { x, y in
            let inside = CGFloat(x) >= rect.minX && CGFloat(x) < rect.maxX
                && CGFloat(y) >= rect.minY && CGFloat(y) < rect.maxY
            return inside ? 0 : textureValue(x, y)
        }
    }

    func testIdenticalImagesHaveNoChange() throws {
        let image = texture()
        let a = try XCTUnwrap(RegionFingerprint.make(image))
        let b = try XCTUnwrap(RegionFingerprint.make(image))
        XCTAssertEqual(a.columns, 16)
        XCTAssertEqual(a.rows, 10)
        XCTAssertEqual(a.hashes.count, 160)
        XCTAssertEqual(a.changedCells(comparedTo: b), [])
        XCTAssertNil(a.changedRect(comparedTo: b, in: CGSize(width: 1440, height: 900)))
    }

    func testFilledTopLeftCellChangesOnlyThatCell() throws {
        let before = try XCTUnwrap(RegionFingerprint.make(texture()))
        // Exactly the top-left cell: 1440/16 = 90 wide, 900/10 = 90 tall.
        let after = try XCTUnwrap(RegionFingerprint.make(texture(blackRect: CGRect(x: 0, y: 0, width: 90, height: 90))))
        XCTAssertEqual(after.changedCells(comparedTo: before), [0])
    }

    func testFilledBottomRightCellChangesOnlyThatCell() throws {
        let before = try XCTUnwrap(RegionFingerprint.make(texture()))
        let after = try XCTUnwrap(RegionFingerprint.make(texture(blackRect: CGRect(x: 1350, y: 810, width: 90, height: 90))))
        // Bottom-right cell: row 9, column 15.
        XCTAssertEqual(after.changedCells(comparedTo: before), [9 * 16 + 15])
    }

    func testRectAcrossCellEdgesOnlyMarksTouchedCells() throws {
        let before = try XCTUnwrap(RegionFingerprint.make(texture()))
        let after = try XCTUnwrap(RegionFingerprint.make(texture(blackRect: CGRect(x: 0, y: 0, width: 100, height: 100))))
        let changed = after.changedCells(comparedTo: before)
        XCTAssertTrue(changed.contains(0), "\(changed)")
        XCTAssertTrue(Set(changed).isSubset(of: [0, 1, 16, 17]), "\(changed)")
    }

    func testTinyNoiseBelowThresholdIsNoChange() throws {
        let before = try XCTUnwrap(RegionFingerprint.make(texture()))
        let after = try XCTUnwrap(RegionFingerprint.make(noisyTexture()))
        XCTAssertEqual(after.changedCells(comparedTo: before, threshold: 6), [])
    }

    func testDifferentGridSizeCountsEveryCellAsChanged() throws {
        let image = texture()
        let wide = try XCTUnwrap(RegionFingerprint.make(image))
        let coarse = try XCTUnwrap(RegionFingerprint.make(image, columns: 8, rows: 5))
        XCTAssertEqual(coarse.changedCells(comparedTo: wide), Array(0..<40))
        XCTAssertEqual(wide.changedCells(comparedTo: coarse), Array(0..<160))
        let rect = wide.changedRect(comparedTo: coarse, in: CGSize(width: 1440, height: 900))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testImageSmallerThanGridReturnsNil() {
        let tiny = image(width: 4, height: 4) { _, _ in 0 }
        XCTAssertNil(RegionFingerprint.make(tiny))
        XCTAssertNil(RegionFingerprint.make(texture(), columns: 0, rows: 10))
    }

    func testChangedRectMatchesChangedCells() throws {
        let size = CGSize(width: 1440, height: 900)
        let before = try XCTUnwrap(RegionFingerprint.make(texture()))

        let corner = try XCTUnwrap(RegionFingerprint.make(texture(blackRect: CGRect(x: 0, y: 0, width: 90, height: 90))))
        XCTAssertEqual(corner.changedRect(comparedTo: before, in: size), CGRect(x: 0, y: 0, width: 90, height: 90))

        // Two cells in different corners: the rect covers both.
        let twoCorners = image(width: 1440, height: 900) { x, y in
            let topLeft = x < 90 && y < 90
            let bottomRight = x >= 1350 && y >= 810
            return (topLeft || bottomRight) ? 0 : textureValue(x, y)
        }
        let two = try XCTUnwrap(RegionFingerprint.make(twoCorners))
        XCTAssertEqual(two.changedRect(comparedTo: before, in: size), CGRect(origin: .zero, size: size))
        XCTAssertNil(before.changedRect(comparedTo: before, in: size))
    }

    func testMakeIsFastOn1440x900() throws {
        let frame = texture()
        // Warm up once, then average a few runs.
        _ = RegionFingerprint.make(frame)
        let runs = 5
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs {
            XCTAssertNotNil(RegionFingerprint.make(frame))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1_000_000
        print("RegionFingerprint.make 1440x900: \(String(format: "%.2f", elapsed)) ms average over \(runs) runs")
        XCTAssertLessThan(elapsed, 50, "make() took \(elapsed) ms")
    }
}
