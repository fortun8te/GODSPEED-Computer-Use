import ApplicationServices
import Foundation

/// Per-snapshot cache for the accessibility reads made by the tree renderer.
///
/// The first read of an element fetches the attributes the renderer commonly uses with one
/// `AXUIElementCopyMultipleAttributeValues` call. Successful and unsupported/no-value results
/// are kept for the rest of that walk; transient errors are not kept. Only the renderer
/// enters this scope: action reads, rewalks and later snapshots always read fresh values.
/// `OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE=1` turns the cache off for output comparison.
final class AXSnapshotReadCache: NSObject {
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    enum Attribute {
        case value(CFTypeRef)
        case absent
        var value: CFTypeRef? { if case .value(let value) = self { return value }; return nil }
    }
    static let key = "OpenComputerUse.AXSnapshotReadCache"
    static var current: AXSnapshotReadCache? { Thread.current.threadDictionary[key] as? AXSnapshotReadCache }
    private var attributes: [ElementKey: [String: Attribute]] = [:]
    private var prefetched: Set<ElementKey> = []
    private var actions: [ElementKey: [String]] = [:]
    private var settable: [ElementKey: [String: Bool]] = [:]
    private var arrayCounts: [ElementKey: [String: Int]] = [:]
    private var arrays: [ElementKey: [String: [AXUIElement]]] = [:]
    let batch: (AXUIElement) -> [String: Attribute]
    let single: (AXUIElement, String) -> (AXError, CFTypeRef?)
    let readActions: (AXUIElement) -> (AXError, [String]?)
    let readSettable: (AXUIElement, String) -> (AXError, Bool)
    let readCount: (AXUIElement, String) -> (AXError, Int)
    let readPage: (AXUIElement, String, Int) -> (AXError, [AXUIElement]?)

    /// Traversal attributes are deliberately absent from the eager scalar batch. Asking a
    /// provider for a million-child array before applying the walk budget defeats that budget.
    static let arrayNames: Set<String> = ["AXChildren", "AXRows", "AXVisibleChildren", "AXContents"]
    static let maximumArrayRead = 10_000

    init(batch: @escaping (AXUIElement) -> [String: Attribute] = readBatch,
         single: @escaping (AXUIElement, String) -> (AXError, CFTypeRef?) = readSingle,
         actions: @escaping (AXUIElement) -> (AXError, [String]?) = readActionNames,
         settable: @escaping (AXUIElement, String) -> (AXError, Bool) = readIsSettable,
         count: @escaping (AXUIElement, String) -> (AXError, Int) = readArrayCount,
         page: @escaping (AXUIElement, String, Int) -> (AXError, [AXUIElement]?) = readArrayPage) {
        self.batch = batch; self.single = single
        self.readActions = actions; self.readSettable = settable
        self.readCount = count; self.readPage = page
    }

    static func withSnapshot<T>(_ body: () throws -> T) rethrows -> T {
        let cache = RequestConfiguration.environment["OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE"] == "1"
            ? nil : AXSnapshotReadCache()
        return try withCache(cache, body)
    }

