import Foundation

let computerUseNoWindowFoundMessage = "The app has no window to read (no document open, or only a system Open dialog, which cannot be driven). To start a document: press_menu {app, path: \"File > New\"}; to open a file: open {path}."

public enum ComputerUseError: Error, LocalizedError {
    case message(String)
    case unsupportedTool(String)
    case invalidArguments(String)
    case appNotFound(String)
    case permissionDenied(String)
    case stateUnavailable(String)
    case notSent(String)
    case targetNotFound(String)
    case ambiguousTarget(String)
    case staleTarget(String)
    case elementGone(String)
    case timedOut(String, delivery: DeliveryState)
    case acknowledged(String)

    public var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        case .unsupportedTool(let name):
            return "unsupportedTool(\"\(name)\")"
        case .invalidArguments(let message):
            return "invalidArguments(\"\(message)\")"
        case .appNotFound(let app):
            return "appNotFound(\"\(app)\")"
        case .permissionDenied(let message):
            return message
        case .stateUnavailable(let message), .notSent(let message), .staleTarget(let message),
             .elementGone(let message), .timedOut(let message, _), .acknowledged(let message):
            return message
        case .targetNotFound(let message), .ambiguousTarget(let message):
            return "invalidArguments(\"\(message)\")"
        }
    }

    var toolResultIsError: Bool { true }

    /// Unclassified errors are conservative: they do not prove a command was never sent.
    public var deliveryState: DeliveryState {
        switch self {
        case .unsupportedTool, .invalidArguments, .appNotFound, .permissionDenied, .notSent,
             .targetNotFound, .ambiguousTarget, .staleTarget, .elementGone:
            return .notSent
        case .timedOut(_, let delivery):
            return delivery
        case .acknowledged:
            return .acknowledged
        case .stateUnavailable, .message:
            return .outcomeUnknown
        }
    }
}

extension ComputerUseError {
    static func missingArgument(_ name: String) -> ComputerUseError {
        .notSent("Missing required argument: \(name)")
    }
}
