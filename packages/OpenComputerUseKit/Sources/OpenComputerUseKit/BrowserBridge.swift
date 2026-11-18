import Foundation

/// Bridge to Open Browser Use (`obu mcp`, https://github.com/iFurySt/open-browser-use) for what the
/// accessibility path cannot do well in a browser: open or go to a URL, list and claim tabs, wait for a
/// page load, read the page URL and title, and answer a file chooser. Clicking and typing inside a page
/// stay on the accessibility path, with the same labels as any app, so a model learns one set of verbs.
///
/// `obu mcp` is started on first use and kept for the life of this process. When no `obu` binary is
/// found (or `OPEN_COMPUTER_USE_BROWSER=0`), the `browser` tool is not listed at all.
///
/// Sessions: every GODSPEED process uses its own OBU session id (`godspeed-<pid>`, or
/// `OPEN_COMPUTER_USE_BROWSER_SESSION`), so two agents never share a tab group or close each other's
/// tabs. `obu mcp` answers one request at a time, so parallel page work uses extra "lanes": more
/// `obu mcp` children, each with its own session (`<session>-lane<N>`) and its own tabs.
final class BrowserBridge: @unchecked Sendable {
    static var baseSessionID: String {
        let value = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_BROWSER_SESSION"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false ? value : nil) ?? "godspeed-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// The bridge of the agent this thread works for (see `ClientScope`): each agent has its own Open Browser
    /// Use session, so its own tabs and its own current tab.
    static var shared: BrowserBridge { scoped.current }
    private static let scoped = ScopedStore<BrowserBridge>(
        make: { scope in BrowserBridge(sessionID: sessionID(for: scope)) },
        drop: { $0.shutdown() }
    )

    static func endClientTurn() { scoped.existing?.turnEnded() }

    /// At most this many pages are loaded at once by parallel actions.
    static let maxLanes = 3

    private static let lanes = ScopedStore<[BrowserBridge]>(
        make: { scope in
            (1...maxLanes).map { BrowserBridge(sessionID: sessionID(for: scope, lane: $0)) }
        },
        drop: { bridges in bridges.forEach { $0.shutdown() } }
    )

    /// These bridges start their helpers lazily and expire with the client's scope.
    static func lane(_ index: Int) -> BrowserBridge { lanes.current[index] }

    private static func sessionID(for scope: String, lane: Int? = nil) -> String {
        if let lane { return "\(baseSessionID)-lane\(lane)-\(scope)" }
        return scope == "main" ? baseSessionID : "\(baseSessionID)-client-\(scope)"
    }

    let sessionID: String
    private let launchEnvironment: [String: String]

    init(sessionID: String, launchEnvironment: [String: String] = GodspeedSettings.environment) {
        self.sessionID = sessionID
        self.launchEnvironment = launchEnvironment
    }

    private let tabLock = NSLock()
    private var preferredTab: Int?

    /// The tab the browser tool works in when a call names none: the one `open` made, `use_tab` took, or a
    /// click's new tab. Nil leaves the choice to Open Browser Use.
    var currentTab: Int? {
        get {
            tabLock.lock()
            defer { tabLock.unlock() }
            return preferredTab
        }
        set {
            tabLock.lock()
            preferredTab = newValue
            tabLock.unlock()
        }
    }

    /// Ids of the session's tabs, or nil when Open Browser Use cannot list them.
    func sessionTabIDs() -> [Int]? {
        guard let reply = try? callTool("tabs", arguments: [:], timeout: 10), !reply.isError else { return nil }
        return BrowserReply.tabIDs(in: reply.text)
    }

    static let notInstalledMessage =
        "Open Browser Use is not installed, so the browser tool is unavailable. Click the address bar and type the URL instead, "
        + "or install it with `npm i -g open-browser-use && open-browser-use setup`."

    /// The `obu` executable: `OPEN_COMPUTER_USE_OBU_BIN`, else the copy bundled in GODSPEED.app
    /// (Contents/Helpers/obu), else the first `obu` / `open-browser-use` on PATH or in the usual folders.
    static func executablePath(environment: [String: String]) -> String? {
        let switchValue = environment["OPEN_COMPUTER_USE_BROWSER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let switchValue, ["0", "false", "no", "off"].contains(switchValue) { return nil }
        let files = FileManager.default
        if let explicit = environment["OPEN_COMPUTER_USE_OBU_BIN"], !explicit.isEmpty {
            return files.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/obu").path
        if files.isExecutableFile(atPath: bundled) { return bundled }
        for directory in searchDirectories(environment: environment) {
            for name in ["obu", "open-browser-use"] {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if files.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static var isAvailable: Bool { executablePath(environment: GodspeedSettings.environment) != nil }

    /// The app the accessibility path reads after a browser step. Default Google Chrome.
    static var browserApp: String {
        let value = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_BROWSER_APP"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false ? value : nil) ?? "Google Chrome"
    }

    private static func searchDirectories(environment: [String: String]) -> [String] {
        let home = NSHomeDirectory()
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return fromPath + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
    }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    /// Responses of the current child only; a new child gets a new buffer, so a late end-of-file
    /// from a child that already exited can never close the buffer the restarted child uses.
    private var responses = BrowserBridgeResponses()

    // MARK: Idle housekeeping
    //
    // Chrome shows "started debugging this browser" while a tab is attached. After `detachAfter` seconds
    // without a browser call, GODSPEED tells OBU the turn ended, which detaches every tab of this session
    // (the bar goes away; the agent's tab stays open and `currentTab` keeps the next call on it). After
    // `stopAfter` seconds the `obu mcp` child itself is stopped; the next call starts it again.
    static let detachAfter: TimeInterval = 20
    static let stopAfter: TimeInterval = 600
    private var lastUse = Date.distantPast
    private var detached = true
    private static let housekeeping = DispatchQueue(label: "godspeed.browser.idle", qos: .utility)

    private func scheduleIdleWork(stamp: Date) {
        Self.housekeeping.asyncAfter(deadline: .now() + Self.detachAfter + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.lastUse == stamp, !self.detached, self.process?.isRunning == true else { return }
            _ = try? self.request(method: "tools/call", params: ["name": "turn_ended", "arguments": [String: Any]()], timeout: 2)
            self.detached = true
        }
        Self.housekeeping.asyncAfter(deadline: .now() + Self.stopAfter + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.lastUse == stamp, let child = self.process, child.isRunning else { return }
            child.terminate()
            self.process = nil
            self.input = nil
        }
    }

    /// Calls one OBU tool and returns its text and error flag. One request at a time.
    func callTool(_ name: String, arguments: [String: Any], timeout: TimeInterval) throws -> (text: String, isError: Bool) {
        lock.lock()
        defer {
            let stamp = Date()
            lastUse = stamp
            detached = false
            lock.unlock()
            scheduleIdleWork(stamp: stamp)
        }
        try startIfNeeded()
        let result = try request(method: "tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        let content = result["content"] as? [[String: Any]] ?? []
        var text = content
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        let isError = (result["isError"] as? Bool) ?? false
        if isError, ["socket", "no active", "not connected", "native host", "extension"].contains(where: { text.lowercased().contains($0) }) {
            text += "\nChrome is not connected to GODSPEED's browser helper yet: run obu setup once and add the Open Browser Use Chrome extension."
        }
        return (text, isError)
    }

    /// Stops the `obu mcp` child. The session's tabs stay open in Chrome.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminate()
        process = nil
        input = nil
    }

    /// Tells OBU the turn ended, if it is running. Never starts it.
    func turnEnded() {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning == true, !detached else { return }
        _ = try? request(method: "tools/call", params: ["name": "turn_ended", "arguments": [String: Any]()], timeout: 2)
        detached = true
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        guard let path = Self.executablePath(environment: launchEnvironment) else {
            throw ComputerUseError.message(Self.notInstalledMessage)
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        var arguments = ["mcp", "--session-id", sessionID]
        if let profile = launchEnvironment["OPEN_COMPUTER_USE_BROWSER_PROFILE"], !profile.isEmpty {
            arguments += ["--profile", profile]
        }
        child.arguments = arguments
        // An app bundle's PATH lacks Homebrew; an npm-installed `obu` needs `node` from there.
        var environment = launchEnvironment
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"] + [environment["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
        child.environment = environment

        let toChild = Pipe()
        let fromChild = Pipe()
        // Writing to a child that already exited must return an error, not raise SIGPIPE and end GODSPEED.
        _ = fcntl(toChild.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.standardInput = toChild
        child.standardOutput = fromChild
        child.standardError = FileHandle.nullDevice

        responses = BrowserBridgeResponses()
        let buffer = responses
        fromChild.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                buffer.close()
                return
            }
            buffer.append(data)
        }

        try child.run()
        process = child
        input = toChild.fileHandleForWriting
        nextID = 1

        do {
            _ = try request(
                method: "initialize",
                params: [
                    "protocolVersion": "2025-03-26",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "godspeed", "version": openComputerUseVersion],
                ],
                timeout: 10
            )
            try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        } catch {
            // Never keep a child that did not finish its handshake: the next call starts a fresh one.
            child.terminate()
            process = nil
            input = nil
            throw error
        }
    }

    private func request(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let wait = min(timeout, BrowserCallBudget.activeRemaining ?? timeout)
        guard wait > 0 else { throw ComputerUseError.message("The browser request ran out of time.") }
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let message = responses.wait(for: id, timeout: wait) else {
            if process?.isRunning != true { process = nil }
            throw ComputerUseError.message("Open Browser Use did not answer \(method) within \(Int(wait.rounded())) s.")
        }
        if let error = message["error"] as? [String: Any] {
            throw ComputerUseError.message("Open Browser Use: \(error["message"] as? String ?? "request failed")")
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else {
            throw ComputerUseError.message("Open Browser Use is not running.")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            // Stop the broken child too, or it would stay alive without a way to reach it.
            process?.terminate()
            process = nil
            self.input = nil
            throw ComputerUseError.message("Open Browser Use stopped; try again to restart it.")
        }
    }
}

/// Results of parallel page loads, one slot per URL.
private final class PeekResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(count: Int) {
        values = Array(repeating: "not loaded", count: count)
    }

    func set(_ index: Int, _ value: String) {
        lock.lock(); values[index] = value; lock.unlock()
    }

    func get(_ index: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return values[index]
    }
}

/// Newline-delimited JSON-RPC responses from `obu mcp`, keyed by request id.
private final class BrowserBridgeResponses: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = Data()
    private var messages: [Int: [String: Any]] = [:]
    private var closed = false

    func reset() {
        condition.lock()
        pending = Data()
        messages = [:]
        closed = false
        condition.unlock()
    }

    func append(_ data: Data) {
        condition.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let id = (object["id"] as? NSNumber)?.intValue {
                messages[id] = object
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(for id: Int, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while messages[id] == nil, !closed {
            if !condition.wait(until: deadline) { break }
        }
        return messages.removeValue(forKey: id)
    }
}

extension ComputerUseToolDispatcher {
    /// The `browser` tool: a handful of OBU abilities behind one verb, so a model sees one extra tool.
    func runBrowser(arguments: [String: Any]) throws -> ToolCallResult {
        try BrowserCallBudget.withDeadline(BrowserCallBudget.deadline()) {
            try runBrowserAction(arguments: arguments)
        }
    }

    private func runBrowserAction(arguments: [String: Any]) throws -> ToolCallResult {
        guard BrowserBridge.isAvailable else {
            throw ComputerUseError.message(BrowserBridge.notInstalledMessage)
        }
        let bridge = BrowserBridge.shared
        let action = ((arguments["action"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // Actions that name no tab; every other action works in the explicit tab, else the current one.
        let tabless: Set<String> = ["open", "new_tab", "open_tab", "tabs", "list", "peek", "read_many", "open_many"]
        var tab: [String: Any] = [:]
        let explicit = Self.browserTabID(arguments["tab_id"])
        if let explicit {
            tab["tab_id"] = explicit
        } else if !tabless.contains(action), let current = bridge.currentTab {
            tab["tab_id"] = current
        }
        let implicit = explicit == nil && tab["tab_id"] != nil
        do {
            return try browserAction(action, arguments: arguments, bridge: bridge, tab: tab)
        } catch {
            // The tab we picked for the model is gone: forget it, so the next call falls back to Open Browser Use's own choice.
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            if implicit, message.hasPrefix("browser: lost the link") || message.hasPrefix("browser: that tab is closed") {
                bridge.currentTab = nil
            }
            throw error
        }
    }

    private func browserAction(
        _ action: String, arguments: [String: Any], bridge: BrowserBridge, tab: [String: Any]
    ) throws -> ToolCallResult {
        let page = BrowserPage(bridge: bridge, tab: tab)
        let label = Self.browserLabel(arguments)
        let index = Self.browserTabID(arguments["index"] ?? arguments["element_index"])

        func call(_ name: String, _ extra: [String: Any] = [:], timeout: TimeInterval = 20) throws -> (text: String, isError: Bool) {
            try bridge.callTool(name, arguments: tab.merging(extra) { _, new in new }, timeout: timeout)
        }
        func finish(_ parts: [(text: String, isError: Bool)]) -> ToolCallResult {
            let text = parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            return .text(BatchTool.clipped(text.isEmpty ? "ok" : text, limit: 3_000), isError: parts.contains { $0.isError })
        }
        func target() throws -> BrowserNode {
            try page.resolve(label: label, index: index)
        }

        switch action {
        case "read", "state", "look", "snapshot":
            let find = (arguments["find"] ?? arguments["query"] ?? arguments["filter"]) as? String
            return .text(try page.read(find: find, full: Self.browserFlag(arguments["full"])))

        case "screenshot", "see", "look_at":
            let image = try page.screenshot()
            let place = try? page.location()
            return ToolCallResult(content: [
                .text("Screenshot of \(place.map { $0.title.isEmpty ? $0.href : "\($0.title) — \($0.href)" } ?? "the page") (visible part)."),
                .screenshotImage(image),
            ])

        case "click", "press", "tap":
            let node = try target()
            return .text(try clickAndWatch(node, page: page, bridge: bridge))

        case "drag":
            guard tab["tab_id"] != nil else {
                throw ComputerUseError.invalidArguments("browser drag needs an open or explicitly selected tab")
            }
            let destinationLabel = arguments["to_label"] as? String
            let destinationIndex = Self.browserTabID(arguments["to_index"])
            guard destinationLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || destinationIndex != nil else {
                throw ComputerUseError.invalidArguments("browser drag needs to_label or to_index for the destination")
            }
            let source = try target()
            let destination = try page.resolve(label: destinationLabel, index: destinationIndex)
            try page.drag(from: source, to: destination)
            return .text("Drag delivered. Read the tab to verify the drop.")

        case "type", "type_text", "fill":
            guard let text = arguments["text"] as? String else {
                throw ComputerUseError.invalidArguments("browser type needs text (and a label or index for the field, or it types into the focused field)")
            }
            let replace = Self.browserFlag(arguments["replace"])
            var node: BrowserNode?
            var targetName = "the focused field"
            if label != nil || index != nil {
                let found = try target()
                node = found
                targetName = "\(found.role) \"\(found.name)\""
            }
            let outcome = try page.type(text, replace: replace, into: node)
            let verb = replace && text.isEmpty ? "cleared" : "typed into"
            return .text(outcome.reply(verb: verb, target: targetName))

        case "key", "press_key":
            guard let key = arguments["key"] as? String, !key.isEmpty else {
                throw ComputerUseError.invalidArguments("browser key needs key, e.g. Enter, Tab, Escape, ArrowDown, or a combination such as Cmd+A")
            }
            let change = try page.pressKeyAndWatch(key)
            return .text("pressed \(key); \(change.line)")

        case "hover":
            let node = try target()
            try page.hover(node)
            return .text("hovered \(node.role) \"\(node.name)\"")

        case "select", "choose":
            let node = try target()
            let option = [arguments["option"], arguments["value"], arguments["text"]]
                .compactMap { $0 as? String }
                .first { !$0.isEmpty }
            guard let option else {
                throw ComputerUseError.invalidArguments(
                    "browser select needs option, the option's text: {\"action\": \"select\", \"label\": \"Country\", \"option\": \"Canada\"}"
                )
            }
            return .text(try page.select(node, option: option))

        case "check", "uncheck", "tick", "untick":
            let node = try target()
            let outcome = try page.setChecked(node, desired: action == "check" || action == "tick")
            return .text("\(outcome); \(page.settle().line)")

        case "scroll":
            let raw = (arguments["direction"] as? String) ?? "down"
            guard let direction = BrowserRules.scrollDirection(raw) else {
                throw ComputerUseError.invalidArguments("browser scroll direction must be up, down, left, right, top or bottom")
            }
            let amount = Self.browserTabID(arguments["amount"])
            if label != nil || index != nil {
                return .text(try page.scrollElement(try target(), direction: direction, amount: amount))
            }
            return .text(try page.scrollPage(direction: direction, amount: amount))

        case "back", "forward", "reload":
            return .text(try page.history(action))

        case "wait_for":
            let text = (arguments["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard text != nil || label != nil else {
                throw ComputerUseError.invalidArguments("browser wait_for needs text (words that should appear) or a label (an element that should appear)")
            }
            let seconds = Swift.min(30, Swift.max(1, Self.browserTabID(arguments["timeout"]) ?? 10))
            let what = "\"\(text ?? label ?? "")\""
            guard page.waitFor(text: text, label: text == nil ? label : nil, timeout: TimeInterval(seconds)) else {
                throw ComputerUseError.message("browser: \(what) did not appear within \(seconds) s; browser read to see what is on the page")
            }
            return .text("found \(what)")

        case "peek", "read_many", "open_many":
            let urls = ((arguments["urls"] as? [String]) ?? []).compactMap { Self.browserURL($0) }
            guard !urls.isEmpty else {
                throw ComputerUseError.invalidArguments("browser peek needs urls: [\"a.com\", \"b.com\"] (up to 6)")
            }
            return .text(Self.peekPages(Array(urls.prefix(6))))

        case "open", "new_tab", "open_tab":
            let url = Self.browserURL(arguments["url"])
            let opened = try bridge.callTool("open_tab", arguments: url.map { ["url": $0] } ?? [:], timeout: max(2, min(20, BrowserCallBudget.remaining() - 3)))
            guard !opened.isError else { return finish([opened]) }
            let newID = BrowserReply.openedTabID(in: opened.text)
            if let newID { bridge.currentTab = newID }
            BrowserPageMemory.shared.forgetTab(session: bridge.sessionID, tab: -1)
            guard let url else {
                return .text("opened a blank tab" + (newID.map { " (id \($0))" } ?? ""))
            }
            if let error = BrowserReply.navigationError(in: opened.text) {
                throw ComputerUseError.message("browser: could not load \(url): \(error). Check the address")
            }
            let fresh = BrowserPage(bridge: bridge, tab: newID.map { ["tab_id": $0] } ?? [:])
            fresh.waitLoad(changedFrom: nil, expect: url, timeout: 20)
            fresh.settle()
            fresh.prime()
            // The page comes with the reply, so the model needs no separate read before acting.
            if let read = try? fresh.read(find: nil, full: false) { return .text("opened. " + read) }
            return .text("opened \(fresh.title(try? fresh.location()))")

        case "go", "goto", "navigate", "visit":
            guard let url = Self.browserURL(arguments["url"]) else {
                throw ComputerUseError.invalidArguments("browser go needs a url")
            }
            let before = try? page.location()
            let moved = try call("navigate", ["url": url])
            let failure = BrowserReply.navigationError(in: moved.text)
            if moved.isError || failure != nil {
                let reason = failure ?? BatchTool.firstLine(moved.text)
                throw ComputerUseError.message("browser: could not load \(url): \(reason). Check the address, or browser tabs if this tab is gone")
            }
            page.waitLoad(changedFrom: before?.href, expect: url, timeout: 20)
            page.settle()
            page.prime()
            if let read = try? page.read(find: nil, full: false) { return .text("went there. " + read) }
            return .text("went to \(page.title(try? page.location()))")

        case "tabs", "list":
            let mine = try bridge.callTool("tabs", arguments: [:], timeout: 10)
            var lines = ["Tabs in this session (browser use_tab with tab_id):"]
            let own = BrowserReply.tabLines(in: mine.text, limit: 30)
            lines += own.isEmpty ? [mine.isError ? BatchTool.firstLine(mine.text) : "(none)"] : own
            if let theirs = try? bridge.callTool("user_tabs", arguments: [:], timeout: 10), !theirs.isError {
                let user = BrowserReply.tabLines(in: theirs.text, limit: 15)
                if !user.isEmpty {
                    lines.append("Your Chrome tabs (read only; use_tab can take one):")
                    lines += user
                }
            }
            return .text(BatchTool.clipped(lines.joined(separator: "\n"), limit: 3_000))

        case "use_tab", "claim", "claim_tab", "switch":
            // Only the id the model named: the current tab is not "claimed" by a call that named none.
            guard let id = Self.browserTabID(arguments["tab_id"]) else {
                throw ComputerUseError.invalidArguments("browser use_tab needs a tab_id from browser tabs")
            }
            let claimed = try call("claim_tab")
            guard !claimed.isError else { return finish([claimed]) }
            bridge.currentTab = id
            BrowserPageMemory.shared.forgetTab(session: bridge.sessionID, tab: id)
            return .text("now working in tab \(id) (\(page.title(try? page.location())))")

        case "wait", "wait_load":
            let seconds = Swift.min(30, Swift.max(1, Self.browserTabID(arguments["timeout"]) ?? 30))
            guard page.waitLoad(changedFrom: nil, timeout: TimeInterval(seconds)) else {
                throw ComputerUseError.message("browser: the page is still loading after \(seconds) s; browser wait again, or browser read it")
            }
            return .text("page is loaded: \(page.title(try? page.location()))")

        case "info", "page", "page_info":
            let raw = try page.evaluate("[location.href, document.title, document.body ? document.body.innerText.slice(0, 20000) : '']")
            let values = (raw as? [Any]) ?? []
            guard values.count == 3 else {
                throw ComputerUseError.message("browser: could not read the page; browser wait, then try again")
            }
            let text = (values[2] as? String) ?? ""
            return .text(BatchTool.clipped("\(page.title(BrowserLocation(href: values[0] as? String ?? "", title: values[1] as? String ?? "", readyState: "complete")))\n\(text)", limit: 3_000))

        case "upload", "files":
            let files = (arguments["files"] as? [String]) ?? ((arguments["file"] as? String).map { [$0] } ?? [])
            guard !files.isEmpty else {
                throw ComputerUseError.invalidArguments("browser upload needs files: [\"/path/to/file\"]. Click the page's upload button in the same batch first.")
            }
            let chooser = try call("wait_file_chooser", timeout: 15)
            guard !chooser.isError else { return finish([chooser]) }
            guard let chooserID = Self.fileChooserID(in: chooser.text) else {
                return .text("browser upload: no file dialog opened. Click the page's upload button in the same batch first.", isError: true)
            }
            return finish([try bridge.callTool("set_file_chooser_files", arguments: ["file_chooser_id": chooserID, "files": files], timeout: 15)])

        default:
            throw ComputerUseError.invalidArguments(
                "browser action must be one of: open, go, read, screenshot, click, drag, type, key, hover, select, check, uncheck, scroll, back, forward, reload, wait_for, tabs, use_tab, wait, info, upload, peek"
            )
        }
    }

    /// Clicks an element. A link is followed for a moment, so the reply says where it landed. A click that
    /// opens a new tab makes that tab the working tab, and the reply says so.
    private func clickAndWatch(_ node: BrowserNode, page: BrowserPage, bridge: BrowserBridge) throws -> String {
        // A link that opens a new tab is opened in the background instead of clicked: Chrome brings a tab that a
        // click opened to the front, over the user's work. If the background open fails, the click goes ahead.
        if node.role == "link", let link = page.linkTarget(node),
           let url = BrowserRules.newTabLinkURL(href: link.href, target: link.target),
           let opened = try? bridge.callTool("open_tab", arguments: ["url": url], timeout: 20), !opened.isError {
            let newID = BrowserReply.openedTabID(in: opened.text)
            if let newID { bridge.currentTab = newID }
            BrowserPageMemory.shared.forgetTab(session: bridge.sessionID, tab: newID ?? -1)
            BrowserPage(bridge: bridge, tab: newID.map { ["tab_id": $0] } ?? [:]).waitLoad(changedFrom: nil, expect: url, timeout: 20)
            return "opened \"\(node.name)\" in a new background tab" + (newID.map { " (id \($0))" } ?? "")
                + "; browser now works in that tab"
        }
        let mayOpenTab = ["link", "button", "menuitem"].contains(node.role)
        let tabsBefore = mayOpenTab ? bridge.sessionTabIDs() : nil
        // A link to another address is followed for a moment: the navigation starts a beat after the click.
        let linkAddress = node.role == "link" ? page.linkTarget(node)?.href : nil
        let hrefBefore = linkAddress.map { BrowserRules.leadsElsewhere(href: $0) } == true ? (try? page.location())?.href : nil
        let textBefore = page.visibleTextLines()
        try page.click(node)
        var message = "clicked \(node.role) \"\(node.name)\""
        if let hrefBefore, let place = page.followNavigation(from: hrefBefore) {
            message += "; \(BrowserChange.navigated(place.href).line)"
        } else {
            // One event-based wait, so the next step or read sees the result and not the old content.
            let change = page.settle()
            if change == .none, ["textbox", "searchbox", "combobox", "spinbutton"].contains(node.role) {
                message += "; focused"
            } else {
                message += "; \(change.line)"
            }
            // What appeared, so the model needs no read to see it (a tab's panel, a message, a result).
            if change != .none, let before = textBefore, let after = page.visibleTextLines() {
                let seen = Set(before)
                let added = after.filter { !seen.contains($0) }.prefix(5)
                if !added.isEmpty { message += "; now shows: " + added.map { String($0.prefix(120)) }.joined(separator: " | ") }
            }
        }
        if let tabsBefore, let after = bridge.sessionTabIDs(), let fresh = after.first(where: { !tabsBefore.contains($0) }) {
            bridge.currentTab = fresh
            BrowserPageMemory.shared.forgetTab(session: bridge.sessionID, tab: fresh)
            message += "; it opened a new tab (id \(fresh)), and browser now works in that tab"
        }
        return message
    }

    /// Loads each URL in a short-lived tab, reads it and closes it, up to `BrowserBridge.maxLanes` at once
    /// (each lane is its own `obu mcp` with its own session, so the loads really run side by side).
    /// Seconds after which a peek starts no further page (other agents wait while it runs).
    static let peekBudget: TimeInterval = 40

    static func peekPages(_ urls: [String]) -> String {
        let results = PeekResults(count: urls.count)
        let laneCount = min(BrowserBridge.maxLanes, urls.count)
        let deadline = BrowserCallBudget.deadline(after: peekBudget)
        // Worker threads do not inherit the caller's client scope: run each lane inside it, so its lane and
        // page memory are this agent's own.
        let scope = ClientScope.current
        let bridges = (0..<laneCount).map(BrowserBridge.lane)
        DispatchQueue.concurrentPerform(iterations: laneCount) { lane in
            ClientScope.withScope(scope) {
                BrowserCallBudget.withDeadline(deadline) {
                    let bridge = bridges[lane]
                    var index = lane
                    while index < urls.count {
                        results.set(index, BrowserCallBudget.remaining() > 4
                            ? peek(urls[index], bridge: bridge, deadline: deadline - 3)
                            : "not read: the other pages took too long; peek this one again")
                        index += laneCount
                    }
                }
            }
        }
        return urls.enumerated()
            .map { "== \($0.element) ==\n\(results.get($0.offset))" }
            .joined(separator: "\n\n")
    }

    private static func peek(_ url: String, bridge: BrowserBridge, deadline: TimeInterval) -> String {
        defer { _ = try? bridge.callTool("finalize_tabs", arguments: [:], timeout: 10) }
        do {
            return try BrowserCallBudget.withDeadline(deadline) {
                let opened = try bridge.callTool("open_tab", arguments: ["url": url], timeout: 15)
                if opened.isError { return "could not open: \(BatchTool.firstLine(opened.text))" }
                if let error = BrowserReply.navigationError(in: opened.text) { return "could not load: \(error)" }
                guard let tabID = BrowserReply.openedTabID(in: opened.text) else {
                    return "could not read: the browser did not identify the tab it opened"
                }
                let page = BrowserPage(bridge: bridge, tab: ["tab_id": tabID], remember: false)
                guard page.waitLoad(changedFrom: nil, expect: url, timeout: 10) else {
                    return "could not read: the page did not finish loading"
                }
                return BatchTool.clipped(try page.read(), limit: 2_500)
            }
        } catch {
            return "failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
    }

    static func browserLabel(_ arguments: [String: Any]) -> String? {
        if let label = arguments["label"] as? String, !label.isEmpty { return label }
        if let labels = arguments["labels"] as? [String], let first = labels.first, !first.isEmpty { return first }
        return nil
    }

    /// Accepts "example.com" as well as full URLs.
    static func browserURL(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.contains("://") || raw.hasPrefix("about:") || raw.hasPrefix("chrome:") || raw.hasPrefix("file:") { return raw }
        return "https://" + raw
    }

    static func browserTabID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// True/false from a JSON flag, or from the words "true", "yes" and "1".
    static func browserFlag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return ["true", "yes", "1"].contains(text.trimmingCharacters(in: .whitespaces).lowercased()) }
        return false
    }

    static func fileChooserID(in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // OBU replies with the whole JSON-RPC envelope, whose top-level `id` is the request id, so look
        // for the chooser id by name, searching inside `result` first.
        for key in ["file_chooser_id", "fileChooserId", "chooser_id", "chooserId"] {
            for scope in [object["result"] as Any, object as Any] {
                if let value = BrowserPage.find(key, in: scope) as? String { return value }
                if let value = BrowserPage.find(key, in: scope) as? NSNumber { return value.stringValue }
            }
        }
        if let result = object["result"] as? [String: Any] {
            if let value = result["id"] as? String { return value }
            if let value = result["id"] as? NSNumber { return value.stringValue }
        }
        return nil
    }
}
