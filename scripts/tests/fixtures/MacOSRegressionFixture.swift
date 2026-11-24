import AppKit
import Foundation

@MainActor
final class RegressionFixture: NSObject, NSApplicationDelegate {
    let stateURL: URL
    let generation: Int
    var events: [String]
    var windows: [NSWindow] = []
    var ready = false
    var moved = false

    init(root: URL, generation: Int) {
        stateURL = root.appendingPathComponent("state.json")
        self.generation = generation
        let state = (try? Data(contentsOf: stateURL)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        events = state?["events"] as? [String] ?? []
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = makeWindow(generation == 1 ? "Original" : "Relaunched")
        window.orderBack(nil)
        ready = generation == 2
        publishWhenWindowIsRegistered()
    }

    private func publishWhenWindowIsRegistered() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        let registered = NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier == pid && $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.isFinishedLaunching
        }
        if registered && entries?.contains(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }) == true {
            publish()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.publishWhenWindowIsRegistered()
            }
        }
    }

    private func makeWindow(_ name: String) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 45, y: 80, width: 520, height: 220),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = name
        window.tabbingMode = .preferred
        windows.append(window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let row = NSStackView()
        for index in 1...8 {
            let button = NSButton(title: "Mark \(index)", target: self, action: #selector(mark(_:)))
            row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
        if name == "Original" {
            stack.addArrangedSubview(NSButton(title: "Load fixture", target: self, action: #selector(load(_:))))
            stack.addArrangedSubview(NSButton(title: "Open fixture tab", target: self, action: #selector(openTab)))
        } else if name == "New fixture tab" {
            stack.addArrangedSubview(NSButton(title: "Move fixture window", target: self, action: #selector(moveWindow)))
        }
        window.contentView = stack
        return window
    }

    @objc private func load(_ sender: NSButton) {
        guard let stack = sender.window?.contentView as? NSStackView else { return }
        events.append("Load fixture")
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.ready = true
            stack.insertArrangedSubview(NSTextField(labelWithString: "Fixture ready"), at: 0)
            self.publish()
        }
    }

    @objc private func mark(_ sender: NSButton) {
        guard let window = sender.window, let stack = window.contentView as? NSStackView else { return }
        let prefix = ready ? window.title : "Before ready"
        events.append("\(prefix)/\(sender.title)")
        publish()
        let label = "Recorded \(sender.title)"
        if !stack.arrangedSubviews.contains(where: { ($0 as? NSTextField)?.stringValue == label }) {
            stack.addArrangedSubview(NSTextField(labelWithString: label))
        }
    }

    @objc private func openTab() {
        guard let original = windows.first else { return }
        events.append("Open fixture tab")
        let tab = makeWindow("New fixture tab")
        original.addTabbedWindow(tab, ordered: .above)
        original.tabGroup?.selectedWindow = tab
        publish()
    }

    @objc private func moveWindow() {
        guard let tab = windows.last else { return }
        events.append("Move fixture window")
        let before = tab.frame.origin
        tab.setFrameOrigin(NSPoint(x: tab.frame.minX + 80, y: tab.frame.minY + 35))
        moved = tab.frame.origin != before
        tab.title = "Moved fixture tab"
        publish()
    }

    private func publish() {
        let state: [String: Any] = [
            "generation": generation, "ready": ready, "events": events,
            "windows": windows.map { $0.title },
            "tabCount": windows.first?.tabGroup?.windows.count ?? 0,
            "moved": moved, "pid": ProcessInfo.processInfo.processIdentifier
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Regression fixture could not write state: %@", String(describing: error))
        }
    }
}

@main
enum RegressionFixtureApp {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3, let generation = Int(CommandLine.arguments[2]) else { return }
        let app = NSApplication.shared
        let fixture = RegressionFixture(root: URL(fileURLWithPath: CommandLine.arguments[1]), generation: generation)
        app.setActivationPolicy(.accessory)
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}
