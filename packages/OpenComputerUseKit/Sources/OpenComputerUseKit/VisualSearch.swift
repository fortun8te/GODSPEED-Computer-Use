import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO

/// A read-only bridge from a semantic description to a point in the exact screenshot returned to the caller.
/// A model suggestion never authorizes input or establishes that the target exists.
enum VisualSearch {
    static func queries(_ raw: Any?) throws -> [String] {
        guard let raw else { return [] }
        guard let values = raw as? [String], (1...2).contains(values.count) else {
            throw ComputerUseError.invalidArguments("visual_queries must contain one or two descriptions.")
        }
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cleaned.allSatisfy({ !$0.isEmpty && $0.count <= 240 && !$0.contains(where: { $0.isNewline }) }) else {
            throw ComputerUseError.invalidArguments("Each visual description must be a single line of 1 to 240 characters.")
        }
        return cleaned
    }

    /// Optional normalized top-left region; explicit scope prevents irrelevant canvas panels from competing.
    static func region(_ raw: Any?) throws -> CGRect? {
        guard let raw else { return nil }
        guard let values = raw as? [NSNumber], values.count == 4,
              values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite }) else {
            throw ComputerUseError.invalidArguments("visual_region must be [x, y, width, height] as four fractions.")
        }
        let v = values.map(\.doubleValue)
        guard v[0] >= 0, v[1] >= 0, v[2] > 0, v[3] > 0,
              v[0] + v[2] <= 1, v[1] + v[3] <= 1 else {
            throw ComputerUseError.invalidArguments("visual_region must be inside the screenshot.")
        }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static func cropPixel(_ fraction: CGPoint, crop: CGRect, width: Int, height: Int) -> CGPoint? {
        guard width > 0, height > 0, (0..<1).contains(fraction.x), (0..<1).contains(fraction.y),
              !crop.isEmpty, !crop.isInfinite,
              CGRect(x: 0, y: 0, width: width, height: height).contains(crop) else { return nil }
        return pixel(CGPoint(x: (crop.minX + fraction.x * crop.width) / CGFloat(width),
                             y: (crop.minY + fraction.y * crop.height) / CGFloat(height)),
                     width: width, height: height)
    }

    /// Coordinates refer to the delivered screenshot, not the smaller model input.
    static func pixel(_ fraction: CGPoint, width: Int, height: Int) -> CGPoint? {
        guard width > 0, height > 0, (0..<1).contains(fraction.x), (0..<1).contains(fraction.y) else { return nil }
        return CGPoint(x: min(CGFloat(width - 1), floor(fraction.x * CGFloat(width))),
                       y: min(CGFloat(height - 1), floor(fraction.y * CGFloat(height))))
    }

    static func annotate(_ state: ToolCallResult, queries: [String], region: CGRect?, windowID: CGWindowID) throws -> ToolCallResult {
        guard !queries.isEmpty else { return state }
        func append(_ lines: [String]) -> ToolCallResult {
            var content = state.content
            content.insert(.text(lines.joined(separator: "\n")),
                           at: content.firstIndex { $0.dictionary["type"] as? String == "image" } ?? content.endIndex)
            return state.replacingContent(content)
        }
        guard !state.isError, let data = state.content.first(where: { $0.dictionary["type"] as? String == "image" })?.dictionary["data"] as? String,
              let bytes = Data(base64Encoded: data),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return append(["Visual search unavailable: no delivered window screenshot."])
        }
        guard VisionFallback.isEnabled else {
            return append(["Visual search unavailable: configure the optional local vision helper."])
        }
        guard !LearningScrubber.marksSecureField([state.textContent]) else {
            return append(["Visual search unavailable: secure-field evidence in the window."])
        }
        let requested = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let crop = VisionFallback.pixelCrop(requested, width: image.width, height: image.height),
              let scoped = region == nil ? image : image.cropping(to: crop),
              let overview = LocalWindowImage.downscaled(scoped),
              let jpeg = LocalWindowImage.jpeg(overview) else {
            return append(["Visual search unavailable: image encoding failed."])
        }
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + min(VisionFallback.timeout, BrowserCallBudget.activeRemaining ?? .infinity)
        let encoded = jpeg.base64EncodedString()
        var lines = ["Visual search — UNVERIFIED proposals for Window ID \(windowID), screenshot \(image.width)x\(image.height). No input sent."]
        if region != nil { lines.append("Search limited to the requested region; coordinates refer to the entire screenshot.") }
        for (index, query) in queries.enumerated() {
            try RequestCancellation.check(delivery: .notSent)
            let remaining = deadline - clock.systemUptime
            guard remaining > 0 else { lines.append("Query \(index + 1): budget exhausted."); continue }
            let fraction = VisionFallback.locate(imageBase64: encoded, query: query, remaining: remaining)
            try RequestCancellation.check(delivery: .notSent)
            guard let fraction, let point = cropPixel(fraction, crop: crop, width: image.width, height: image.height) else {
                lines.append("Query \(index + 1): no usable proposal.")
                continue
            }
            lines.append("Query \(index + 1): x=\(Int(point.x)), y=\(Int(point.y)).")
        }
        lines.append("Inspect the screenshot and confirm each intended target before using existing window-bound pixel click or drag. Read again if the view changes.")
        return append(lines)
    }
}
