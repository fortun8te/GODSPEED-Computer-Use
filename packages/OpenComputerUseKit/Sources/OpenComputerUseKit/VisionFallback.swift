import CoreFoundation
import Foundation
import ImageIO

/// Optional grounding for an unambiguous labelled miss. The returned point is a suggestion.
enum VisionFallback {
    /// Read per request (L6): the settings file and each caller's options can change it.
    static var baseURL: URL? { localURL(GodspeedSettings.environment["OPEN_COMPUTER_USE_VISION_URL"]) }

    static func localURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              HelperAutoStarter.isLoopback(url) else { return nil }
        return url
    }

    /// Default 8 s: one answer takes about 2.3 s warm, more on the first call after the model unloaded.
    static var timeout: TimeInterval {
        let configured = GodspeedSettings.environment["OPEN_COMPUTER_USE_VISION_TIMEOUT_MS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let milliseconds = configured.flatMap(Double.init).flatMap { (0...30_000).contains($0) ? $0 : nil } ?? 8_000
        return max(500, milliseconds) / 1000
    }

    static var isEnabled: Bool { baseURL != nil }

    /// `zoom` is a second /locate on a zoomed crop around a model point (GroundingCascade step 5).
    enum Evidence: Equatable { case ocr, model, zoom }

    /// The learning-log name of an evidence kind.
    static func evidenceName(_ evidence: Evidence) -> String {
        switch evidence {
        case .ocr: return "ocr"
        case .model: return "model"
        case .zoom: return "zoom"
        }
    }

    struct Candidate {
        let fraction: CGPoint
        let evidence: Evidence
    }

    static func candidate(scan: (_ accurate: Bool) -> LocalOCR.Scan,
                          locate: () -> CGPoint?) -> Candidate? {
        for accurate in [false, true] {
            switch scan(accurate) {
            case .point(let point): return Candidate(fraction: point, evidence: .ocr)
            case .ambiguous: return nil
            case .missing: continue
            }
        }
        return locate().map { Candidate(fraction: $0, evidence: .model) }
    }

    /// Learning row for one grounding attempt, found or not (see visionClick). The crop is saved only when
    /// images are on, and the PNG is encoded only then. Nothing is written unless LearningLog is enabled.
    /// `secure` is true when the window or the target is a password or secure field: the row is kept, the image is not.
    static func recordLocate(query: String, crop: CGImage, candidate: Candidate?, verified: Bool, secure: Bool,
                             log: LearningLog) {
        guard log.isEnabled else { return }
        let image = log.imagesEnabled && !secure ? LocalWindowImage.png(crop).flatMap { log.saveImage($0) } : nil
        log.append(LearningLocateRow(
            query: query, crop_width: Double(crop.width), crop_height: Double(crop.height),
            point: candidate.map { [Double($0.fraction.x), Double($0.fraction.y)] },
            verified: verified, image: image,
            evidence: candidate.map { evidenceName($0.evidence) }
        ))
    }

    static func sameName(_ left: String, _ right: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let lhs = left.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let rhs = right.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !lhs.isEmpty && lhs.compare(rhs, options: options) == .orderedSame
    }

    static func risky(_ label: String) -> Bool {
        HandoffTool.isRisky(label: label) || MenuItemLookup.isDestructive(label)
    }

    static func allowsHit(candidate: Candidate, label: String, hitNames: [String]) -> Bool {
        guard !risky(label), !hitNames.contains(where: risky) else { return false }
        if hitNames.contains(where: { sameName($0, label) }) { return true }
        // OCR can identify text drawn in an unnamed surface. A model point alone cannot identify it.
        return candidate.evidence == .ocr && hitNames.isEmpty
    }

    /// Both OCR and the helper use top-left fractions. Scaling the whole crop preserves these fractions.
    static func windowPoint(_ fraction: CGPoint, bounds: CGRect) -> CGPoint? {
        guard (0..<1).contains(fraction.x), (0..<1).contains(fraction.y),
              WindowCaptureGeometry.isValid(bounds) else { return nil }
        return CGPoint(x: fraction.x * bounds.width, y: fraction.y * bounds.height)
    }

    static func sameCapture(_ original: CGImage, _ fresh: CGImage) -> Bool {
        guard original.width == fresh.width, original.height == fresh.height,
              original.bytesPerRow == fresh.bytesPerRow,
              let left = original.dataProvider?.data, let right = fresh.dataProvider?.data else { return false }
        return CFEqual(left, right)
    }

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
