import Foundation

public struct ToolResultContentItem: @unchecked Sendable {
    let dictionary: [String: Any]

    public static func text(_ text: String) -> ToolResultContentItem {
        ToolResultContentItem(
            dictionary: [
                "type": "text",
                "text": text,
            ]
        )
    }

    static func screenshotImage(_ data: Data) -> ToolResultContentItem {
        ToolResultContentItem(dictionary: [
            "type": "image", "data": data.base64EncodedString(),
            "mimeType": data.starts(with: [0xff, 0xd8, 0xff]) ? "image/jpeg" : (data.count >= 12 && String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WEBP" ? "image/webp" : "image/png"),
        ])
    }

    public static func pngImage(_ data: Data) -> ToolResultContentItem {
        ToolResultContentItem(
            dictionary: [
                "type": "image",
                "data": data.base64EncodedString(),
                "mimeType": "image/png",
            ]
        )
    }
}

public struct ToolCallResult: @unchecked Sendable {
    public let content: [ToolResultContentItem]
    public let isError: Bool
    let batchReceipt: TrajectoryLog.BatchReceipt?
    let failureCode: TrajectoryLog.FailureCode?
    let browserObservationURL: String?
    let browserFullObservationText: String?
    let browserContinuationTabID: Int?
    let browserPreviewPages: [[String: Any]]?

    public init(content: [ToolResultContentItem], isError: Bool = false) {
        self.init(content: content, isError: isError, batchReceipt: nil)
    }

    init(
        content: [ToolResultContentItem], isError: Bool,
        batchReceipt: TrajectoryLog.BatchReceipt? = nil, failureCode: TrajectoryLog.FailureCode? = nil,
        browserObservationURL: String? = nil, browserContinuationTabID: Int? = nil,
        browserPreviewPages: [[String: Any]]? = nil, browserFullObservationText: String? = nil
    ) {
        self.content = content
        self.isError = isError
        self.batchReceipt = batchReceipt
        self.failureCode = failureCode
        self.browserObservationURL = browserObservationURL
        self.browserFullObservationText = browserFullObservationText
        self.browserContinuationTabID = browserContinuationTabID
        self.browserPreviewPages = browserPreviewPages
    }

    public var primaryText: String? {
        content.first(where: { $0.dictionary["type"] as? String == "text" })?.dictionary["text"] as? String
    }

    /// Plain-text CLI output includes observation notes but never image bytes.
    public var textContent: String {
        content.compactMap { item in
            item.dictionary["type"] as? String == "text" ? item.dictionary["text"] as? String : nil
        }.joined(separator: "\n")
    }

    public var asDictionary: [String: Any] {
        var result: [String: Any] = [
            "content": content.map(\.dictionary),
            "isError": isError,
        ]
        var metadata: [String: Any] = [:]
        metadata["godspeed/preview_pages"] = browserPreviewPages
        if let failureCode, failureCode == .staleRef || failureCode == .windowChanged {
            metadata["godspeed/error_code"] = failureCode.rawValue
        }
        if let receipt = batchReceipt {
            var batch: [String: Any] = [
                "total_steps": receipt.totalSteps,
                "steps": receipt.steps.enumerated().map { $0.element.metadata(number: $0.offset + 1) },
                "not_run": max(0, receipt.totalSteps - receipt.steps.count),
                "observation": receipt.observation.rawValue,
                "completion": receipt.doneCheck.rawValue,
            ]
            batch["stop"] = receipt.stop?.rawValue
            batch["recovery"] = receipt.recovery
            metadata["godspeed/batch"] = batch
        }
        if !metadata.isEmpty { result["_meta"] = metadata }
        return result
    }

    public static func text(_ text: String, isError: Bool = false) -> ToolCallResult {
        ToolCallResult(content: [.text(text)], isError: isError)
    }
}
