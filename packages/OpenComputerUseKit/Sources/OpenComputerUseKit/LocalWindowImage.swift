import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LocalWindowImage {
    static let maxSide = 1_280

    static func downscaled(_ image: CGImage) -> CGImage? {
        let side = max(image.width, image.height)
        guard side > maxSide else { return image }
        let scale = Double(maxSide) / Double(side)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 1_048_576 else { return nil }
        return data as Data
    }
}

/// Picture support is advertised by the helper. Older servers have a smaller text-only body limit.
enum RefereePicture {
    static func attachment(url: URL?, visionEnabled: Bool, state: String, remaining: TimeInterval?,
                           supportsPictures: (URL, TimeInterval) -> Bool,
                           capture: () -> Data?) -> String? {
        guard let url, HelperAutoStarter.isLoopback(url), visionEnabled, HandoffTool.observedWindowID(in: state) != nil,
              (remaining ?? .infinity) >= 1.2, RefereeView.isThin(state),
              supportsPictures(url.appendingPathComponent("health"), 0.15),
              let image = capture() else { return nil }
        return image.base64EncodedString()
    }
}
