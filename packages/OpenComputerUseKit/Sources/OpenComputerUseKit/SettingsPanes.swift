import AppKit
import Foundation

/// System Settings panes by their sidebar names. Its sidebar is often unreadable or slow through accessibility
/// (the read stops with an error), so a click on a pane's name opens the pane by its link instead, without
/// bringing System Settings forward.
enum SettingsPanes {
    static let links: [String: String] = [
        "general": "com.apple.systempreferences.GeneralSettings",
        "about": "com.apple.SystemProfiler.AboutExtension",
        "software update": "com.apple.Software-Update-Settings.extension",
        "storage": "com.apple.settings.Storage",
        "date & time": "com.apple.Date-Time-Settings.extension",
        "login items": "com.apple.LoginItems-Settings.extension",
        "login items & extensions": "com.apple.LoginItems-Settings.extension",
        "desktop & dock": "com.apple.Desktop-Settings.extension",
        "wi-fi": "com.apple.wifi-settings-extension",
        "bluetooth": "com.apple.BluetoothSettings",
        "network": "com.apple.Network-Settings.extension",
        "notifications": "com.apple.Notifications-Settings.extension",
        "sound": "com.apple.Sound-Settings.extension",
        "focus": "com.apple.Focus-Settings.extension",
        "screen time": "com.apple.Screen-Time-Settings.extension",
        "appearance": "com.apple.Appearance-Settings.extension",
        "accessibility": "com.apple.Accessibility-Settings.extension",
        "control center": "com.apple.ControlCenter-Settings.extension",
        "siri": "com.apple.Siri-Settings.extension",
        "spotlight": "com.apple.Spotlight-Settings.extension",
        "privacy & security": "com.apple.settings.PrivacySecurity.extension",
        "displays": "com.apple.Displays-Settings.extension",
        "wallpaper": "com.apple.Wallpaper-Settings.extension",
        "battery": "com.apple.Battery-Settings.extension",
        "lock screen": "com.apple.Lock-Screen-Settings.extension",
        "users & groups": "com.apple.Users-Groups-Settings.extension",
        "keyboard": "com.apple.Keyboard-Settings.extension",
        "trackpad": "com.apple.Trackpad-Settings.extension",
        "mouse": "com.apple.Mouse-Settings.extension",
        "printers & scanners": "com.apple.Print-Scanner-Settings.extension",
    ]

    static func isSettings(_ app: String) -> Bool {
        let a = app.lowercased()
        return a == "system settings" || a == "com.apple.systempreferences" || a == "system preferences"
    }

    /// The pane a call names, in whichever argument the model put it (a label, a search text, a menu item).
    static func paneName(in arguments: [String: Any]) -> String? {
        for key in ["label", "pane", "text", "value", "item", "path", "name"] {
            guard let raw = arguments[key] as? String else { continue }
            let last = raw.components(separatedBy: ">").last ?? raw
            let name = last.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " and ", with: " & ")
            if links[name] != nil { return name }
        }
        return nil
    }

    /// Opens the pane named `label`; true when the name is a known pane and the link was handed to macOS.
    static func open(label: String) throws -> Bool {
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " and ", with: " & ")
        guard let id = links[key], let url = URL(string: "x-apple.systempreferences:\(id)") else { return false }
        try SmartSteps.openWorkspace { complete in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in complete(error) }
        }
        Thread.sleep(forTimeInterval: 0.6)
        return true
    }
}
