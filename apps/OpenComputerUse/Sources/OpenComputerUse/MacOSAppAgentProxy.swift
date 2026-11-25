import AppKit
import CoreFoundation
import Darwin
import Foundation
import OpenComputerUseKit

private let appAgentCommand = "__open-computer-use-app-agent"
private let appAgentDisableEnvironmentKey = "OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY"
private let appAgentProcessStartDate = Date()
private let appAgentLaunchEnvironment = ProcessInfo.processInfo.environment
private let appAgentBuildIdentifier = Bundle.main.object(forInfoDictionaryKey: "OpenComputerUseBuildIdentifier") as? String ?? ""

enum MacOSAppAgentProxy {
    static func isAgentInvocation(arguments: [String]) -> Bool {
        arguments.first == appAgentCommand
    }

    @MainActor
    static func runAgent(arguments: [String]) throws {
        guard arguments.count == 2 else {
            throw OpenComputerUseCLIError(message: "\(appAgentCommand) requires a socket path")
        }

        // Swift globals initialize lazily. Capture both before the first request
        // so a later agentInfo call cannot mistake an old process for a rebuild.
        _ = appAgentProcessStartDate
        _ = appAgentLaunchEnvironment
        _ = appAgentBuildIdentifier
        try MacOSAppAgentRuntime.run(socketPath: arguments[1])
    }

    static func shouldProxy(command: OpenComputerUseCLICommand) -> Bool {
        shouldUseMacOSAppAgentProxy(
            command: command,
            proxyDisabled: proxyDisabled,
            appBundleAvailable: PermissionSupport.currentAppBundleURL() != nil,
            runningFromLaunchServicesAppInstance: isRunningFromLaunchServicesAppInstance
        )
    }

    @MainActor
    static func runProxy(command: OpenComputerUseCLICommand, arguments: [String]) throws -> Int32 {
        let socketPath = defaultSocketPath()
        let client = try connectOrLaunchAgent(socketPath: socketPath)

        switch command {
        case .mcp:
            try proxyMCP(client: client, socketPath: socketPath)
            return EXIT_SUCCESS
        default:
            let response = try sendCLIRequest(arguments: arguments, client: client)
            if !response.stdout.isEmpty {
                FileHandle.standardOutput.write(Data(response.stdout.utf8))
            }
            if !response.stderr.isEmpty {
                FileHandle.standardError.write(Data(response.stderr.utf8))
            }
            return response.exitCode
        }
    }

