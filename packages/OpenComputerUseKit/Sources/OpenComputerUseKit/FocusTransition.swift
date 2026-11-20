import Foundation

public struct FocusTarget: Equatable, Sendable {
    public let windowID: Int
    public let elementRole: String
    public let label: String
    public let dialogTitle: String?

    public init(windowID: Int, elementRole: String, label: String, dialogTitle: String? = nil) {
        self.windowID = windowID
        self.elementRole = elementRole
        self.label = label
        self.dialogTitle = dialogTitle
    }
}

public struct ObservedFocus: Equatable, Sendable {
    public let windowID: Int?
    public let elementRole: String?
    public let label: String?
    public let dialogTitle: String?

    public init(windowID: Int?, elementRole: String?, label: String?, dialogTitle: String? = nil) {
        self.windowID = windowID
        self.elementRole = elementRole
        self.label = label
        self.dialogTitle = dialogTitle
    }
}

public enum FocusCheck: Equatable, Sendable {
    case ok
    case wrongWindow
    case wrongElement(expected: String, observed: String)
    case unexpectedDialog(title: String)
    case unknown
}

public enum FocusTransition {
    public static func check(target: FocusTarget, observed: ObservedFocus) -> FocusCheck {
        guard let window = observed.windowID, let role = observed.elementRole,
              let label = observed.label else { return .unknown }
        if window != target.windowID { return .wrongWindow }
        if let dialog = observed.dialogTitle {
            guard let expectedDialog = target.dialogTitle else { return .unexpectedDialog(title: dialog) }
            guard normalized(dialog) == normalized(expectedDialog) else { return .unexpectedDialog(title: dialog) }
        } else if target.dialogTitle != nil {
            return .unknown
        }
        guard normalized(role) == normalized(target.elementRole), normalized(label) == normalized(target.label) else {
            return .wrongElement(expected: "\(target.elementRole): \(target.label)", observed: "\(role): \(label)")
        }
        if normalized(role).contains("secure") && !normalized(target.elementRole).contains("secure") { return .unknown }
        return .ok
    }

    public enum Action: Sendable {
        case openSaveDialog
        case tab(currentLabel: String, orderedLabels: [String])
    }

    public static func predictedFocusAfter(action: Action) -> String? {
        switch action {
        case .openSaveDialog: return "Name"
        case let .tab(currentLabel, orderedLabels):
            guard let index = orderedLabels.firstIndex(where: { normalized($0) == normalized(currentLabel) }),
                  orderedLabels.indices.contains(index + 1) else { return nil }
            return orderedLabels[index + 1]
        }
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
