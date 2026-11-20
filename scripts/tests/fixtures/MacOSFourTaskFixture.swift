import AppKit
import Foundation

@MainActor
final class FourTaskFixture: NSObject, NSApplicationDelegate {
    private let root: URL
    private var window: NSWindow!
    private let result = NSTextField(labelWithString: "Result: 0")
    private let document = NSTextView(frame: CGRect(x: 0, y: 0, width: 440, height: 110))
    private let folder = NSTextField(string: "")
    private let folderStatus = NSTextField(labelWithString: "Folder: none")
    private let selectionStatus = NSTextField(labelWithString: "Selected: none")
    private var input = ""
    private var multiplicand: Int?
    private var answer: Int?
    private var selected: String?
    private var activations = 0
    private var lastWrite: Data?
    private var heartbeat: Timer?

    init(root: URL) {
        self.root = root
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 40, y: 55, width: 550, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Godspeed Four Task Fixture"
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.addArrangedSubview(result)
        let keys = NSStackView()
        for label in ["Digit 2", "Digit 3", "Digit 4", "Digit 7", "Multiply", "Equals"] {
            keys.addArrangedSubview(NSButton(title: label, target: self, action: #selector(key(_:))))
        }
        content.addArrangedSubview(keys)

        document.setAccessibilityLabel("Benchmark document")
        document.setAccessibilityIdentifier("bench-document")
        document.isRichText = false
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalToConstant: 440),
                                     scroll.heightAnchor.constraint(equalToConstant: 110)])
        content.addArrangedSubview(scroll)

        folder.setAccessibilityLabel("Folder name")
        folder.setAccessibilityIdentifier("bench-folder-name")
        folder.widthAnchor.constraint(equalToConstant: 225).isActive = true
        content.addArrangedSubview(NSStackView(views: [folder, NSButton(title: "Create folder", target: self, action: #selector(createFolder))]))
        content.addArrangedSubview(folderStatus)

        content.addArrangedSubview(NSStackView(views: ["other-file.txt", "target-file.txt"].map { name in
            NSButton(radioButtonWithTitle: name, target: self, action: #selector(selectFile(_:)))
        }))
        content.addArrangedSubview(selectionStatus)
        window.contentView = content
        window.makeFirstResponder(document)

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        window.orderBack(nil)
        publish()
        heartbeat = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(publish), userInfo: nil, repeats: true)
    }

    @objc private func key(_ sender: NSButton) {
        if sender.title == "Multiply" {
            multiplicand = Int(input)
            input = ""
        } else if sender.title == "Equals" {
            if let left = multiplicand, let right = Int(input) {
                let product = left.multipliedReportingOverflow(by: right)
                guard !product.overflow else { return }
                answer = product.partialValue
                result.stringValue = "Result: \(product.partialValue)"
            }
        } else if let digit = sender.title.last {
            input.append(digit)
        }
        publish()
    }

    @objc private func createFolder() {
        guard folder.stringValue == "Benchmark folder" else { return }
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder.stringValue), withIntermediateDirectories: false)
            folderStatus.stringValue = "Folder created"
            publish()
        } catch {
            folderStatus.stringValue = "Folder creation failed"
        }
    }

    @objc private func selectFile(_ sender: NSButton) {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(sender.title).path) else { return }
        selected = sender.title
        selectionStatus.stringValue = "Selected: \(sender.title)"
        publish()
    }

    @objc private func activated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { activations += 1 }
        publish()
    }

    @objc private func publish() {
        let value: [String: Any] = ["answer": answer as Any? ?? NSNull(), "document": document.string,
                                   "selected": selected as Any? ?? NSNull(), "activations": activations,
                                   "active": NSApp.isActive,
                                   "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data != lastWrite else { return }
        do {
            try data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
            lastWrite = data
        } catch { }
    }
}

@main
enum FourTaskBenchmarkApp {
    @MainActor static func main() {
        guard let path = ProcessInfo.processInfo.environment["GODSPEED_BENCH_FIXTURE_ROOT"] else { return }
        let app = NSApplication.shared
        let delegate = FourTaskFixture(root: URL(fileURLWithPath: path, isDirectory: true))
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
