import Foundation

/// The app agent installs this while a request owns desktop admission.
public enum RequestInferenceAdmission {
    @TaskLocal public static var withoutExclusive: (@Sendable (() -> Data?) -> Data?)?
}
