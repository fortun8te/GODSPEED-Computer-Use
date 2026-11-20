import Foundation

/// Immutable settings for one synchronous request. Worker threads must
/// explicitly capture and reinstall the environment when they need it.
public enum RequestConfiguration {
    private static let key = "godspeed.request-configuration"

    public static var environment: [String: String] {
        Thread.current.threadDictionary[key] as? [String: String]
            ?? ProcessInfo.processInfo.environment
    }

    public static func withEnvironment<T>(_ environment: [String: String], _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = environment
        defer { dictionary[key] = previous }
        return try body()
    }
}