    private static var proxyDisabled: Bool {
        let value = ProcessInfo.processInfo.environment[appAgentDisableEnvironmentKey]?.lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    private static var isRunningFromOpenComputerUseAppBundle: Bool {
        Bundle.main.bundleURL.standardizedFileURL.pathExtension == "app"
            && PermissionSupport.isOpenComputerUseBundleIdentifier(Bundle.main.bundleIdentifier)
    }

    private static var isRunningFromLaunchServicesAppInstance: Bool {
        isRunningFromOpenComputerUseAppBundle && getppid() == 1
    }

    private static func defaultSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                openComputerUseAppAgentSocketFileName(
                    namespace: ProcessInfo.processInfo.environment[openComputerUseAppAgentSocketNamespaceEnvironmentKey]
                )
            )
            .standardizedFileURL
            .path
    }

    @MainActor
    private static func connectOrLaunchAgent(socketPath: String) throws -> AppAgentSocketClient {
        guard let appURL = PermissionSupport.currentAppBundleURL() else {
            throw OpenComputerUseCLIError(message: "Unable to locate Open Computer Use.app for app-scoped macOS permissions.")
        }

        // Two agents starting at the same moment must not each launch an app agent: the second one replaced
        // the first one's socket, and the two halves then worked without the shared lock. One proxy at a time
        // connects or launches; the others wait and find the agent running.
        let launchLock = open(socketPath + ".lock", O_CREAT | O_RDWR, 0o600)
        if launchLock >= 0 { flock(launchLock, LOCK_EX) }
        defer {
            if launchLock >= 0 {
                flock(launchLock, LOCK_UN)
                close(launchLock)
            }
        }

        var reachable = AppAgentSocketClient.connect(path: socketPath)
        if reachable == nil, appAgentOwnerIsRunning(socketPath: socketPath) {
            // An agent holds the owner lock but is not listening yet (still starting). Its socket is live:
            // wait for it rather than unlinking it, which would let a second agent take the path.
            let deadline = Date().addingTimeInterval(5)
            while reachable == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                reachable = AppAgentSocketClient.connect(path: socketPath)
            }
            guard reachable != nil else {
                throw OpenComputerUseCLIError(message: "Open Computer Use.app agent is still starting. Retry in a moment.")
            }
        }

        if let client = reachable {
            do {
                if try client.isCurrentAgent(for: appURL) { return client }
            } catch is AppAgentResponseTimeout {
                // Busy or wedged: never terminate an agent because it did not answer in time.
                return client
            } catch {}

            _ = try? client.request(["kind": "terminate"])
            guard client.waitForDisconnect() else {
                throw OpenComputerUseCLIError(message: "Previous app agent has not exited. Retry after its current work stops.")
            }
            unlink(socketPath)
        } else {
            unlink(socketPath)
        }

        // Never active, never hidden-to-Dock: LSUIElement keeps it out of the Dock, and these keep it
        // from taking focus or coming forward while an agent is working.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [appAgentCommand, socketPath]
        configuration.activates = false
        configuration.hides = true
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }

        // The socket usually appears within tens of milliseconds of the launch. Poll quickly at first,
        // then settle at 50 ms, instead of waiting a fixed 50 ms before every first try.
        let deadline = Date().addingTimeInterval(10)
        var delay: TimeInterval = 0.005
        while Date() < deadline {
            if let client = AppAgentSocketClient.connect(path: socketPath) {
                return client
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 0.05)
        }

        throw OpenComputerUseCLIError(message: "Timed out waiting for Open Computer Use.app agent to start.")
    }

    /// True while a running app agent holds the owner lock for `socketPath` (it holds it for its whole life).
    private static func appAgentOwnerIsRunning(socketPath: String) -> Bool {
        let fd = open(socketPath + ".owner", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // A shared lock fails only while the agent holds its exclusive owner lock.
        return flock(fd, LOCK_SH | LOCK_NB) != 0
    }

    @MainActor
    private static func proxyMCP(client initialClient: AppAgentSocketClient, socketPath: String) throws {
        var client = initialClient
        var environment = proxiedEnvironment(mcpSession: UUID())
        var canIdentifyClient = environment[cursorNameEnvironmentKey] == nil
        let requests = MCPRequestStream()
        let output = MCPLineWriter()
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                let keepReading = autoreleasepool { requests.receiveRPCLine(line, reply: output.writeLine) }
                if !keepReading { break }
            }
            requests.disconnect()
        }
        while let request = requests.next() {
            let line = request.line
            if request.cancellation.isCancelled {
                if let id = jsonRPCRequestID(line) {
                    let reply = Self.mcpFailureReply(id: id, message: "Request cancelled before dispatch. No steps ran.",
                                                     delivery: .notSent)
                    if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                        output.writeLine(data)
                    }
                }
                continue
            }
            // Reconnect only when there is another live request to serve.
            // A cancelled final call or a closed MCP client must not relaunch
            // the app agent solely to replace an unused socket.
            if client.needsReconnect {
                do { client = try connectOrLaunchAgent(socketPath: socketPath) }
                catch {
                    if let id = jsonRPCRequestID(line) {
                        let reply = Self.mcpFailureReply(id: id, message: error.localizedDescription, delivery: .notSent)
                        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                            output.writeLine(data)
                        }
                    }
                    continue
                }
            }
            if canIdentifyClient {
                canIdentifyClient = false
                environment = addingCursorClientName(to: environment, initializeLine: line)
            }

            // No run loop drains this thread's autorelease pool either: one per request.
            try autoreleasepool {
                do {
                    let response = try client.request([
                        "kind": "mcp",
                        "line": line,
                        "environment": environment,
                    ], cancellation: request.cancellation, rpcID: jsonRPCRequestID(line))

                    if let responseLine = response["response"] as? String {
                        output.writeLine(responseLine)
                    }
                } catch let timeout as AppAgentResponseTimeout {
                    // Answer this request with an error, then continue on a fresh connection: the late reply
                    // on the old one must not be read as the answer to the next request.
                    if let id = jsonRPCRequestID(line) {
                        let reply = Self.mcpFailureReply(id: id, message: timeout.errorDescription ?? "timed out",
                                                         delivery: .outcomeUnknown)
                        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                            output.writeLine(data)
                        }
                    }
                } catch let cancelled as RequestCancellation.Cancelled {
                    if let id = jsonRPCRequestID(line) {
                        let message = cancelled.deliveryState == .notSent
                            ? "Request cancelled before dispatch. No steps ran."
                            : "Request cancelled while communicating with the app agent. Inspect the current state before retrying."
                        let reply = Self.mcpFailureReply(id: id, message: message, delivery: cancelled.deliveryState)
                        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                            output.writeLine(data)
                        }
                    }
                } catch let lost as AppAgentConnectionLost {
                    if let id = jsonRPCRequestID(line) {
                        let reply = Self.mcpFailureReply(id: id, message: lost.localizedDescription, delivery: .outcomeUnknown)
                        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                            output.writeLine(data)
                        }
                    }
                }
            }
        }
    }

    /// Use a fixed product label for recognized MCP clients. Unknown client
    /// metadata stays private and falls back to a numbered cursor.
    static func knownCursorClientName(initializeLine line: String) -> String? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              message["method"] as? String == "initialize",
              let params = message["params"] as? [String: Any],
              let clientInfo = params["clientInfo"] as? [String: Any],
              let name = clientInfo["name"] as? String else { return nil }
        switch name.lowercased() {
        case "codex", "codex-cli", "codex-mcp-client", "codex-tui": return "Codex"
        case "claude-code": return "Claude Code"
        case "claude-ai", "claude-desktop": return "Claude"
        case "cursor", "cursor-vscode": return "Cursor"
        case "opencode": return "OpenCode"
        default: return nil
        }
    }

    /// Inferred client identity is a fallback, not an explicit preference. Keeping it separate
    /// lets a saved nickname take effect on the next request without reconnecting the proxy.
    static func addingCursorClientName(to environment: [String: String], initializeLine: String) -> [String: String] {
        var result = environment
        result[cursorClientNameEnvironmentKey] = knownCursorClientName(initializeLine: initializeLine)
        return result
    }

    static func mcpFailureReply(id: Any, message: String, delivery: DeliveryState) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message, "data": delivery.metadata]]
    }

    /// The `id` of a JSON-RPC request line; nil for a notification (no id, no reply expected).
    private static func jsonRPCRequestID(_ line: String) -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = object["id"], !(id is NSNull)
        else {
            return nil
        }
        return id
    }

    private static func sendCLIRequest(arguments: [String], client: AppAgentSocketClient) throws -> CLIProxyResponse {
        let response = try client.request([
            "kind": "cli",
            "arguments": resolvingOpenComputerUseCallFilePaths(arguments),
            "environment": proxiedEnvironment(),
        ])

        return CLIProxyResponse(
            stdout: response["stdout"] as? String ?? "",
            stderr: response["stderr"] as? String ?? "",
            exitCode: Int32(clamping: response["exitCode"] as? Int ?? 1)
        )
    }

    static func proxyClientID(explicit: String?, mcpSession: UUID?, parentProcessID: pid_t) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let mcpSession { return "m" + mcpSession.uuidString.lowercased() }
        return "p\(parentProcessID)"
    }

    private static func proxiedEnvironment(mcpSession: UUID? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            key.hasPrefix("OPEN_COMPUTER_USE_")
        }
        // A proxy keeps its identity across socket reconnects. CLI calls use their
        // parent so a sequence of separate calls can share the observed state.
        environment[clientEnvironmentKey] = proxyClientID(
            explicit: environment[clientEnvironmentKey], mcpSession: mcpSession, parentProcessID: getppid()
        )
        if let url = try? OCUConfiguration.fileURL(environment: OCUConfiguration.environment) {
            environment["OPEN_COMPUTER_USE_CONFIG_FILE"] = url.path
        }
        return environment
    }
}

