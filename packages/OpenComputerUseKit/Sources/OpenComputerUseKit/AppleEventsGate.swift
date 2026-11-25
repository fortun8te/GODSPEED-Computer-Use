import AppKit
import CoreServices
import Foundation

/// Whether GODSPEED may send Apple Events to an app right now, without ever blocking on the macOS consent
/// prompt. Outside background-only mode the first use may ask once; pending consent uses the
/// non-scripted path instead of waiting. Background-only requests never trigger the prompt.
enum AppleEventsGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: Set<String> = []

    static func allowed(bundle: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        if status == noErr { return true }
        if status == OSStatus(errAEEventWouldRequireUserConsent), !backgroundOnlyMode() {
            let first = lock.withLock { asked.insert(bundle).inserted }
            if first {
                // Ask once, off this thread: the answer applies to later calls.
                Thread.detachNewThread {
                    let promptTarget = NSAppleEventDescriptor(bundleIdentifier: bundle)
                    guard let promptDescriptor = promptTarget.aeDesc else { return }
                    _ = AEDeterminePermissionToAutomateTarget(promptDescriptor, typeWildCard, typeWildCard, true)
                }
            }
        }
        return false
    }

    /// Read-only convenience. Mutating callers use `send` so a failure cannot
    /// silently fall through into a second action.
    static func run(_ source: String, bundle: String, limit: TimeInterval = 7) -> NSAppleEventDescriptor? {
        try? send(source, bundle: bundle, limit: limit)
    }

    /// Nil means the permission gate stopped the script before sending. A failure after dispatch
    /// must reach the caller, since falling through to input could repeat the same mutation.
    static func send(
        _ source: String, bundle: String, limit: TimeInterval = 7,
        permission: (String) -> Bool = { allowed(bundle: $0) },
        schedule: (@escaping @Sendable () -> Void) -> Void = { Thread.detachNewThread($0) },
        execute: @escaping @Sendable (String) throws -> NSAppleEventDescriptor = { try executeScript($0) }
    ) throws -> NSAppleEventDescriptor? {
        let operation = try LocalOperation<NSAppleEventDescriptor>(timeout: limit, action: "Apple Event")
        let permitted = permission(bundle)
        try operation.check()
        guard permitted else { return nil }
        let environment = RequestConfiguration.environment
        schedule {
            RequestConfiguration.withEnvironment(environment) {
                RequestCancellation.$current.withValue(operation.cancellation) {
                    BrowserCallBudget.withDeadline(operation.deadline) {
                        operation.perform {
                            // AppleScript accepts whole seconds. The outer wait
                            // still enforces subsecond deadlines and marks an
                            // in-flight timeout as uncertain delivery.
                            let seconds = max(1, Int(min(60, ceil(operation.remaining))))
                            return try execute("with timeout of \(seconds) seconds\n\(source)\nend timeout")
                        }
                    }
                }
            }
        }
        return try operation.wait()
    }

    private static func executeScript(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, let result else {
            throw ComputerUseError.stateUnavailable("The app did not confirm the Apple Event. Inspect it before retrying.")
        }
        return result
    }
}
