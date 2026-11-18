import CoreFoundation
import Foundation
import ImageIO

/// Optional local vision fallback for `click` with a `label`: when no accessibility element matches
/// (canvas apps, games, some web content), take one screenshot of the window, ask a small local
/// vision model (LFM3-VL-2B through the helper service in ~/.ocu-referee, `POST /locate`) where the
/// label is, and click there. Off unless `OPEN_COMPUTER_USE_VISION_URL` is set. A missing or slow
/// service only means the original "no element labelled ..." error is returned.
///
/// Contract: request {"image_base64": str, "query": str}; reply {"found": bool, "x": 0-1, "y": 0-1,
/// "ms": int}, where x and y are fractions of the image width and height.
enum VisionFallback {
    static let baseURL: URL? = {
        guard let raw = GodspeedSettings.environment["OPEN_COMPUTER_USE_VISION_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }()

    /// Default 8 s: one answer takes about 2.3 s warm, more on the first call after the model unloaded.
    static let timeout: TimeInterval = {
        let configured = GodspeedSettings.environment["OPEN_COMPUTER_USE_VISION_TIMEOUT_MS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let milliseconds = configured.flatMap(Double.init).flatMap { (0...30_000).contains($0) ? $0 : nil } ?? 8_000
        return max(500, milliseconds) / 1000
    }()

    static var isEnabled: Bool { baseURL != nil }

    /// Where `query` is in the image, as fractions of its width and height, or nil.
    static func locate(imageBase64: String, query: String, remaining: TimeInterval? = nil) -> CGPoint? {
        guard let baseURL else { return nil }
        let wait = min(timeout, remaining ?? timeout)
        guard wait > 0 else { return nil }
        let body: [String: Any] = ["image_base64": imageBase64, "query": query]
        guard let object = HelperHTTP.postJSON(baseURL.appendingPathComponent("locate"), body: body, timeout: wait) else {
            if wait == timeout { HelperAutoStarter.shared.helperUnreachable(baseURL) }
            return nil
        }
        return location(in: object)
    }

    static func location(in object: [String: Any]) -> CGPoint? {
        guard let found = object["found"] as? NSNumber, CFGetTypeID(found) == CFBooleanGetTypeID(), found.boolValue,
              let x = object["x"] as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(),
              let y = object["y"] as? NSNumber, CFGetTypeID(y) != CFBooleanGetTypeID(),
              (0...1).contains(x.doubleValue), (0...1).contains(y.doubleValue)
        else { return nil }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    /// Pixel width and height of an encoded image (PNG, JPEG or WebP).
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
