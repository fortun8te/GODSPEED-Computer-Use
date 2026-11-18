import AppKit
import CoreServices
import Foundation

/// Whether GODSPEED may send Apple Events to an app right now, without ever blocking on the macOS consent
/// prompt. The first use of an app asks the user once, in the background; until they answer, callers fall
/// back to their non-scripted path instead of waiting (a waiting prompt held every other agent's calls).
enum AppleEventsGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: Set<String> = []

    static func allowed(bundle: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        if status == noErr { return true }
        if status == OSStatus(errAEEventWouldRequireUserConsent) {
            let first = lock.withLock { asked.insert(bundle).inserted }
            if first {
                // Ask once, off this thread: the answer applies to later calls.
                Thread.detachNewThread {
                    _ = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
                }
            }
        }
        return false
    }

    /// Runs AppleScript source only when allowed; nil otherwise or on error. A 6 s Apple Event timeout applies.
    static func run(_ source: String, bundle: String, limit: TimeInterval = 7) -> NSAppleEventDescriptor? {
        guard allowed(bundle: bundle) else { return nil }
        // The script runs on its own thread and is given up on after `limit`: an app showing a modal sheet
        // answered nothing for minutes, which held every other agent's calls.
        final class Box: @unchecked Sendable { var value: NSAppleEventDescriptor?; var failed = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let wrapped = "with timeout of \(Int(limit) - 1) seconds\n\(source)\nend timeout"
        Thread.detachNewThread {
            var error: NSDictionary?
            let result = NSAppleScript(source: wrapped)?.executeAndReturnError(&error)
            box.value = result
            box.failed = error != nil
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success, !box.failed else { return nil }
        return box.value
    }
}
