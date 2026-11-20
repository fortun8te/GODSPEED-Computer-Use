import Foundation

/// Runs a synchronous browser request with its own effective launch environment and authorization.
public func withBrowserRequestEnvironment<T>(
    _ environment: [String: String],
    validate: (@Sendable () throws -> Void)? = nil,
    _ body: () throws -> T
) rethrows -> T {
    try BrowserRequestContext.withContext(
        BrowserRequestContext(environment: GodspeedSettings.merged(environment), validate: validate), body
    )
}

/// Require an available desktop at each transport boundary of a serialized GUI request.
public func withBrowserDesktopValidation<T>(_ body: () throws -> T) rethrows -> T {
    try BrowserRequestContext.withDesktopValidation(body)
}

struct BrowserRequestContext: Sendable {
    let environment: [String: String]
    let validate: (@Sendable () throws -> Void)?

    private static let key = "godspeed.browser-request"

    static var current: Self? { Thread.current.threadDictionary[key] as? Self }
    static var environment: [String: String] { current?.environment ?? GodspeedSettings.environment }

    static func withContext<T>(_ context: Self?, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = context
        defer { dictionary[key] = previous }
        return try body()
    }

    static func validateCurrent() throws {
        try current?.validate?()
    }

    static func withDesktopValidation<T>(
        session: @escaping @Sendable () -> LockedUseSession = LockedUseSession.current,
        _ body: () throws -> T
    ) rethrows -> T {
        let existing = current
        return try withContext(.init(
            environment: existing?.environment ?? GodspeedSettings.environment,
            validate: existing?.validate ?? { try requireUsableComputerUseSession(session()) }
        ), body)
    }
}

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
        baseSessionID(environment: BrowserRequestContext.environment)
    }

    private static func baseSessionID(environment: [String: String]) -> String {
        let value = environment["OPEN_COMPUTER_USE_BROWSER_SESSION"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false ? value : nil) ?? "godspeed-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// The bridge of the agent this thread works for (see `ClientScope`): each agent has its own Open Browser
    /// Use session, so its own tabs and its own current tab.
    static var shared: BrowserBridge {
        guard let context = BrowserRequestContext.current else { return scoped.current }
        return configured.current.bridge(environment: context.environment)
    }
    private static let scoped = ScopedStore<BrowserBridge>(
        make: { scope in BrowserBridge(sessionID: sessionID(for: scope)) },
        drop: { $0.shutdown() }
    )

    static func endClientTurn() {
        if let context = BrowserRequestContext.current {
            configured.existing?.existingBridge(environment: context.environment)?.turnEnded()
        } else {
            scoped.existing?.turnEnded()
        }
    }

    private static let configured = ScopedStore<ConfiguredBridges>(
        make: { ConfiguredBridges(scope: $0) },
        drop: { $0.shutdown() }
    )

    private final class ConfiguredBridges: @unchecked Sendable {
        let scope: String
        private let lock = NSLock()
        private var identity: [String: String] = [:]
        private var bridges: [Int: BrowserBridge] = [:]

        init(scope: String) { self.scope = scope }

        private static func launchIdentity(_ environment: [String: String]) -> [String: String] {
            environment.filter { key, _ in
                ["PATH", "HOME", "OPEN_COMPUTER_USE_OBU_BIN", "OPEN_COMPUTER_USE_BROWSER_SESSION",
                 "OPEN_COMPUTER_USE_BROWSER_PROFILE"].contains(key) || key.hasPrefix("OBU_")
            }
        }

        func bridge(environment: [String: String], lane: Int? = nil) -> BrowserBridge {
            lock.lock()
            defer { lock.unlock() }
            let requestedIdentity = Self.launchIdentity(environment)
            if identity != requestedIdentity {
                // An older helper with the same session may still have idle work scheduled.
                // Stop it before starting a helper with the new launch settings.
                bridges.values.forEach { $0.shutdown() }
                bridges.removeAll()
                identity = requestedIdentity
            }
            let index = lane ?? 0
            if let bridge = bridges[index] { return bridge }
            let bridge = BrowserBridge(
                sessionID: sessionID(for: scope, lane: lane, base: baseSessionID(environment: environment)),
                launchEnvironment: environment, isPreview: lane != nil
            )
            bridges[index] = bridge
            return bridge
        }

        func existingBridge(environment: [String: String]) -> BrowserBridge? {
            lock.lock()
            defer { lock.unlock() }
            return identity == Self.launchIdentity(environment) ? bridges[0] : nil
        }

        func shutdown() {
            lock.lock()
            defer { lock.unlock() }
            bridges.values.forEach { $0.shutdown() }
            bridges.removeAll()
        }
    }

    /// At most this many pages are loaded at once by parallel actions.
    static let maxLanes = 3
    static let previewPermits = DispatchSemaphore(value: maxLanes)

    private static let lanes = ScopedStore<[BrowserBridge]>(
        make: { scope in
            (1...maxLanes).map { BrowserBridge(sessionID: sessionID(for: scope, lane: $0), isPreview: true) }
        },
        drop: { bridges in bridges.forEach { $0.shutdown() } }
    )

    /// These bridges start their helpers lazily and expire with the client's scope.
    static func lane(_ index: Int) -> BrowserBridge {
        guard let context = BrowserRequestContext.current else { return lanes.current[index] }
        return configured.current.bridge(environment: context.environment, lane: index + 1)
    }

    private static func sessionID(for scope: String, lane: Int? = nil, base: String = baseSessionID) -> String {
        if let lane { return "\(base)-lane\(lane)-\(scope)" }
        return scope == "main" ? base : "\(base)-client-\(scope)"
    }

    let sessionID: String
    let referenceScope = UUID()
    private let launchEnvironment: [String: String]

    init(sessionID: String, launchEnvironment: [String: String] = GodspeedSettings.environment, isPreview: Bool = false) {
        self.sessionID = sessionID
        self.launchEnvironment = launchEnvironment
        idleStopAfter = isPreview ? 60 : Self.stopAfter
        idleTimer = DispatchSource.makeTimerSource(queue: Self.housekeeping)
        idleTimer.setEventHandler { [weak self] in self?.handleIdleDeadline() }
        idleTimer.schedule(deadline: .distantFuture)
        idleTimer.resume()
    }

    deinit { idleTimer.cancel() }

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

    @TaskLocal static var implicitTabGeneration: Int?

    func resolveImplicitTab() throws -> (id: Int, generation: Int) {
        try withToolConnection {
            try startIfNeeded()
            let preferred = currentTab
            if let preferred, let verifiedImplicitTab,
               verifiedImplicitTab.id == preferred, verifiedImplicitTab.generation == helperGeneration {
                return verifiedImplicitTab
            }
            let reply = try requestTool("tabs", arguments: [:], timeout: 10)
            guard !reply.isError, let ids = BrowserReply.sessionTabIDs(in: reply.text) else {
                throw ComputerUseError.stateUnavailable("browser: could not verify the session's tabs. List tabs before continuing.")
            }
            let selected: Int
            if let preferred {
                guard ids.contains(preferred) else {
                    throw ComputerUseError.stateUnavailable("browser: the previous tab is unavailable in this session. List tabs and select the intended tab.")
                }
                selected = preferred
            } else {
                guard ids.count == 1, let only = ids.first else {
                    throw ComputerUseError.invalidArguments("browser: choose a tab with browser tabs and use_tab, or open a page")
                }
                selected = only
            }
            currentTab = selected
            verifiedImplicitTab = (selected, helperGeneration)
            return (selected, helperGeneration)
        }
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

    static var isAvailable: Bool { executablePath(environment: BrowserRequestContext.environment) != nil }

    /// The app the accessibility path reads after a browser step. Default Google Chrome.
    static var browserApp: String {
        let value = BrowserRequestContext.environment["OPEN_COMPUTER_USE_BROWSER_APP"]?.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private var helperGeneration = 0
    // Protected by the connection lock; selection is rechecked once per helper generation.
    private var verifiedImplicitTab: (id: Int, generation: Int)?
    // Only direct open_tab replies confer ownership. A tab in the session list may be a user's claimed tab.
    private var openedTabs: Set<Int> = []

    var referenceGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return helperGeneration
    }
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
    private var lastUse: TimeInterval = 0
    private var detached = true
    private let idleStopAfter: TimeInterval
    private let idleTimer: DispatchSourceTimer
    private static let housekeeping = DispatchQueue(label: "godspeed.browser.idle", qos: .utility)

    /// One rescheduled timer per helper. A burst of CDP commands does not accumulate idle closures.
    private func handleIdleDeadline() {
        lock.lock()
        defer { lock.unlock() }
        guard let child = process, child.isRunning else {
            idleTimer.schedule(deadline: .distantFuture)
            return
        }
        let clock = ProcessInfo.processInfo
        let age = clock.systemUptime - lastUse
        if age >= idleStopAfter {
            child.terminate()
            process = nil
            input = nil
            idleTimer.schedule(deadline: .distantFuture)
            return
        }
        if !detached && age >= Self.detachAfter {
            _ = try? request(method: "tools/call", params: ["name": "turn_ended", "arguments": [String: Any]()], timeout: 2)
            detached = true
        }
        let threshold = detached ? idleStopAfter : Self.detachAfter
        let remaining = max(0, threshold - (clock.systemUptime - lastUse))
        idleTimer.schedule(deadline: .now() + remaining, leeway: .milliseconds(500))
    }

    /// Calls one OBU tool and returns its text and error flag. One request at a time.
    func callTool(
        _ name: String, arguments: [String: Any], timeout: TimeInterval, referenceGeneration: Int? = nil
    ) throws -> (text: String, isError: Bool) {
        try withToolConnection {
            if let referenceGeneration, process?.isRunning != true || referenceGeneration != helperGeneration {
                throw ComputerUseError.invalidArguments("browser: the tab connection changed; browser read again before using an element number")
            }
            if let generation = Self.implicitTabGeneration,
               process?.isRunning != true || generation != helperGeneration {
                throw ComputerUseError.stateUnavailable("browser: the connection changed after selecting the tab. Read the tab before continuing.")
            }
            try startIfNeeded()
            // Claiming changes OBU's origin for this tab to "user", even if a later part of the request fails.
            if name == "claim_tab", let id = arguments["tab_id"] as? Int { openedTabs.remove(id) }
            let reply = try requestTool(name, arguments: arguments, timeout: timeout)
            if name == "open_tab", !reply.isError, let id = BrowserReply.createdTabID(in: reply.text) {
                openedTabs.insert(id)
            }
            return reply
        }
    }

    func closeOpenedTab(_ id: Int) throws {
        try withToolConnection {
            guard process?.isRunning == true, openedTabs.contains(id) else {
                throw ComputerUseError.invalidArguments("browser close_tab requires a tab opened by this browser connection")
            }
            // The regular OBU MCP exposes scoped CDP. Its IAB close_tab uses this same Chrome operation.
            // Send it once without the BrowserPage CDP recovery path, which can dismiss page prompts.
            let deadline = BrowserCallBudget.deadline(after: min(12, BrowserCallBudget.remaining()))
            // Keep time for a readback if the close took effect before its reply arrived.
            let closeWait = min(8, deadline - ProcessInfo.processInfo.systemUptime - 2)
            guard closeWait > 0 else {
                throw ComputerUseError.timedOut("browser close_tab did not run because little time remained.", delivery: .notSent)
            }
            _ = try? requestTool("cdp", arguments: ["tab_id": id, "method": "Page.close"], timeout: closeWait)
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0.3, process?.isRunning == true else { break }
                guard let listed = try? requestTool("tabs", arguments: [:], timeout: min(1, remaining)),
                      !listed.isError, let tabs = BrowserReply.sessionTabIDs(in: listed.text),
                      !tabs.contains(id) else { continue }
                openedTabs.remove(id)
                tabLock.lock()
                if preferredTab == id { preferredTab = nil }
                tabLock.unlock()
                BrowserPageMemory.shared.forgetTab(bridge: self, tab: id)
                return
            }
            throw ComputerUseError.stateUnavailable("browser could not confirm tab \(id) closed. Check browser tabs before retrying.")
        }
    }

    private func withToolConnection<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            lastUse = ProcessInfo.processInfo.systemUptime
            detached = false
            idleTimer.schedule(deadline: .now() + Self.detachAfter, leeway: .milliseconds(500))
            lock.unlock()
        }
        return try body()
    }

    private func requestTool(
        _ name: String, arguments: [String: Any], timeout: TimeInterval
    ) throws -> (text: String, isError: Bool) {
        let result = try request(method: "tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        guard let content = result["content"] as? [[String: Any]],
              content.allSatisfy({ item in
                  guard let type = item["type"] as? String else { return false }
                  return type != "text" || item["text"] is String
              }) else {
            throw Self.unreadableReply
        }
        if let flag = result["isError"] {
            guard let boolean = flag as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                throw Self.unreadableReply
            }
        }
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
        idleTimer.schedule(deadline: .distantFuture)
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
        if StrictBackground.enabled() {
            throw ComputerUseError.backgroundUnsupported("The browser helper is not connected.")
        }
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

        try BrowserRequestContext.validateCurrent()
        try child.run()
        process = child
        helperGeneration += 1
        openedTabs.removeAll()
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
            try BrowserRequestContext.validateCurrent()
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
        try BrowserRequestContext.validateCurrent()
        let profiles = BrowserRequestContext.environment["OPEN_COMPUTER_USE_BROWSER_PROFILE_TIMING"] == "1"
        let began = ProcessInfo.processInfo.systemUptime
        var received = false
        defer {
            if profiles {
                let tool = params["name"] as? String ?? method
                let arguments = params["arguments"] as? [String: Any]
                let operation = tool == "cdp" ? (arguments?["method"] as? String ?? tool) : tool
                let ms = Int(((ProcessInfo.processInfo.systemUptime - began) * 1000).rounded())
                FileHandle.standardError.write(Data("godspeed-helper \(operation) \(ms) \(received ? "reply" : "no_reply")\n".utf8))
            }
        }
        let wait = min(timeout, BrowserCallBudget.activeRemaining ?? timeout)
        guard wait > 0 else { throw ComputerUseError.timedOut("The browser request ran out of time.", delivery: .notSent) }
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let message = responses.wait(for: id, timeout: wait) else {
            // The command may already have landed. Retire this transport and let a later
            // request reconnect, without resending the timed-out command.
            if process?.isRunning == true { process?.terminate() }
            process = nil
            input = nil
            openedTabs.removeAll()
            throw ComputerUseError.timedOut(
                "Open Browser Use did not answer \(method) within \(Int(wait.rounded())) s. Inspect the tab before repeating the action.",
                delivery: .outcomeUnknown
            )
        }
        received = true
        if let error = message["error"] as? [String: Any] {
            throw ComputerUseError.message("Open Browser Use: \(error["message"] as? String ?? "request failed")")
        }
        guard let result = message["result"] as? [String: Any] else {
            throw Self.unreadableReply
        }
        return result
    }

    private static let unreadableReply = ComputerUseError.stateUnavailable(
        "browser: the helper returned an unreadable reply. Inspect the tab before repeating the command."
    )

    private func send(_ object: [String: Any]) throws {
        guard let input else {
            throw ComputerUseError.notSent("Open Browser Use is not running.")
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
            throw ComputerUseError.stateUnavailable("Open Browser Use disconnected during the send. Inspect the tab before retrying.")
        }
    }
}