    static func withCache<T>(_ cache: AXSnapshotReadCache?, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = cache
        defer { dictionary[key] = previous }
        return try body()
    }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let key = ElementKey(element: element)
        if prefetched.insert(key).inserted { attributes[key] = batch(element) }
        if Self.arrayNames.contains(name) {
            return array(element, name, limit: Self.maximumArrayRead).values as CFArray
        }
        if name == "AXValue" || name == "AXSelectedText" {
            _ = value(element, "AXSubrole")
            // A transient classification failure is not evidence of an ordinary
            // field. Leave it retryable, but do not fetch text until it resolves.
            guard let classification = attributes[key]?["AXSubrole"] else { return nil }
            if case .value(let raw) = classification {
                guard Self.permitsTextRead(subroleError: .success, subrole: raw) else { return nil }
            }
        }
        if let cached = attributes[key]?[name] { return cached.value }
        let (error, value) = single(element, name)
        if error == .success, let value { attributes[key, default: [:]][name] = .value(value); return value }
        if error == .attributeUnsupported || error == .noValue { attributes[key, default: [:]][name] = .absent }
        return nil // Transient errors are not retained.
    }

    static func permitsTextRead(subroleError: AXError, subrole: CFTypeRef?) -> Bool {
        if subroleError == .attributeUnsupported || subroleError == .noValue { return subrole == nil }
        guard subroleError == .success, let name = subrole as? String else { return false }
        return !isSecureTextField(subrole: name)
    }

    /// Counts and successful prefixes are shared only within this snapshot. A larger request
    /// can extend a cached prefix; a smaller one never causes another provider read.
    func arrayCount(_ element: AXUIElement, _ name: String) -> Int? {
        let key = ElementKey(element: element)
        if prefetched.insert(key).inserted { attributes[key] = batch(element) }
        if let injected = attributes[key]?[name] {
            switch injected {
            case .absent: return 0
            case .value(let value): return (value as? [AXUIElement])?.count
            }
        }
        if let count = arrayCounts[key]?[name] { return count }
        let (error, count) = readCount(element, name)
        if error == .attributeUnsupported || error == .noValue {
            arrayCounts[key, default: [:]][name] = 0
            return 0
        }
        guard error == .success, count >= 0 else { return nil }
        arrayCounts[key, default: [:]][name] = count
        return count
    }

    func array(_ element: AXUIElement, _ name: String, limit: Int) -> (values: [AXUIElement], truncated: Bool) {
        guard let total = arrayCount(element, name) else { return ([], true) }
        let requested = min(total, max(0, min(limit, Self.maximumArrayRead)))
        guard requested > 0 else { return ([], total > 0) }
        let key = ElementKey(element: element)
        if case .value(let raw)? = attributes[key]?[name], let values = raw as? [AXUIElement] {
            return (Array(values.prefix(requested)), total > requested)
        }
        if let values = arrays[key]?[name], values.count >= requested {
            return (Array(values.prefix(requested)), total > requested)
        }
        let (error, values) = readPage(element, name, requested)
        guard error == .success, let values else { return ([], true) }
        // A changing provider can answer a shorter or malformed page. Do not turn it into
        // evidence of a complete tree, and leave the next request able to retry.
        guard values.count == requested else { return (Array(values.prefix(requested)), true) }
        arrays[key, default: [:]][name] = values
        return (values, total > requested)
    }

    func actionNames(_ element: AXUIElement) -> [String]? {
        let key = ElementKey(element: element)
        if let cached = actions[key] { return cached }
        let (error, raw) = readActions(element)
        if error == .success { let names = raw ?? []; actions[key] = names; return names }
        return nil
    }

    func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        let key = ElementKey(element: element)
        if let cached = settable[key]?[name] { return cached }
        let (error, flag) = readSettable(element, name)
        let result = error == .success && flag
        if error == .success || error == .attributeUnsupported { settable[key, default: [:]][name] = result }
        return result
    }

    private static func readActionNames(_ element: AXUIElement) -> (AXError, [String]?) {
        var raw: CFArray?
        let error = AXUIElementCopyActionNames(element, &raw)
        return (error, raw as? [String])
    }

    private static func readIsSettable(_ element: AXUIElement, _ name: String) -> (AXError, Bool) {
        var flag = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, name as CFString, &flag)
        return (error, flag.boolValue)
    }

    static let names = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXHelp",
        "AXIdentifier", "AXSelected", "AXExpanded", "AXEnabled", "AXPlaceholderValue", "AXPlaceholder",
        "AXPosition", "AXSize", "AXURL",
    ]

    private static func readArrayCount(_ element: AXUIElement, _ name: String) -> (AXError, Int) {
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
        return (error, count)
    }

    private static func readArrayPage(_ element: AXUIElement, _ name: String, _ limit: Int) -> (AXError, [AXUIElement]?) {
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(element, name as CFString, 0, limit, &values)
        return (error, values as? [AXUIElement])
    }

    private static func readSingle(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    private static func readBatch(_ element: AXUIElement) -> [String: Attribute] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        guard error == .success, let raw = values as? [AnyObject] else { return [:] }
        return decodeBatch(raw, names: names)
    }

    static func decodeBatch(_ raw: [AnyObject], names: [String]) -> [String: Attribute] {
        guard raw.count == names.count else { return [:] }
        var result: [String: Attribute] = [:]
        for (name, value) in zip(names, raw) {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var failure = AXError.failure
                if AXValueGetValue(value as! AXValue, .axError, &failure), failure == .attributeUnsupported || failure == .noValue {
                    result[name] = .absent
                }
            } else if !(value is NSNull) { result[name] = .value(value) }
        }
        return result
    }
}
