import Foundation

public struct SnapshotObservationOptions: Equatable, Sendable {
    public var includeAX: Bool
    public var includeScreenshot: Bool
    public var includeMenuBar: Bool

    public static let defaults = SnapshotObservationOptions()
    public static let accessibilityOmittedNote = "Accessibility omitted; previous element indexes invalidated. Read AX before element-targeted actions."
    public static let screenshotOmittedNote = "Screenshot omitted by include_screenshot=false"

    public init(includeAX: Bool = true, includeScreenshot: Bool = true, includeMenuBar: Bool = false) {
        self.includeAX = includeAX
        self.includeScreenshot = includeScreenshot
        self.includeMenuBar = includeMenuBar
    }

    func readMenuBar(_ read: () -> Void) {
        if includeAX, includeMenuBar { read() }
    }

    public func validate() throws {
        guard includeAX || includeScreenshot else {
            throw ComputerUseError.invalidArguments("At least one of include_ax or include_screenshot must be true")
        }
    }
}
