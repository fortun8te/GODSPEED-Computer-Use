import Foundation

/// The app agent installs this while a request owns desktop admission.
public enum RequestInferenceAdmission {
    /// Runs the work with desktop admission released. Throws when the gate cannot be re-acquired.
    @TaskLocal public static var withoutExclusive: (@Sendable (() -> Data?) throws -> Data?)?
}
