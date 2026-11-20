import Foundation

/// The persisted state of the adaptive modules: menu shortcuts, failure recovery hints, route choices and the settle
/// wait. Production files live in ~/.godspeed. Under XCTest they live in a per-process temp directory, so no test
/// reads or writes the real files. Every load is forgiving (a missing or damaged file starts empty) and every save is
/// best-effort: learning must never fail a tool call.
final class AdaptiveLearning: @unchecked Sendable {
    static let directory: URL = {
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("godspeed-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".godspeed", isDirectory: true)
    }()

    static let shared = AdaptiveLearning(directory: directory)

    /// Read-only lookups use `"query"`; the arms are the two ways to answer a query. The first is the default.
    static let queryArms = ["targeted_query", "full_tree_read"]
    /// Settle waits the tuner may pick, within the range `settle_ms` already accepts (1 to 5000).
    static let settleBounds = ParameterBounds(min: 500, max: 5000, defaultValue: LeanDefaults.batchSettleMs)

    let directory: URL
    let shortcuts = ShortcutCache()
    let failures = FailureSignatureStore()
    let routes = RouteBandit()
    let settle = ParameterTuner(bounds: AdaptiveLearning.settleBounds)
    private let saveLock = NSLock()

    init(directory: URL) {
        self.directory = directory
        try? shortcuts.load(from: file("shortcuts.json"))
        try? failures.load(from: file("failure-signatures.json"))
        if let data = try? Data(contentsOf: file("routes.json")) { try? routes.restore(data) }
        if let data = try? Data(contentsOf: file("settle.json")) { try? settle.restore(data) }
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func saveShortcuts() { saveLock.lock(); defer { saveLock.unlock() }; try? shortcuts.save(to: file("shortcuts.json")) }
    func saveFailures() { saveLock.lock(); defer { saveLock.unlock() }; try? failures.save(to: file("failure-signatures.json")) }
    func saveRoutes() { saveLock.lock(); defer { saveLock.unlock() }; writeJSON(try? routes.jsonData(), "routes.json") }
    func saveSettle() { saveLock.lock(); defer { saveLock.unlock() }; writeJSON(try? settle.jsonData(), "settle.json") }

    private func writeJSON(_ data: Data?, _ name: String) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(name), options: .atomic)
    }

    /// The shortcut cache key for a running app: its bundle id plus its version, so an update starts clean.
    static func appKey(for app: RunningAppDescriptor) -> String {
        let bundle = app.runningApplication.bundleURL.flatMap { Bundle(url: $0) }
        let short = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = bundle?.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return ShortcutCache.appKey(bundleID: app.bundleIdentifier ?? app.name, version: "\(short)+\(build)")
    }

    /// Menu titles compare without case, the ellipsis or trailing dots ("Save As…" is "Save As").
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        func clean(_ t: String) -> String {
            t.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean(a) == clean(b)
    }
}
