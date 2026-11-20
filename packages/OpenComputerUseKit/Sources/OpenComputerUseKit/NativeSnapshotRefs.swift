import CoreGraphics
import Foundation

struct NativeWindowObservation {
    let id: CGWindowID
    let app: TargetedAppIdentity

    func matches(windowID: CGWindowID, app: TargetedAppIdentity) -> Bool {
        id == windowID && self.app == app
    }
}

/// Tokens belong to one observed tree. They never resolve by label or by a
/// number in a later tree, even if that number was assigned to a new control.
struct NativeSnapshotRefs {
    let generation = UUID()
    let client = ClientScope.current
    private let indexes: [String: Int]

    init(elementIndexes: [Int]) {
        indexes = Dictionary(uniqueKeysWithValues: elementIndexes.map { ("n1_" + UUID().uuidString, $0) })
    }

    func index(for ref: String) throws -> Int {
        guard client == ClientScope.current, let index = indexes[ref] else {
            throw ComputerUseError.staleRef
        }
        return index
    }

    /// A ref is the only target on the call. A window ID may further restrict it.
    static func argument(in arguments: [String: Any], tool: String) throws -> String? {
        guard let raw = arguments["ref"] else { return nil }
        guard ArgumentNormalizer.elementTools.contains(tool) else {
            throw ComputerUseError.invalidArguments("ref is only for native element actions")
        }
        guard let ref = raw as? String, !ref.isEmpty, ref.utf8.count <= 64 else {
            throw ComputerUseError.invalidArguments("ref must be a token from get_app_state")
        }
        guard !["label", "labels", "element_index", "x", "y"].contains(where: { arguments[$0] != nil }) else {
            throw ComputerUseError.invalidArguments("Use ref as the only element target.")
        }
        return ref
    }

    var text: String {
        let rows = indexes.sorted { $0.value < $1.value }.map { "\($0.value) = \($0.key)" }
        return (["Element refs by index"] + rows).joined(separator: "\n")
    }
}