struct BrowserPreviewPage: Sendable {
    let status: String
    let text: String
    let cleanupConfirmed: Bool?
}

/// Results of parallel page loads, one slot per URL.
private final class PeekResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BrowserPreviewPage]
    private var nextIndex = 0

    init(count: Int) {
        values = Array(repeating: BrowserPreviewPage(status: "not_started", text: "No preview worker started this page.", cleanupConfirmed: nil), count: count)
    }

    func takeNextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < values.count else { return nil }
        let index = nextIndex
        nextIndex += 1
        return index
    }

    func set(_ index: Int, _ value: BrowserPreviewPage) {
        lock.lock(); values[index] = value; lock.unlock()
    }

    func get(_ index: Int) -> BrowserPreviewPage {
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
    @TaskLocal static var defersBrowserNavigationObservation = false
    @TaskLocal static var clipsBrowserStepObservation = false

    /// The `browser` tool: a handful of OBU abilities behind one verb, so a model sees one extra tool.
    func runBrowser(arguments: [String: Any]) throws -> ToolCallResult {
        let action = (arguments["action"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        let limit = ["peek", "read_many", "open_many"].contains(action ?? "") ? Self.peekBudget : BrowserCallBudget.limit
        let remaining = min(limit, BrowserCallBudget.activeRemaining ?? limit)
        return try BrowserCallBudget.withDeadline(BrowserCallBudget.deadline(after: remaining)) {
            try BrowserRequestContext.validateCurrent()
            let result = try runBrowserAction(arguments: arguments)
            try BrowserRequestContext.validateCurrent()
            return result
        }
    }

    private func runBrowserAction(arguments: [String: Any]) throws -> ToolCallResult {
        var arguments = arguments
        let action = Self.canonicalBrowserAction(((arguments["action"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased())
        let policy = try currentActionPolicy()
        try authorizeBrowserRequest(policy, action: action, arguments: arguments)
        guard BrowserBridge.isAvailable else {
            if StrictBackground.enabled() {
                throw ComputerUseError.backgroundUnsupported("The browser helper is unavailable.")
            }
            throw ComputerUseError.notSent(BrowserBridge.notInstalledMessage)
        }
        let bridge = BrowserBridge.shared
        if let direction = Self.browserScrollDirection[((arguments["action"] as? String) ?? "").lowercased()], arguments["direction"] == nil {
            arguments["direction"] = direction
        }
        if !action.isEmpty, !Self.knownBrowserActions.contains(action) {
            throw ComputerUseError.invalidArguments(
                "browser action must be one of: open, go, read, screenshot, click, drag, type, fill_field, copy, cut, paste, key, hover, select, check, uncheck, scroll, scroll_into_view, back, forward, reload, wait_for, tabs, use_tab, close_tab, wait, location, info, outline, frames, read_text, link_destination, control_state, value, upload, peek"
            )
        }
        // Actions that name no tab; every other action works in the explicit tab, else the current one.
        let tabless: Set<String> = ["open", "new_tab", "open_tab", "tabs", "list", "peek", "read_many", "open_many", "close_tab"]
        var tab: [String: Any] = [:]
        let explicit = try Self.validatedBrowserTabID(arguments["tab_id"])
        let implicit = explicit == nil && !tabless.contains(action) ? try bridge.resolveImplicitTab() : nil
        if let id = explicit ?? implicit?.id { tab["tab_id"] = id }
        return try BrowserBridge.$implicitTabGeneration.withValue(implicit?.generation) {
            let result = try browserAction(action, arguments: arguments, bridge: bridge, tab: tab, policy: policy)
            // A page can navigate while a read, wait or action is in flight.
            if !result.isError, tab["tab_id"] != nil, action != "close_tab",
               !Self.browserOpenActions.contains(action), !Self.browserPreviewActions.contains(action),
               !Self.browserListActions.contains(action) {
                try Self.authorizeBrowserPage(policy, page: BrowserPage(bridge: bridge, tab: tab), afterDelivery: true)
            }
            return result
        }
    }

    /// Spellings models reach for, mapped to the action that does it. Real sessions failed on these.
    static let browserActionAliases: [String: String] = [
        "input": "type", "enter_text": "type", "fill_in": "type",
        "keypress": "key", "keys": "key", "hotkey": "key",
        "select_option": "select", "pick": "select",
        "get_text": "read_text", "extract_text": "read_text", "text": "read_text",
        "get_state": "read", "observe": "read", "find": "read", "get_page": "read",
        "list_tabs": "tabs", "get_tabs": "tabs",
        "close": "close_tab",
        "switch_tab": "use_tab", "focus_tab": "use_tab", "activate_tab": "use_tab",
        "open_url": "go", "goto_url": "go", "load": "go", "navigate_to": "go",
        "scroll_down": "scroll", "scroll_up": "scroll", "scroll_page": "scroll",
        "capture": "screenshot", "take_screenshot": "screenshot",
        "refresh": "reload", "go_back": "back", "go_forward": "forward",
        "wait_for_text": "wait_for", "wait_for_selector": "wait_for", "wait_for_element": "wait_for",
        "url": "location", "current_url": "location", "get_url": "location",
        "hover_over": "hover", "mouse_over": "hover",
    ]
    static let browserScrollDirection: [String: String] = ["scroll_down": "down", "scroll_up": "up"]

    /// Every action `browserAction` handles (its switch cases). Checked first, so an unknown action says so
    /// instead of asking for a tab.
    static let knownBrowserActions: Set<String> = ["back", "check", "choose", "claim", "claim_tab", "click", "close_tab", "control_state", "copy", "cut", "drag", "files", "fill", "fill_field", "forward", "frames", "go", "goto", "hover", "info", "key", "link_destination", "list", "location", "look", "look_at", "navigate", "new_tab", "open", "open_many", "open_tab", "outline", "page", "page_info", "paste", "peek", "press", "press_key", "read", "read_many", "read_text", "reload", "screenshot", "scroll", "scroll_into_view", "see", "select", "snapshot", "state", "switch", "tabs", "tap", "tick", "type", "type_text", "uncheck", "untick", "upload", "use_tab", "value", "visit", "wait", "wait_for", "wait_load"]

    static func canonicalBrowserAction(_ action: String) -> String {
        browserActionAliases[action.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")] ?? action
    }

    private func browserAction(
        _ action: String, arguments: [String: Any], bridge: BrowserBridge, tab: [String: Any], policy: ActionPolicy
    ) throws -> ToolCallResult {
        let page = BrowserPage(bridge: bridge, tab: tab)
        if policy.checksOrigins {
            let tabless = Self.browserOpenActions.union(Self.browserPreviewActions).union(Self.browserListActions)
            if Self.browserClaimActions.contains(action) || action == "close_tab" {
                guard let id = Self.browserTabID(arguments["tab_id"]) else {
                    throw ComputerUseError.invalidArguments("A tab ID is required by the browser action policy.")
                }
                let list = try bridge.callTool(action == "close_tab" ? "tabs" : "user_tabs", arguments: [:], timeout: 5)
                let own = action != "close_tab" ? try bridge.callTool("tabs", arguments: [:], timeout: 5) : list
                guard let url = BrowserReply.tabURL(in: own.text, id: id) ?? BrowserReply.tabURL(in: list.text, id: id) else {
                    throw ComputerUseError.actionDenied("The browser could not confirm the tab's origin.")
                }
                try Self.authorizeBrowserAddresses(policy, addresses: [url])
            } else if !tabless.contains(action) {
                try Self.authorizeBrowserPage(policy, page: page)
            }
        }
        func verifyPage(_ page: BrowserPage, afterDelivery: Bool = true) throws {
            try Self.authorizeBrowserPage(policy, page: page, afterDelivery: afterDelivery)
        }
        func includeTab(_ url: String) -> Bool {
            (try? Self.authorizeBrowserAddresses(policy, addresses: [url])) != nil
        }
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

        func clipboardAction(_ operation: PrivateClipboard.Action) throws -> ToolCallResult {
            switch operation {
            case .copy, .cut:
                try page.copySelectionToPrivateClipboard(cut: operation == .cut)
                return .text(operation == .copy ? "Copied selected text to the private clipboard." : "Cut selected text to the private clipboard.")
            case .paste:
                let node = label != nil || index != nil ? try target() : nil
                try authorizeBrowserEffect(policy, action: "paste", arguments: arguments, page: page, node: node)
                if case .files(let paths, let move) = PrivateClipboard.current.payload {
                    guard !move, let node else {
                        throw ComputerUseError.invalidArguments("Paste copied files into a labelled Chrome file input. Cut files can only be moved in Finder.")
                    }
                    try page.setFiles(paths, on: node)
                    return .text("Selected \(paths.count) file(s) in the upload control.", deliveryState: .verified)
                }
                let text = try PrivateClipboard.current.textForPaste()
                if text.isEmpty { return .text("Private clipboard text is empty.") }
                let result = try page.type(text, replace: false, into: node, keyEvents: false)
                return .text(result.reply(verb: "Pasted into", target: node?.name ?? "the focused Chrome field"),
                             deliveryState: result.deliveryState)
            case .moveFiles:
                throw ComputerUseError.invalidArguments("Move-paste is only available in Finder.")
            }
        }

        switch action {
        case "copy", "cut", "paste":
            guard let operation = PrivateClipboard.Action(rawValue: action) else {
                throw ComputerUseError.invalidArguments("Invalid private clipboard action.")
            }
            return try clipboardAction(operation)
        case "read", "state", "look", "snapshot":
            let find = (arguments["find"] ?? arguments["query"] ?? arguments["filter"]) as? String
            let snapshot = try page.readSnapshot(
                find: find, full: Self.browserFlag(arguments["full"]),
                interactive: Self.browserFlag(arguments["interactive"]), diff: Self.browserFlag(arguments["diff"]),
                includeLinkURLs: Self.browserFlag(arguments["include_link_urls"]),
                keepsDiffBaseline: !Self.clipsBrowserStepObservation
            )
            return ToolCallResult(
                content: [.text(snapshot.text)], isError: false, browserObservationURL: snapshot.verifiedURL,
                browserFullObservationText: snapshot.fullText
            )

        case "screenshot", "see", "look_at":
            let generation = bridge.referenceGeneration
            let image = try page.screenshot()
            let place = try? page.location()
            if let id = tab["tab_id"] as? Int, let place, !place.href.isEmpty,
               generation == bridge.referenceGeneration {
                let unchanged = BrowserPageMemory.shared.rememberScreenshot(
                    image, bridge: bridge, tab: id, generation: generation, url: place.href
                )
                if unchanged, Self.browserFlag(arguments["if_changed"]) {
                    return .text("Screenshot unchanged in tab \(id) since the last capture.")
                }
            }
            return ToolCallResult(content: [
                .text("Screenshot of \(place.map { $0.title.isEmpty ? $0.href : "\($0.title) — \($0.href)" } ?? "the page") (visible part)."),
                .screenshotImage(image),
            ])

        case "click", "press", "tap":
            let buttonName = arguments["mouse_button"] as? String ?? "left"
            guard let button = BrowserPage.PointerButton(rawValue: buttonName) else {
                throw ComputerUseError.invalidArguments("browser click mouse_button must be left, right or middle")
            }
            let count = try Self.browserClickCount(arguments["click_count"], button: button)
            let modifiers = try Self.browserPointerModifiers(arguments["modifiers"])
            let node = try target()
            try authorizeBrowserEffect(policy, action: action, arguments: arguments, page: page, node: node)
            let click = try clickAndWatch(node, page: page, bridge: bridge, button: button, count: count, modifiers: modifiers, policy: policy)
            return ToolCallResult(content: [.text(click.text)], isError: false, browserContinuationTabID: click.tabID)

        case "drag":
            guard tab["tab_id"] != nil else {
                throw ComputerUseError.invalidArguments("browser drag needs an open or explicitly selected tab")
            }
            let destinationLabel = arguments["to_label"] as? String
            let destinationIndex = Self.browserTabID(arguments["to_index"])
            guard destinationLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || destinationIndex != nil else {
                throw ComputerUseError.invalidArguments("browser drag needs to_label or to_index for the destination")
            }
            let modifiers = try Self.browserPointerModifiers(arguments["modifiers"])
            let source = try target()
            let destination = try page.resolve(label: destinationLabel, index: destinationIndex)
            try page.drag(from: source, to: destination, modifiers: modifiers)
            return .text("Drag delivered. Read the tab to verify the drop.")

        case "type", "type_text", "fill", "fill_field":
            guard let text = arguments["text"] as? String else {
                throw ComputerUseError.invalidArguments("browser type needs text (and a label or index for the field, or it types into the focused field)")
            }
            let replace = action == "fill_field" || Self.browserFlag(arguments["replace"])
            var node: BrowserNode?
            var targetName = "the focused field"
            if label != nil || index != nil {
                let found = try target()
                node = found
                targetName = "\(found.role) \"\(found.name)\""
            }
            try authorizeBrowserEffect(policy, action: action, arguments: arguments, page: page, node: node)
            let outcome = try page.type(text, replace: replace, into: node, keyEvents: action != "fill_field")
            let verb = replace && text.isEmpty ? "cleared" : "typed into"
            return .text(outcome.reply(verb: verb, target: targetName), deliveryState: outcome.deliveryState)

        case "key", "press_key":
            guard let key = arguments["key"] as? String, !key.isEmpty else {
                throw ComputerUseError.invalidArguments("browser key needs key, e.g. Enter, Tab, Escape, ArrowDown, or a combination such as Cmd+A")
            }
            if let operation = PrivateClipboard.Action(key: key, browser: true) {
                return try clipboardAction(operation)
            }
            try authorizeBrowserEffect(policy, action: action, arguments: arguments, page: page)
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
            return .text("\(outcome); \(page.settle().line)", deliveryState: .verified)

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
            return .text(try page.history(action) { try Self.authorizeBrowserAddresses(policy, addresses: [$0]) })

        case "wait_for":
            let text = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let wantedText = text.flatMap { $0.isEmpty ? nil : $0 }
            let urlPart = (arguments["url_contains"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if arguments["url_contains"] != nil {
                guard let urlPart, !urlPart.isEmpty, wantedText == nil, label == nil else {
                    throw ComputerUseError.invalidArguments("browser wait_for needs one nonempty url_contains, text, or label")
                }
            } else if wantedText == nil, label == nil {
                throw ComputerUseError.invalidArguments("browser wait_for needs text, label, or url_contains")
            }
            let condition: BrowserPage.ControlCondition?
            if let raw = arguments["condition"] {
                guard label != nil, wantedText == nil, urlPart == nil,
                      let name = raw as? String, let parsed = BrowserPage.ControlCondition(rawValue: name) else {
                    throw ComputerUseError.invalidArguments("browser wait_for condition needs a label and one of visible, enabled, checked, unchecked")
                }
                condition = parsed
            } else {
                condition = nil
            }
            let seconds = Swift.min(30, Swift.max(1, Self.browserTabID(arguments["timeout"]) ?? 10))
            let what = urlPart.map { "URL containing \"\($0)\"" } ?? "\"\(wantedText ?? label ?? "")\""
            let expected = condition.map { "\(what) is \($0.rawValue)" } ?? what
            guard page.waitFor(text: wantedText, label: wantedText == nil ? label : nil,
                               urlContains: urlPart, controlCondition: condition, timeout: TimeInterval(seconds)) else {
                throw ComputerUseError.stateUnavailable("browser: could not confirm \(expected) before the wait ended. Read the tab before continuing.")
            }
            return .text("confirmed \(expected)")

        case "peek", "read_many", "open_many":
            guard let addresses = arguments["urls"] as? [String], (1...6).contains(addresses.count) else {
                throw ComputerUseError.invalidArguments("browser peek needs one to six URLs")
            }
            let urls = try addresses.map { address -> String in
                guard let url = try Self.navigationURL(address), BrowserRules.isWebAddress(url) else {
                    throw ComputerUseError.invalidArguments("browser peek needs HTTP or HTTPS URLs")
                }
                return url
            }
            let pages = Self.readPreviewPages(urls) { try Self.authorizeBrowserPage(policy, page: $0, afterDelivery: true) }
            let content = Self.renderPreviewPages(urls, pages: pages)
            return ToolCallResult(content: [.text(content)], isError: false,
                                  browserPreviewPages: zip(urls, pages).map { url, page in
                var entry: [String: Any] = ["url": url, "status": page.status, "text": page.text]
                entry["cleanup_confirmed"] = page.cleanupConfirmed
                return entry
            })

        case "open", "new_tab", "open_tab":
            let url = try Self.navigationURL(arguments["url"])
            let opened = try bridge.callTool("open_tab", arguments: url.map { ["initial_url": $0] } ?? [:], timeout: 10)
            guard !opened.isError else { return finish([opened]) }
            guard let newID = BrowserReply.createdTabID(in: opened.text) else {
                throw ComputerUseError.stateUnavailable("browser: open may have created a tab, but returned no tab ID. List tabs before retrying.")
            }
            BrowserPageMemory.shared.forgetTab(bridge: bridge, tab: newID)
            guard let url else {
                bridge.currentTab = newID
                return .text("opened a blank tab (id \(newID))")
            }
            if !BrowserReply.acceptedInitialNavigation(in: opened.text) {
                // Keep the allocated tab ID even when attaching or navigating fails.
                let navigation: (text: String, isError: Bool)
                do {
                    navigation = try bridge.callTool("navigate", arguments: ["tab_id": newID, "url": url], timeout: 15)
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    throw ComputerUseError.stateUnavailable("browser: tab \(newID) was created, but navigation was not confirmed. Inspect that tab before retrying. \(reason)")
                }
                if let error = BrowserReply.navigationError(in: navigation.text) ?? (navigation.isError ? BatchTool.firstLine(navigation.text) : nil) {
                    throw ComputerUseError.stateUnavailable("browser: tab \(newID) was created, but navigation was not confirmed. Inspect that tab before retrying. \(error)")
                }
            }
            let fresh = BrowserPage(bridge: bridge, tab: ["tab_id": newID])
            // Chrome can confirm that an exact new tab finished loading without attaching
            // a debugger just to evaluate document.readyState.
            var loaded = false
            if Self.defersBrowserNavigationObservation, BrowserReply.acceptedInitialNavigation(in: opened.text),
               BrowserCallBudget.remaining() > 3,
               let tabs = try? bridge.callTool("tabs", arguments: [:], timeout: 2), !tabs.isError {
                loaded = BrowserReply.completedTab(in: tabs.text, id: newID, expectedURL: url)
            }
            guard loaded || fresh.waitLoad(changedFrom: nil, expect: url, timeout: 20) else {
                try verifyPage(fresh)
                throw ComputerUseError.stateUnavailable("browser: tab \(newID) was created, but the requested page did not become ready. Inspect that tab before retrying.")
            }
            try verifyPage(fresh)
            bridge.currentTab = newID
            if Self.defersBrowserNavigationObservation { return .text("opened tab \(newID)") }
            fresh.settle()
            fresh.prime()
            // The page comes with the reply, so the model needs no separate read before acting.
            if let read = try? fresh.read(find: nil, full: false) { return .text("opened. " + read) }
            return .text("opened \(fresh.title(try? fresh.location()))")

        case "go", "goto", "navigate", "visit":
            guard let url = try Self.navigationURL(arguments["url"]) else {
                throw ComputerUseError.invalidArguments("browser go needs a url")
            }
            let before = try? page.location()
            let moved = try call("navigate", ["url": url])
            let failure = BrowserReply.navigationError(in: moved.text)
            if moved.isError || failure != nil {
                let reason = failure ?? BatchTool.firstLine(moved.text)
                throw ComputerUseError.message("browser: could not load \(url): \(reason). Check the address, or browser tabs if this tab is gone")
            }
            guard page.waitLoad(changedFrom: before?.href, expect: url, timeout: 20) else {
                try verifyPage(page)
                throw ComputerUseError.stateUnavailable("browser: navigation was sent, but the requested page did not become ready. Read the tab before retrying.")
            }
            try verifyPage(page)
            page.settle()
            page.prime()
            if Self.defersBrowserNavigationObservation { return .text("navigation ready") }
            if let read = try? page.read(find: nil, full: false) { return .text("went there. " + read) }
            return .text("went to \(page.title(try? page.location()))")

        case "close_tab":
            guard let id = tab["tab_id"] as? Int, id > 0,
                  (arguments["tab_id"] as? NSNumber).map({ Int(exactly: $0.doubleValue) == id }) ?? true else {
                throw ComputerUseError.invalidArguments("browser close_tab needs a positive, whole tab_id from browser tabs")
            }
            try bridge.closeOpenedTab(id)
            return .text("closed tab \(id)", deliveryState: .verified)

        case "tabs", "list":
            let mine = try bridge.callTool("tabs", arguments: [:], timeout: 10)
            var lines = ["Tabs in this session (browser use_tab with tab_id):"]
            let own = BrowserReply.tabLines(in: mine.text, limit: 30, include: includeTab)
            lines += own.isEmpty ? [mine.isError ? BatchTool.firstLine(mine.text) : "(none)"] : own
            if let theirs = try? bridge.callTool("user_tabs", arguments: [:], timeout: 10), !theirs.isError {
                let user = BrowserReply.tabLines(in: theirs.text, limit: 15, include: includeTab)
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
            BrowserPageMemory.shared.forgetTab(bridge: bridge, tab: id)
            try verifyPage(page)
            guard let place = try? page.location(), !place.href.isEmpty else {
                throw ComputerUseError.stateUnavailable("browser: tab \(id) was claimed, but its connection could not be verified. The current tab selection was kept. Inspect the listed tabs before retrying.")
            }
            bridge.currentTab = id
            return .text("now working in tab \(id) (\(page.title(place)))")

        case "wait", "wait_load":
            let seconds = Swift.min(30, Swift.max(1, Self.browserTabID(arguments["timeout"]) ?? 30))
            guard page.waitLoad(changedFrom: nil, timeout: TimeInterval(seconds)) else {
                throw ComputerUseError.message("browser: the page is still loading after \(seconds) s; browser wait again, or browser read it")
            }
            return .text("page is loaded: \(page.title(try? page.location()))")

        case "read_text":
            let text = try page.readTargetText(label: label, index: index)
            return .text(text.isEmpty ? "Text: (empty)" : text)

        case "link_destination":
            let node = try target()
            guard node.role == "link", let target = page.linkTarget(node),
                  let url = BrowserRules.displayableLinkURL(target.href) else {
                throw ComputerUseError.stateUnavailable("browser: no readable HTTP or HTTPS destination for that link.")
            }
            return .text(BatchTool.clipped("Destination: " + url, limit: 1_000))

        case "control_state":
            return .text(try page.controlState(target()))

        case "value":
            let node = try target()
            guard let value = try page.fieldText(node) else {
                throw ComputerUseError.stateUnavailable("browser: this control has no readable editable value.")
            }
            return .text(BatchTool.clipped(value.isEmpty ? "Value: (empty)" : "Value: " + value, limit: 1_000))

        case "outline":
            return .text(try page.outline())

        case "frames":
            return .text(try page.frameSummary())

        case "scroll_into_view":
            try page.scrollIntoView(target())
            return .text("Scrolled the requested control into view.")

        case "location":
            let place = try page.location()
            return ToolCallResult(
                content: [.text("URL: \(place.href)\nTitle: \(place.title)\nReady state: \(place.readyState)")],
                isError: false, browserObservationURL: place.href
            )

        case "info", "page", "page_info":
            let raw = try page.evaluate("[location.href, document.title, document.body ? document.body.innerText.slice(0, 20000) : '']")
            let values = (raw as? [Any]) ?? []
            guard values.count == 3 else {
                throw ComputerUseError.message("browser: could not read the page; browser wait, then try again")
            }
            let text = (values[2] as? String) ?? ""
            return .text(BatchTool.clipped("\(page.title(BrowserLocation(href: values[0] as? String ?? "", title: values[1] as? String ?? "", readyState: "complete")))\n\(text)", limit: 3_000))

        case "upload", "files":
            try authorizeAction(policy, bundleIDs: [], risks: [.submit])
            let files = (arguments["files"] as? [String]) ?? ((arguments["file"] as? String).map { [$0] } ?? [])
            guard !files.isEmpty else {
                throw ComputerUseError.invalidArguments("browser upload needs files: [\"/path/to/file\"]. Click the page's upload button in the same batch first.")
            }
            if label != nil || index != nil {
                try page.setFiles(files, on: target())
                return .text("Selected \(files.count) file(s) in the upload control.")
            }
            let chooser = try call("wait_file_chooser", timeout: 15)
            guard !chooser.isError else { return finish([chooser]) }
            guard let chooserID = Self.fileChooserID(in: chooser.text) else {
                return .text("browser upload: no file dialog opened. Click the page's upload button in the same batch first.", isError: true)
            }
            return finish([try bridge.callTool("set_file_chooser_files", arguments: ["file_chooser_id": chooserID, "files": files], timeout: 15)])

        default:
            throw ComputerUseError.invalidArguments(
                "browser action must be one of: open, go, read, screenshot, click, drag, type, fill_field, copy, cut, paste, key, hover, select, check, uncheck, scroll, scroll_into_view, back, forward, reload, wait_for, tabs, use_tab, close_tab, wait, location, info, outline, frames, read_text, link_destination, control_state, value, upload, peek"
            )
        }
    }

    private static func browserClickCount(_ raw: Any?, button: BrowserPage.PointerButton) throws -> Int {
        guard let raw else { return 1 }
        guard let count = browserTabID(raw), count == 1 || (count == 2 && button == .left) else {
            throw ComputerUseError.invalidArguments("browser click_count must be 1, or 2 for the left button")
        }
        return count
    }

    private static func browserPointerModifiers(_ raw: Any?) throws -> Int {
        guard let raw else { return 0 }
        guard let modifiers = raw as? [String] else {
            throw ComputerUseError.invalidArguments("browser pointer modifiers must be an array of key names")
        }
        var mask = 0
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "alt", "option": mask |= 1
            case "ctrl", "control": mask |= 2
            case "cmd", "meta", "command": mask |= 4
            case "shift": mask |= 8
            default: throw ComputerUseError.invalidArguments("browser pointer modifiers must be alt, ctrl, cmd or shift")
            }
        }
        return mask
    }

    /// Clicks an element. A link is followed for a moment, so the reply says where it landed. A click that
    /// opens a new tab makes that tab the working tab, and the reply says so.
    private func clickAndWatch(_ node: BrowserNode, page: BrowserPage, bridge: BrowserBridge,
                               button: BrowserPage.PointerButton, count: Int, modifiers: Int, policy: ActionPolicy) throws -> (text: String, tabID: Int?) {
        // Open an explicit new-tab destination in the background. If delivery is uncertain,
        // do not fall back to clicking the link and potentially open it twice.
        let link = node.role == "link" ? page.linkTarget(node) : nil
        if button == .left, count == 1, modifiers == 0,
           let link, let url = BrowserRules.newTabLinkURL(href: link.href, target: link.target) {
            if StrictBackground.enabled() {
                throw ComputerUseError.backgroundUnsupported("This link needs a new tab.")
            }
            try Self.authorizeBrowserAddresses(policy, addresses: [url])
            let opened = try bridge.callTool("open_tab", arguments: ["url": url], timeout: 20)
            guard !opened.isError, let newID = BrowserReply.createdTabID(in: opened.text) else {
                throw ComputerUseError.stateUnavailable("browser: the background link may have opened. List tabs before repeating the click.")
            }
            BrowserPageMemory.shared.forgetTab(bridge: bridge, tab: newID)
            let destination = BrowserPage(bridge: bridge, tab: ["tab_id": newID])
            guard destination.waitLoad(changedFrom: nil, expect: url, timeout: 20) else {
                try Self.authorizeBrowserPage(policy, page: destination, afterDelivery: true)
                throw ComputerUseError.stateUnavailable("browser: link opened tab \(newID), but the destination did not become ready. Inspect that tab before retrying.")
            }
            try Self.authorizeBrowserPage(policy, page: destination, afterDelivery: true)
            bridge.currentTab = newID
            return ("opened \"\(node.name)\" in a new background tab (id \(newID)); browser now works in that tab", newID)
        }
        let mayOpenTab = ["link", "button", "menuitem"].contains(node.role)
        let tabsBefore = mayOpenTab ? bridge.sessionTabIDs() : nil
        // A link to another address is followed for a moment: the navigation starts a beat after the click.
        let hrefBefore = link.map { BrowserRules.leadsElsewhere(href: $0.href) } == true ? (try? page.location())?.href : nil
        let textBefore = Self.defersBrowserNavigationObservation ? nil : page.visibleTextLines()
        try page.click(node, button: button, count: count, modifiers: modifiers)
        let verb = count == 2 ? "double-clicked" : button == .left ? "clicked" : "\(button.rawValue)-clicked"
        var message = "\(verb) \(node.role) \"\(node.name)\""
        if let hrefBefore, let place = page.followNavigation(from: hrefBefore) {
            try Self.authorizeBrowserPage(policy, page: page, afterDelivery: true)
            message += "; \(BrowserChange.navigated(place.href).line)"
        } else {
            // One event-based wait, so the next step or read sees the result and not the old content.
            let change = page.settle()
            try Self.authorizeBrowserPage(policy, page: page, afterDelivery: true)
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
        if let tabsBefore, let after = bridge.sessionTabIDs() {
            let newTabs = Set(after).subtracting(tabsBefore)
            if newTabs.count > 1 {
                let ids = newTabs.sorted().map { String($0) }.joined(separator: ", ")
                throw ComputerUseError.stateUnavailable("browser: the click ran and multiple tabs appeared (\(ids)). Select the intended tab before continuing.")
            }
            if let fresh = newTabs.first {
                try Self.authorizeBrowserPage(policy, page: BrowserPage(bridge: bridge, tab: ["tab_id": fresh]), afterDelivery: true)
                bridge.currentTab = fresh
                BrowserPageMemory.shared.forgetTab(bridge: bridge, tab: fresh)
                message += "; it opened a new tab (id \(fresh)), and browser now works in that tab"
                return (message, fresh)
            }
        }
        return (message, nil)
    }

    /// Loads each URL in a short-lived tab, reads it and closes it, up to `BrowserBridge.maxLanes` at once
    /// (each lane is its own `obu mcp` with its own session, so the loads really run side by side).
    /// Seconds after which a peek starts no further page (other agents wait while it runs).
    static let peekBudget: TimeInterval = 40

    static func peekPages(_ urls: [String]) -> String {
        renderPreviewPages(urls, pages: readPreviewPages(urls))
    }

    private static func renderPreviewPages(_ urls: [String], pages: [BrowserPreviewPage]) -> String {
        zip(urls, pages).map { url, page in
            "== \(url) [\(page.status)] ==\n\(page.text)"
        }.joined(separator: "\n\n")
    }

    private static func readPreviewPages(_ urls: [String], verifyPage: @Sendable (BrowserPage) throws -> Void = { _ in }) -> [BrowserPreviewPage] {
        let results = PeekResults(count: urls.count)
        let laneCount = min(BrowserBridge.maxLanes, urls.count)
        let remaining = min(peekBudget, BrowserCallBudget.activeRemaining ?? peekBudget)
        let deadline = BrowserCallBudget.deadline(after: remaining)
        // Worker threads do not inherit the caller's client scope: run each lane inside it, so its lane and
        // page memory are this agent's own.
        let scope = ClientScope.current
        let context = BrowserRequestContext.current
        let bridges = (0..<laneCount).map(BrowserBridge.lane)
        DispatchQueue.concurrentPerform(iterations: laneCount) { lane in
            BrowserRequestContext.withContext(context) {
                ClientScope.withScope(scope) {
                    BrowserCallBudget.withDeadline(deadline) {
                        let bridge = bridges[lane]
                        // A fast lane can pick up the next URL while a slow or failed lane is occupied.
                        while BrowserCallBudget.remaining() > 4, let index = results.takeNextIndex() {
                            let permits = BrowserBridge.previewPermits
                            let wait = max(0, BrowserCallBudget.remaining() - 4)
                            guard permits.wait(timeout: .now() + wait) == .success else { break }
                            defer { permits.signal() }
                            guard BrowserCallBudget.remaining() > 4 else { break }
                            let result = peek(urls[index], bridge: bridge, deadline: deadline - 3, verifyPage: verifyPage)
                            results.set(index, result)
                            if result.cleanupConfirmed != true { break }
                        }
                    }
                }
            }
        }
        return urls.indices.map(results.get)
    }

    private static func peek(
        _ url: String, bridge: BrowserBridge, deadline: TimeInterval, verifyPage: @Sendable (BrowserPage) throws -> Void
    ) -> BrowserPreviewPage {
        let outcome: (status: String, text: String)
        do {
            outcome = try BrowserCallBudget.withDeadline(deadline) {
                let opened = try bridge.callTool("open_tab", arguments: ["url": url], timeout: 15)
                if opened.isError { return ("failed", "could not open: \(BatchTool.firstLine(opened.text))") }
                if let error = BrowserReply.navigationError(in: opened.text) { return ("failed", "could not load: \(error)") }
                guard let tabID = BrowserReply.openedTabID(in: opened.text) else {
                    return ("failed", "the browser did not identify the tab it opened")
                }
                let page = BrowserPage(bridge: bridge, tab: ["tab_id": tabID], remember: false)
                guard page.waitLoad(changedFrom: nil, expect: url, timeout: 10) else {
                    return ("failed", "the page did not finish loading")
                }
                try verifyPage(page)
                return ("read", BatchTool.clipped(try page.read(), limit: 2_500))
            }
        } catch {
            outcome = ("failed", (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        let cleanup = try? bridge.callTool("finalize_tabs", arguments: [:], timeout: 3)
        guard let cleanup, !cleanup.isError else {
            return BrowserPreviewPage(status: outcome.status, text: outcome.text + "\nTemporary tab cleanup could not be confirmed.", cleanupConfirmed: false)
        }
        return BrowserPreviewPage(status: outcome.status, text: outcome.text, cleanupConfirmed: true)
    }

    static func browserLabel(_ arguments: [String: Any]) -> String? {
        if let label = arguments["label"] as? String, !label.isEmpty { return label }
        if let labels = arguments["labels"] as? [String], let first = labels.first, !first.isEmpty { return first }
        return nil
    }

    static func navigationURL(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ComputerUseError.invalidArguments("browser url must be a nonempty address; omit it to open a blank tab")
        }
        if raw.hasPrefix("/") || raw.hasPrefix("~/") || raw.lowercased().hasPrefix("file:") {
            throw ComputerUseError.invalidArguments("browser cannot verify a local file through the tab helper. Use the native open tool with the file path and browser app.")
        }
        if raw.lowercased().hasPrefix("data:") {
            throw ComputerUseError.invalidArguments("browser cannot verify data URLs through the tab helper. Serve the fixture on localhost and pass its HTTP URL.")
        }
        return browserURL(raw)
    }

    /// Accepts "example.com" as well as full URLs.
    static func browserURL(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.contains("://") || raw.hasPrefix("about:") || raw.hasPrefix("chrome:") || raw.hasPrefix("file:") { return raw }
        return "https://" + raw
    }

    static func validatedBrowserTabID(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let id = browserTabID(value), id > 0 else {
            throw ComputerUseError.invalidArguments("browser tab_id must be a positive integer")
        }
        return id
    }

    static func browserTabID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let integer = number.intValue
            return number.compare(NSNumber(value: integer)) == .orderedSame ? integer : nil
        }
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
