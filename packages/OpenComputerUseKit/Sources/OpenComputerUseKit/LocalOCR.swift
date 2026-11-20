import CoreGraphics
import Vision

enum LocalOCR {
    struct Match {
        let text: String
        /// Vision reports fractions from the bottom left.
        let bounds: CGRect
    }

    enum Scan {
        case missing
        case ambiguous
        case point(CGPoint)
    }

    static func scan(_ image: CGImage, label: String, level: VNRequestTextRecognitionLevel) -> Scan {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return .missing }
        let matches = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Match(text: $0.string, bounds: observation.boundingBox) }
        }
        return match(matches, label: label)
    }

    static func match(_ matches: [Match], label: String) -> Scan {
        let found = matches.filter { VisionFallback.sameName($0.text, label) }
        guard found.count < 2 else { return .ambiguous }
        guard let box = found.first?.bounds, box.width > 0, box.height > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(box) else { return .missing }
        return .point(CGPoint(x: box.midX, y: 1 - box.midY))
    }
}