private struct CLIProxyResponse {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

@MainActor
private final class MacOSAppAgentRuntime: NSObject, NSApplicationDelegate {
    private let socketPath: String
    private var listener: AppAgentSocketListener?
    private var turnEndedObserver: NSObjectProtocol?

    private init(socketPath: String) {
        self.socketPath = socketPath
    }

    static func run(socketPath: String) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let delegate = MacOSAppAgentRuntime(socketPath: socketPath)
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        turnEndedObserver = DistributedNotificationCenter.default().addObserver(
            forName: openComputerUseTurnEndedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // This legacy notification is unscoped. Let cursors reach their own idle deadlines
                // when several clients are active, so one turn cannot hide another client's work.
                guard ClientScope.activeCount() <= 1 else { return }
                resetOpenComputerUseBackgroundWindowState()
                resetOpenComputerUseVisualCursor()
            }
        }

        // The first action's cursor should not wait for its window and frame clock to be built.
        DispatchQueue.main.async { MainActor.assumeIsolated { prewarmOpenComputerUseVisualCursor() } }
        let idle = AgentIdleClock(idleLimit: AgentIdlePolicy.configuredIdleExitSeconds()) {
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }

        do {
            let listener = try AppAgentSocketListener(path: socketPath, idle: idle)
            self.listener = listener
            listener.start()
        } catch {
            writeAgentError(error)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        resetOpenComputerUseBackgroundWindowState()
        if let turnEndedObserver {
            DistributedNotificationCenter.default().removeObserver(turnEndedObserver)
        }
        listener?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func writeAgentError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Arms one deadline while no clients are connected. The lock orders disarm, rearm and expiry
/// against socket admissions so an expired deadline cannot stop a newly active agent.
private final class AgentIdleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: AgentIdleTimer
    private let source = DispatchSource.makeTimerSource(queue: .main)

    init(idleLimit: TimeInterval, onExit: @escaping @Sendable () -> Void) {
        timer = AgentIdleTimer(idleLimit: idleLimit, now: ProcessInfo.processInfo.systemUptime)
        schedule(now: ProcessInfo.processInfo.systemUptime)
        source.setEventHandler { [weak self] in
            if self?.expire() == true { onExit() }
        }
        source.resume()
    }

    deinit { source.cancel() }

    /// False when the agent is exiting; the caller closes the connection.
    func clientConnected() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard timer.connectedClients < AppAgentAdmission.connectionLimit,
              timer.clientConnected() else { return false }
        if timer.connectedClients == 1 { source.schedule(deadline: .distantFuture) }
        return true
    }

    func clientDisconnected() {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        timer.clientDisconnected(now: now)
        if timer.connectedClients == 0 { schedule(now: now) }
    }

    private func expire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if timer.shouldExit(now: now) { return true }
        schedule(now: now)
        return false
    }

    private func schedule(now: TimeInterval) {
        guard let delay = timer.nextExitDelay(now: now) else {
            source.schedule(deadline: .distantFuture)
            return
        }
        source.schedule(deadline: .now() + min(delay, 31_536_000), leeway: .milliseconds(500))
    }
}

private final class AppAgentSocketListener: @unchecked Sendable {
    private let path: String
    private let socketFD: Int32
    private let idle: AgentIdleClock
    private var running = true
    /// Exclusive lock on `<socket>.owner`, held until this process exits. Two agents starting together cannot both
    /// bind the path: the second finds the lock taken and exits, instead of replacing the first one's socket.
    private var ownerLock: Int32 = -1

