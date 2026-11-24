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
    public let deliveryState: DeliveryState
    let handoffMetrics: [String: Int]?
    let batchReceipt: TrajectoryLog.BatchReceipt?
    let failureCode: TrajectoryLog.FailureCode?
    let browserObservationURL: String?
    let browserEvidenceScope: BrowserEvidenceScope?
    let browserFullObservationText: String?
    let observedFields: [DoneCheck.Field]?
    let browserContinuationTabID: Int?
    let browserPreviewPages: [[String: Any]]?

    public init(content: [ToolResultContentItem], isError: Bool = false, deliveryState: DeliveryState? = nil) {
        self.init(content: content, isError: isError, batchReceipt: nil, deliveryState: deliveryState)
    }

    init(
        content: [ToolResultContentItem], isError: Bool,
        batchReceipt: TrajectoryLog.BatchReceipt? = nil, failureCode: TrajectoryLog.FailureCode? = nil,
        browserObservationURL: String? = nil, browserContinuationTabID: Int? = nil,
        browserPreviewPages: [[String: Any]]? = nil, browserFullObservationText: String? = nil,
        browserEvidenceScope: BrowserEvidenceScope? = nil, observedFields: [DoneCheck.Field]? = nil,
        deliveryState: DeliveryState? = nil, handoffMetrics: [String: Int]? = nil
    ) {
        self.content = content
        self.isError = isError
        self.deliveryState = deliveryState ?? (isError ? .outcomeUnknown : .acknowledged)
        self.handoffMetrics = handoffMetrics
        self.batchReceipt = batchReceipt
        self.failureCode = failureCode
        self.browserObservationURL = browserObservationURL
        self.browserEvidenceScope = browserEvidenceScope
        self.observedFields = observedFields
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
        for (key, value) in deliveryState.metadata { metadata["godspeed/\(key)"] = value }
        metadata["godspeed/handoff"] = handoffMetrics
        metadata["godspeed/preview_pages"] = browserPreviewPages
        let code = batchReceipt?.failureCode ?? failureCode
        if let code, code == .staleRef || code == .windowChanged || code.isActionRefusal {
            metadata["godspeed/error_code"] = code.rawValue
        }
        if let receipt = batchReceipt {
            var batch: [String: Any] = [
                "total_steps": receipt.totalSteps,
                "not_run": max(0, receipt.totalSteps - receipt.steps.count),
                "observation": receipt.observation.rawValue,
                "completion": receipt.doneCheck.rawValue,
            ]
            if receipt.canSummarizeSteps, !isError {
                batch["step_summary"] = [
                    "completed": receipt.steps.count,
                    "verified": receipt.steps.filter { $0.deliveryState == .verified }.count,
                ]
            } else {
                batch["steps"] = receipt.steps.enumerated().map { $0.element.metadata(number: $0.offset + 1) }
            }
            batch["stop"] = receipt.stop?.rawValue
            batch["recovery"] = receipt.recovery
            metadata["godspeed/batch"] = batch
        }
        if !metadata.isEmpty { result["_meta"] = metadata }
        return result
    }

    func replacingContent(_ content: [ToolResultContentItem], deliveryState: DeliveryState? = nil) -> ToolCallResult {
        ToolCallResult(
            content: content, isError: isError, batchReceipt: batchReceipt, failureCode: failureCode,
            browserObservationURL: browserObservationURL, browserContinuationTabID: browserContinuationTabID,
            browserPreviewPages: browserPreviewPages, browserFullObservationText: browserFullObservationText,
            browserEvidenceScope: browserEvidenceScope, observedFields: observedFields, deliveryState: deliveryState ?? self.deliveryState,
            handoffMetrics: handoffMetrics
        )
    }

    static func delivery(of error: Error) -> DeliveryState {
        (error as? ComputerUseError)?.deliveryState
            ?? (error as? RequestCancellation.Cancelled)?.deliveryState
            ?? .outcomeUnknown
    }

    static func failure(_ error: Error) -> ToolCallResult {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return ToolCallResult(
            content: [.text(message)], isError: true, failureCode: TrajectoryLog.failureCode(error: error),
            deliveryState: delivery(of: error)
        )
    }

    public static func text(_ text: String, isError: Bool = false, deliveryState: DeliveryState? = nil) -> ToolCallResult {
        ToolCallResult(content: [.text(text)], isError: isError, deliveryState: deliveryState)
    }
}
