import CoreGraphics
import Foundation

/// Background-only work may share the desktop with a person, but must yield
/// mutations that overlap the person's current app/window. This is a dispatch
/// admission check, not an exclusive lease over subsequent human input.
enum SharedWorkspace {
    struct Observation {
        var secondsSinceUserInput: () -> TimeInterval
        var idleThreshold: () -> TimeInterval
        var targetPID: (String) -> pid_t?
        var foregroundPID: () throws -> pid_t
        var focusedWindowID: (pid_t) -> CGWindowID?

        static var system: Observation {
            Observation(
                secondsSinceUserInput: FocusBorrowController.secondsSinceUserInput,
                idleThreshold: { FocusBorrowController.userIdleNeeded },
                targetPID: { (try? AppDiscovery.resolveRunning($0))?.pid },
                foregroundPID: ForegroundApplication.pid,
                focusedWindowID: { UserKeyWindow.focusedWindowID(pid: $0, spi: .shared) }
            )
        }
    }

    private static let mutatingTools: Set<String> = [
        "click", "hover", "perform_secondary_action", "scroll", "scroll_into_view", "drag", "gesture",
        "type_text", "press_key", "press_menu", "set_value", "select_text", "save_as", "open",
    ]

    static func guards(tool: String, arguments: [String: Any], backgroundOnly: Bool) -> Bool {
        guard backgroundOnly, mutatingTools.contains(tool) else { return false }
        // Copy reads the selection into Godspeed's private clipboard. Cut and
        // paste still mutate the app and therefore use the ordinary guard.
        if tool == "press_key", let key = arguments["key"] as? String,
           PrivateClipboard.Action(key: key) == .copy { return false }
        if tool == "open", case .url = SmartSteps.openPlan(path: arguments["path"] as? String,
            url: arguments["url"] as? String, app: arguments["app"] as? String, home: NSHomeDirectory()) {
            return false // Browser dispatch has its own tab identity.
        }
        return true
    }

    static func requireAvailable(tool: String, arguments: [String: Any], backgroundOnly: Bool,
                                 pinnedWindowID: CGWindowID?, observation: Observation = .system) throws {
        guard guards(tool: tool, arguments: arguments, backgroundOnly: backgroundOnly) else { return }
        let idle = observation.secondsSinceUserInput()
        if idle >= observation.idleThreshold() { return }
        guard let app = arguments["app"] as? String, !app.isEmpty,
              let target = observation.targetPID(app) else {
            // Leave unresolved/missing app handling to the existing dispatcher.
            // This also avoids treating headless fixture state as a live app.
            return
        }
        let front: pid_t
        do { front = try observation.foregroundPID() }
        catch { throw refusal(unknown: true) }
        guard front > 0 else { throw refusal(unknown: true) }
        guard front == target else { return }

        // Only an enforced native window pin/ref can establish a different
        // destination. An app-wide command or cached label is not a window pin.
        if ArgumentNormalizer.windowBoundTools.contains(tool), let pin = pinnedWindowID, pin != 0,
           let focused = observation.focusedWindowID(target), focused != 0, focused != pin {
            // The AX window read can yield. Do not use a result from an app
            // that stopped being the foreground owner during that read.
            do {
                let current = try observation.foregroundPID()
                guard current > 0 else { throw refusal(unknown: true) }
                if current != target { return }
                if let latest = observation.focusedWindowID(target), latest != 0, latest != pin { return }
            } catch { throw refusal(unknown: true) }
        }
        throw refusal(unknown: false)
    }

    private static func refusal(unknown: Bool) -> ComputerUseError {
        .backgroundUnsupported(unknown
            ? "Nothing was sent: the user is active and the current foreground owner could not be confirmed. Continue unrelated background work or retry after the user pauses."
            : "Nothing was sent: the user is active in the target app or window. Continue work in a different app or an explicitly bound different window, or retry after the user pauses.")
    }
}