    init(path: String, idle: AgentIdleClock) throws {
        self.path = path
        self.idle = idle
        let owner = open(path + ".owner", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard owner >= 0, flock(owner, LOCK_EX | LOCK_NB) == 0 else {
            if owner >= 0 { close(owner) }
            throw OpenComputerUseCLIError(message: "An app agent is already running on \(path).")
        }
        ownerLock = owner
        // Never take the socket from an app agent that is alive and answering.
        if let live = AppAgentSocketClient.connect(path: path) {
            _ = live
            throw OpenComputerUseCLIError(message: "An app agent is already running on \(path).")
        }
        unlink(path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        try withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            try pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer in
                let bytes = Array(path.utf8)
                guard bytes.count < pathCapacity else {
                    throw OpenComputerUseCLIError(message: "Socket path is too long: \(path)")
                }
                for index in 0..<bytes.count {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[bytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard chmod(path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            close(socketFD)
            unlink(path)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        if stat(path, &info) == 0 { boundInode = info.st_ino }
    }

    /// The socket file this agent made; `stop` removes the path only while it is still that file.
    private var boundInode: ino_t = 0

    func start() {
        Thread.detachNewThread {
            self.acceptLoop()
        }
    }

    func stop() {
        running = false
        close(socketFD)
        var info = stat()
        if stat(path, &info) == 0, info.st_ino == boundInode { unlink(path) }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else {
                if running {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continue
            }

            // A proxy that gave up on a request closes its socket; a late reply must fail with EPIPE, not raise SIGPIPE
            // and end the agent (and every other agent's work with it).
            var noSigpipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

            // Refused while the agent is exiting for idleness; the proxy relaunches it on its next call.
            guard idle.clientConnected() else {
                close(clientFD)
                continue
            }
            Thread.detachNewThread {
                defer { self.idle.clientDisconnected() }
                AppAgentConnection(fileDescriptor: clientFD).run()
            }
        }
    }
}

private final class AppAgentConnection: @unchecked Sendable {
    private let fileDescriptor: Int32
    private var server: StdioMCPServer?
    private let lockedUse: LockedUseConnection
    private var keychainProbe: LockedUseKeychainProbe?
    /// The agent this connection serves (from its proxy); nil until its first request.
    private var client: String?
    private var browserEnvironment: [String: String]?

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        lockedUse = LockedUseConnection(clientSocket: fileDescriptor)
    }

    func run() {
        // A dedicated reader can observe cancellation and EOF even during a long dispatch.
        // Use independent streams so stdio's FILE lock cannot block replies behind reads.
        let outputFD = dup(fileDescriptor)
        guard outputFD >= 0, let output = fdopen(outputFD, "w") else {
            if outputFD >= 0 { close(outputFD) }
            close(fileDescriptor)
            return
        }
        guard let input = fdopen(fileDescriptor, "r") else {
            fclose(output)
            close(fileDescriptor)
            return
        }
        _ = fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(outputFD, F_SETFD, FD_CLOEXEC)
        let requests = MCPRequestStream()
        // The pointer belongs to the reader until EOF. The worker only writes.
        let source = AppAgentLineSource(file: input)
        Thread.detachNewThread { [self] in
            source.read(into: requests, output: output)
            lockedUse.end(disconnecting: true)
        }
        defer {
            if let probe = keychainProbe { keychainProbe = nil; LockedUseDeferredCleanup.shared.retainIfNeeded(probe) }
            server?.flushTrajectory()
            // An explicitly shared identity must not detach browser tabs while
            // its other connection is performing a read.
            try? AppAgentAdmission.shared.withAdmission(.exclusive) {
                ClientScope.with(client) {
                    if let browserEnvironment {
                        AppAgentEnvironment.withConfiguration(browserEnvironment) { server?.endSession() }
                    } else {
                        server?.endSession()
                    }
                }
            }
            fclose(output)
        }

        while let request = requests.next() {
            autoreleasepool {
                let response = RequestCancellation.$current.withValue(request.cancellation) {
                    handle(requestLine: request.line)
                }
                writeAgentLine(OperationRestartNotice.attach(to: response, requestLine: request.line), to: output)
            }
        }
    }

    private func handle(requestLine: String) -> [String: Any] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        func admissionMs() -> Double { (ProcessInfo.processInfo.systemUptime - startedAt) * 1000 }
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any],
                  let kind = request["kind"] as? String
            else {
                return ["error": "Invalid app-agent request"]
            }

            switch kind {
            case "agentInfo":
                return [
                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                    "bundleURL": Bundle.main.bundleURL.standardizedFileURL.path,
                    "executableURL": Bundle.main.executableURL?.standardizedFileURL.path ?? "",
                    "processStartTime": appAgentProcessStartDate.timeIntervalSince1970,
                    "buildIdentifier": appAgentBuildIdentifier,
                ]
            case "terminate":
                // Another agent's request is still running: refuse. The proxy then reports that the old agent has not exited.
                guard ClientScope.requestsInFlight == 0 else { return ["ok": false, "busy": true] }
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
                return ["ok": true]
            case "mcp":
                let line = request["line"] as? String ?? ""
                let environment = request["environment"] as? [String: String] ?? [:]
                client = environment[clientEnvironmentKey] ?? client
                let browserEnvironment = AppAgentEnvironment.effectiveEnvironment(environment)
                self.browserEnvironment = browserEnvironment
                // Record settings belong to this MCP connection, not to the shared agent's launch environment.
                let server = self.server ?? StdioMCPServer(trajectoryEnvironment: environment, recordOperations: true)
                self.server = server
                // Handshake and listing never wait behind another agent's running tool call: a slow call
                // used to hold the lock, so the next session's initialize timed out and it started with no tools.
                let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                if let method = payload?["method"] as? String,
                   ["initialize", "notifications/initialized", "tools/list", "ping", "resources/list", "prompts/list"].contains(method) {
                    let response = ClientScope.with(client) {
                        server.handle(line: line, toolListingEnvironment: browserEnvironment)
                    }
                    return ["response": response ?? NSNull()]
                }
                let admission = AppAgentAdmission.shared
                if let payload, let client, !client.isEmpty,
                   let mode = AppAgentBrowserRead.mode(payload, client: ClientScope.sanitized(client),
                                                       allowWrites: admission.parallelTabWrites) {
                    do {
                        let response = try admission.withAdmission(mode) {
                            try ClientScope.with(client) { [lockedUse] in
                                try lockedUse.performParallelBrowserOperation {
                                    try AppAgentEnvironment.withConfiguration(
                                        browserEnvironment,
                                        validate: { try lockedUse.validateParallelBrowserOperation() }
                                    ) {
                                        if let tab = mode.tabWrite {
                                            return try withOwnedBrowserTabWrite(tab) {
                                                server.handle(line: line, admissionMs: admissionMs())
                                            }
                                        }
                                        return server.handle(line: line, admissionMs: admissionMs())
                                    }
                                }
                            }
                        }
                        return ["response": response ?? NSNull()]
                    } catch LockedUseConnection.ParallelReadFallback.needsExclusive {
                        // Nothing was sent. Let the normal serialized path handle the session.
                    } catch BrowserTabWriteNeedsExclusive.unconfirmedOwnership {
                        // Only ownership preflight can take this fallback.
                    }
                }
                let response: String? = try AppAgentEnvironment.withOverrides(environment, client: client) {
                    if payload?["method"] as? String == "notifications/turn-ended" { lockedUse.end() }
                    if let method = payload?["method"] as? String, method.hasPrefix("ocu/locked-use/keychain/") || ["ocu/locked-use/validate", "ocu/locked-use/validate-unlocked", "ocu/locked-use/validate-recovery", "ocu/locked-use/validate-unlock", "ocu/locked-use/ready", "ocu/locked-use/protection-released"].contains(method) {
                        var passed = false
                        switch method {
                        case "ocu/locked-use/ready":
                            passed = try lockedUse.observeManualUnlock()
                        case "ocu/locked-use/protection-released":
                            passed = try lockedUse.protectionReleased()
                        case "ocu/locked-use/validate-recovery":
                            passed = try lockedUse.validateRecovery()
                        case "ocu/locked-use/validate-unlock":
                            guard LockedUseSession.current().state == .locked else {
                                throw ComputerUseError.stateUnavailable("Begin unlock validation in a locked session")
                            }
                            // acquire() returns only after Root has observed
                            // the original session unlocked with fresh guards.
                            // No application, input, capture or Keychain access.
                            try lockedUse.perform {
                                guard LockedUseSession.current().state == .unlocked else {
                                    throw ComputerUseError.stateUnavailable("Protected session did not remain unlocked")
                                }
                            }
                            passed = true
                        case "ocu/locked-use/keychain/prepare", "ocu/locked-use/keychain/prepare-legacy":
                            guard LockedUseSession.current().state == .unlocked, keychainProbe == nil else { throw ComputerUseError.stateUnavailable("Prepare validation items in a normally unlocked session.") }
                            keychainProbe = try LockedUseKeychainProbe(includeDataProtection: method != "ocu/locked-use/keychain/prepare-legacy"); passed = true
                        case "ocu/locked-use/keychain/verify":
                            guard let probe = keychainProbe else { throw ComputerUseError.stateUnavailable("Prepare validation items first.") }
                            try lockedUse.perform { try probe.verify() }; passed = true
                        case "ocu/locked-use/validate-unlocked":
                            guard LockedUseSession.current().state == .unlocked, let probe = keychainProbe else {
                                throw ComputerUseError.stateUnavailable("Unshielded native fixture preflight requires a normally unlocked session.")
                            }
                            try lockedUse.perform { try LockedUseNativeValidation.run(probe: probe) }
                            passed = true
                        case "ocu/locked-use/validate":
                            guard LockedUseSession.current().state == .locked, let probe = keychainProbe else {
                                throw ComputerUseError.stateUnavailable("Begin fixed native validation from a locked session with prepared isolated Keychain items.")
                            }
                            try lockedUse.perform {
                                try LockedUseNativeValidation.run(probe: probe)
                                if probe.includesDataProtection { try lockedUse.recordValidation() }
                            }
                            passed = true
                        case "ocu/locked-use/keychain/verify-manual":
                            guard LockedUseSession.current().state == .unlocked, let probe = keychainProbe else {
                                throw ComputerUseError.stateUnavailable("Unlock normally before the final isolated Keychain check.")
                            }
                            try probe.verify()
                            if probe.includesDataProtection { try lockedUse.recordValidation(manual: true) }
                            passed = true
                        case "ocu/locked-use/keychain/cleanup":
                            passed = keychainProbe?.cleanup() ?? true
                            if passed { keychainProbe = nil }
                        default: throw ComputerUseError.message("Unknown Keychain validation operation.")
                        }
                        let result: [String: Any] = ["jsonrpc": "2.0", "id": payload?["id"] ?? NSNull(), "result": ["passed": passed, "existingItemsRead": false, "dataProtectionIncluded": keychainProbe?.includesDataProtection ?? false]]
                        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                    }
                    let parameters = payload?["params"] as? [String: Any]
                    if payload?["method"] as? String == "tools/call",
                       let name = parameters?["name"] as? String,
                       name != "list_apps", ToolDefinitions.isKnown(name) {
                        return try lockedUse.perform { server.handle(line: line, admissionMs: admissionMs()) }
                    }
                    return server.handle(line: line, admissionMs: admissionMs())
                }
                if let response {
                    return ["response": response]
                }
                return ["response": NSNull()]
            case "cli":
                let arguments = request["arguments"] as? [String] ?? []
                let environment = request["environment"] as? [String: String] ?? [:]
                let response = try AppAgentEnvironment.withOverrides(environment) {
                    let command = try parseOpenComputerUseCLI(arguments: arguments)
                    switch command {
                    case .snapshot, .call:
                        return try lockedUse.perform { runCLI(arguments: arguments) }
                    default: return runCLI(arguments: arguments)
                    }
                }
                return [
                    "stdout": response.stdout,
                    "stderr": response.stderr,
                    "exitCode": Int(response.exitCode),
                ]
            default:
                return ["error": "Unknown app-agent request kind: \(kind)"]
            }
        } catch {
            let message = (error as? RequestCancellation.Cancelled)?.deliveryState == .notSent
                ? "Request cancelled before dispatch. No steps ran."
                : (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // Preserve the native RPC id even when lease acquisition fails
            // before the MCP server runs. The stdio proxy forwards responses,
            // not the app-agent envelope's error field.
            if let envelope = try? JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any] {
                if envelope["kind"] as? String == "mcp",
                   let line = envelope["line"] as? String,
                   let rpc = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let id = rpc["id"] {
                    if error is AppAgentAdmission.Timeout, rpc["method"] as? String == "tools/call",
                       let params = rpc["params"] as? [String: Any], let tool = params["name"] as? String {
                        server?.recordAdmissionTimeout(tool: tool, elapsedMs: admissionMs())
                    }
                    let failure = MacOSAppAgentProxy.mcpFailureReply(
                        id: id, message: message, delivery: error is AppAgentAdmission.Timeout
                            ? .notSent : (error as? RequestCancellation.Cancelled)?.deliveryState ?? .outcomeUnknown
                    )
                    if let data = try? JSONSerialization.data(withJSONObject: failure) {
                        return ["response": String(decoding: data, as: UTF8.self)]
                    }
                }
                if envelope["kind"] as? String == "cli" {
                    return ["stdout": "", "stderr": message + "\n", "exitCode": Int(EXIT_FAILURE)]
                }
            }
            return ["error": message]
        }
    }

    private func runCLI(arguments: [String]) -> CLIProxyResponse {
        do {
            let command = try parseOpenComputerUseCLI(arguments: arguments)

            switch command {
            case .launchOnboarding:
                let permissions = PermissionDiagnostics.current()
                if !permissions.allGranted {
                    Task { @MainActor in
                        PermissionOnboardingApp.present()
                    }
                }
                return CLIProxyResponse(stdout: "", stderr: "", exitCode: EXIT_SUCCESS)

            case let .doctor(json):
                // Report only. Agents run `doctor` after a permission error; it must never open
                // onboarding windows mid-task. The user grants permissions by opening GODSPEED.app.
                let permissions = PermissionDiagnostics.current()
                var text = try json ? permissions.jsonText() : permissions.summary + "\n" + LockedUseDiagnostics.current().summary
                if !json && !permissions.allGranted {
                    text += "\nOpen GODSPEED.app yourself to grant the missing permissions."
                }
                return CLIProxyResponse(stdout: text + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .lockedUseStatus(json):
                let diagnostics = LockedUseDiagnostics.current()
                return CLIProxyResponse(stdout: (try json ? diagnostics.jsonText() : diagnostics.summary) + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case .listApps:
                let service = ComputerUseService()
                return CLIProxyResponse(stdout: (service.listApps().primaryText ?? "") + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .snapshot(app, textLimit, treeLimits, observation):
                let service = ComputerUseService()
                let text = try service.getAppState(app: app, textLimit: textLimit, treeLimits: treeLimits, observation: observation).textContent
                return CLIProxyResponse(stdout: text + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .call(invocation):
                let output = try withOperationJournal { try runOpenComputerUseCall(invocation) }
                return CLIProxyResponse(
                    stdout: try output.jsonText() + "\n",
                    stderr: "",
                    exitCode: output.hasToolError ? EXIT_FAILURE : EXIT_SUCCESS
                )

            default:
                return CLIProxyResponse(stdout: "", stderr: "Unsupported proxied command.\n", exitCode: EXIT_FAILURE)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return CLIProxyResponse(stdout: "", stderr: message + "\n", exitCode: EXIT_FAILURE)
        }
    }
}

/// The environment key that names the agent a proxy works for.
private let clientEnvironmentKey = "OPEN_COMPUTER_USE_CLIENT"
private let cursorNameEnvironmentKey = "OPEN_COMPUTER_USE_CURSOR_NAME"
private let cursorClientNameEnvironmentKey = "OPEN_COMPUTER_USE_CURSOR_CLIENT_NAME"

/// Match only canonical requests. Batches and actions with shared side
/// effects use exclusive admission.
enum AppAgentBrowserRead {
    private static let common: Set<String> = ["action", "tab_id"]
    private static let arguments: [String: Set<String>] = [
        "read": common.union(["find", "full", "interactive", "diff", "include_link_urls"]),
        "screenshot": common.union(["if_changed"]),
        "location": common,
        "info": common,
        "outline": common,
        "frames": common,
        "read_text": common.union(["label", "index", "element_index"]),
        "link_destination": common.union(["label", "index", "element_index"]),
        "control_state": common.union(["label", "index", "element_index"]),
        "value": common.union(["label", "index", "element_index"]),
        "wait_for": common.union(["text", "label", "url_contains", "condition", "timeout"]),
        "tabs": ["action"],
        "peek": ["action", "urls"],
    ]

    static func mode(_ payload: [String: Any], client: String, allowWrites: Bool) -> AppAgentAdmission.Mode? {
        guard payload["method"] as? String == "tools/call",
              let params = payload["params"] as? [String: Any], params["name"] as? String == "browser",
              let args = params["arguments"] as? [String: Any], let action = args["action"] as? String else { return nil }
        if accepts(payload) {
            return action == "peek" ? .browserPeek(client: client) : .browserRead(client: client)
        }
        guard allowWrites, let tab = args["tab_id"] as? NSNumber,
              CFGetTypeID(tab) != CFBooleanGetTypeID(), tab.intValue > 0,
              tab.compare(NSNumber(value: tab.intValue)) == .orderedSame else { return nil }
        switch action {
        case "scroll":
            guard Set(args.keys).isSubset(of: common.union(["direction", "amount", "label", "index", "element_index"])) else { return nil }
        case "fill_field":
            guard Set(args.keys).isSubset(of: common.union(["label", "text"])),
                  let text = args["text"] as? String, !text.isEmpty,
                  let label = args["label"] as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
        default: return nil
        }
        return .browserTabWrite(client: client, tabID: tab.intValue)
    }

    static func accepts(_ payload: [String: Any]) -> Bool {
        guard payload["method"] as? String == "tools/call",
              let params = payload["params"] as? [String: Any], params["name"] as? String == "browser",
              let requested = params["arguments"] as? [String: Any], let action = requested["action"] as? String,
              let allowed = arguments[action] else { return false }
        guard requested.keys.allSatisfy(allowed.contains) else { return false }
        if action == "wait_for" {
            // A long wait would hold an admission slot ahead of desktop work.
            guard let seconds = requested["timeout"] as? Int, (1...3).contains(seconds) else { return false }
        }
        return true
    }
}

enum AppAgentEnvironment {
    private static let requestEnvironmentKeys = OCUConfiguration.environmentKeys.union([
        "OPEN_COMPUTER_USE_BROWSER", "OPEN_COMPUTER_USE_OBU_BIN",
        "OPEN_COMPUTER_USE_BROWSER_SESSION", "OPEN_COMPUTER_USE_BROWSER_PROFILE",
        "OPEN_COMPUTER_USE_BROWSER_APP", "OPEN_COMPUTER_USE_BROWSER_TRACE",
    ])

    static func withOverrides<T>(_ overrides: [String: String], client: String? = nil, _ body: () throws -> T) throws -> T {
        try AppAgentAdmission.shared.withAdmission(.exclusive) {
            try ClientScope.with(client ?? overrides[clientEnvironmentKey]) {
                try withConfiguration(effectiveEnvironment(overrides), body)
            }
        }
    }

    static func withConfiguration<T>(
        _ environment: [String: String],
        validate: (@Sendable () throws -> Void)? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        try RequestConfiguration.withEnvironment(environment) {
            try withBrowserRequestEnvironment(environment, validate: validate, body)
        }
    }

    static func effectiveEnvironment(_ overrides: [String: String]) -> [String: String] {
        effectiveEnvironment(overrides, launchEnvironment: appAgentLaunchEnvironment)
    }

    static func effectiveEnvironment(_ overrides: [String: String], launchEnvironment: [String: String]) -> [String: String] {
        var environment = launchEnvironment
        for key in requestEnvironmentKeys { environment[key] = nil }
        return environment.merging(overrides.filter { $0.key.hasPrefix("OPEN_COMPUTER_USE_") }) { _, request in request }
    }

}

/// The app agent did not answer in time. The call is stopped; the agent and its other work are left running.
struct AppAgentResponseTimeout: LocalizedError {
    var errorDescription: String? {
        "Open Computer Use.app did not answer within \(Int(AppAgentSocketClient.responseTimeout)) seconds. The action may have taken effect. Inspect the current state before retrying."
    }
}

struct AppAgentConnectionLost: LocalizedError {
    var errorDescription: String? {
        "Open Computer Use.app agent closed the connection. The action may have taken effect. Inspect the current state before retrying."
    }
}

/// A cancellation can arrive while stdio is still flushing the request. Sending
/// a cancellation frame then would splice it into the request, so interrupt
/// that connection instead. After a complete flush the normal RPC cancellation
/// can use the same connection without discarding later queued work.
private final class AppAgentSocketCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private let envelope: Data?
    private var frameSent = false
    private var interrupted = false

    init(descriptor: Int32, envelope: Data?) {
        self.descriptor = descriptor
        self.envelope = envelope
    }

    var interruptedConnection: Bool { lock.withLock { interrupted } }

    func didSendFrame() { lock.withLock { frameSent = true } }

    func cancel(disconnected: Bool) {
        lock.withLock {
            if !disconnected, frameSent, let envelope {
                let count = envelope.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
                if count == envelope.count { return }
            }
            interrupted = true
            shutdown(descriptor, SHUT_RDWR)
        }
    }
}

final class AppAgentSocketClient: @unchecked Sendable {
    private let file: UnsafeMutablePointer<FILE>
    private let descriptor: Int32

    init(file: UnsafeMutablePointer<FILE>) {
        self.file = file
        descriptor = fileno(file)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        fclose(file)
    }

    static func connect(path: String) -> AppAgentSocketClient? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer -> Bool in
                let bytes = Array(path.utf8)
                guard bytes.count < pathCapacity else {
                    return false
                }
                for index in 0..<bytes.count {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[bytes.count] = 0
                return true
            }
        }

        guard copied else {
            close(fd)
            return nil
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, let file = fdopen(fd, "r+") else {
            close(fd)
            return nil
        }

        // A hung agent must not hold the caller forever.
        var timeout = timeval(tv_sec: Int(responseTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        return AppAgentSocketClient(file: file)
    }

    /// Seconds one request waits for an answer before its connection is closed.
    /// Other clients of the shared agent remain connected.
    static let responseTimeout: TimeInterval = 120

    /// An interrupted/closed stream cannot be reused: a late or partial reply
    /// must never become the answer to a later request.
    private(set) var needsReconnect = false

    private func invalidateConnection() {
        needsReconnect = true
        // Signal the reader immediately, so its active worker is cancelled
        // even when no later MCP request arrives to replace this client.
        shutdown(descriptor, SHUT_RDWR)
    }

    func request(
        _ object: [String: Any], cancellation: RequestCancellation? = nil, rpcID: Any? = nil
    ) throws -> [String: Any] {
        if needsReconnect { throw AppAgentConnectionLost() }
        if cancellation?.isCancelled == true { throw RequestCancellation.Cancelled(deliveryState: .notSent) }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let line = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode app-agent request.")
        }
        if cancellation?.isCancelled == true { throw RequestCancellation.Cancelled(deliveryState: .notSent) }

        let cancellationState = AppAgentSocketCancellation(descriptor: descriptor, envelope: Self.cancellationEnvelope(id: rpcID))
        cancellation?.onCancel { disconnected in cancellationState.cancel(disconnected: disconnected) }
        defer {
            // onCancel(nil) waits for an in-flight callback before the file can
            // be reused or closed, then exposes its final transport state.
            cancellation?.onCancel(nil)
            if cancellationState.interruptedConnection { invalidateConnection() }
        }
        if cancellation?.isCancelled == true { throw RequestCancellation.Cancelled(deliveryState: .notSent) }
        guard writeAgentLine(line, to: file) else {
            invalidateConnection()
            if cancellation?.isCancelled == true { throw RequestCancellation.Cancelled(deliveryState: .outcomeUnknown) }
            throw AppAgentConnectionLost()
        }
        cancellationState.didSendFrame()

        let responseLine = readAgentLine(file)
        // A read that hit the timeout returns what arrived so far (possibly a partial line): check it before using it.
        if ferror(file) != 0, errno == EAGAIN || errno == EWOULDBLOCK {
            invalidateConnection()
            throw AppAgentResponseTimeout()
        }

        guard let responseLine,
              let response = try? JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any]
        else {
            invalidateConnection()
            if cancellation?.isCancelled == true { throw RequestCancellation.Cancelled(deliveryState: .outcomeUnknown) }
            throw AppAgentConnectionLost()
        }

        if let error = response["error"] as? String {
            throw ComputerUseError.message(error)
        }

        return response
    }

    private static func cancellationEnvelope(id: Any?) -> Data? {
        guard let id,
              let rpc = try? JSONSerialization.data(withJSONObject: [
                  "jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id],
              ]),
              let envelope = try? JSONSerialization.data(withJSONObject: [
                  "kind": "mcp", "line": String(decoding: rpc, as: UTF8.self),
              ]) else { return nil }
        return envelope + Data([10])
    }

    func waitForDisconnect() -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var byte: UInt8 = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = recv(fileno(file), &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 { return true }
            if count < 0, ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func isCurrentAgent(for appURL: URL) throws -> Bool {
        let response = try request(["kind": "agentInfo"])
        let expectedBundleURL = appURL.standardizedFileURL

        guard response["bundleURL"] as? String == expectedBundleURL.path else {
            return false
        }

        if let expectedBuild = Bundle(url: expectedBundleURL)?.object(forInfoDictionaryKey: "OpenComputerUseBuildIdentifier") as? String,
           !expectedBuild.isEmpty, response["buildIdentifier"] as? String != expectedBuild { return false }

        guard let processStartTime = response["processStartTime"] as? TimeInterval else {
            return false
        }

        guard let executableURL = executableURL(for: expectedBundleURL),
              let modifiedAt = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else {
            return true
        }

        return processStartTime + 0.5 >= modifiedAt.timeIntervalSince1970
    }

    private func executableURL(for appURL: URL) -> URL? {
        guard let bundle = Bundle(url: appURL),
              let executableName = bundle.object(forInfoDictionaryKey: kCFBundleExecutableKey as String) as? String,
              !executableName.isEmpty
        else {
            return nil
        }

        return appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
            .standardizedFileURL
    }
}

private final class AppAgentLineSource: @unchecked Sendable {
    private let file: UnsafeMutablePointer<FILE>

    init(file: UnsafeMutablePointer<FILE>) { self.file = file }

    func read(into requests: MCPRequestStream, output: UnsafeMutablePointer<FILE>) {
        defer { fclose(file) }
        while let line = readAgentLine(file) {
            let intake = autoreleasepool {
                let envelope = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                let rpc = envelope?["kind"] as? String == "mcp" ? envelope?["line"] as? String : nil
                return requests.intake(line, rpcLine: rpc)
            }
            switch intake {
            case .accepted:
                continue
            case .busy:
                // Refuse this request only. The active request keeps running and the connection stays open.
                if let reply = MCPRequestStream.busyEnvelope(for: line) { writeAgentLine(reply, to: output) }
            case .closed:
                shutdown(fileno(file), SHUT_RDWR)
                requests.disconnect()
                return
            }
        }
        requests.disconnect()
    }
}

private func readAgentLine(_ file: UnsafeMutablePointer<FILE>) -> String? {
    var bytes: [UInt8] = []

    while true {
        let character = fgetc(file)
        if character == EOF {
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
        if character == 10 {
            // Lossy decode: a bad byte makes that request fail with an error reply, not end the connection.
            return String(decoding: bytes, as: UTF8.self)
        }
        bytes.append(UInt8(character))
    }
}

private func writeAgentLine(_ object: [String: Any], to file: UnsafeMutablePointer<FILE>) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
       let line = String(data: data, encoding: .utf8)
    {
        writeAgentLine(line, to: file)
    }
}

@discardableResult
private func writeAgentLine(_ line: String, to file: UnsafeMutablePointer<FILE>) -> Bool {
    let output = line + "\n"
    let written = output.withCString { pointer in fputs(pointer, file) != EOF }
    return written && fflush(file) == 0
}
