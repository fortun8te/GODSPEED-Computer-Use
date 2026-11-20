import Foundation

let computerUseNoWindowFoundMessage = "The app has no window to read (no document open, or only a system Open dialog, which cannot be driven). To start a document: press_menu {app, path: \"File > New\"}; to open a file: open {path}."

public enum ComputerUseError: Error, LocalizedError {
    case message(String)
    case unsupportedTool(String)
    case invalidArguments(String)
    case appNotFound(String)
    case permissionDenied(String)
    case stateUnavailable(String)
    case backgroundUnsupported(String)
    case approvalRequired(String)
    case actionDenied(String)

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
        case .backgroundUnsupported(let message):
            return "BACKGROUND_UNSUPPORTED: \(message)"
        case .approvalRequired(let message):
            return "APPROVAL_REQUIRED: \(message)"
        case .actionDenied(let message):
            return "ACTION_DENIED: \(message)"
        case .stateUnavailable(let message):
            return message
        }
    }

    var toolResultIsError: Bool {
        true
    }
}

extension ComputerUseError {
    static func missingArgument(_ name: String) -> ComputerUseError {
        .message("Missing required argument: \(name)")
    }
}
