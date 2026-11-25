import Foundation

let computerUseServerInstructions = """
Use Godspeed for Mac apps and Chrome.

- Start with the outcome. For a familiar workflow, use batch with app, the exact saved goal and current values to replay a verified recipe. For known steps, use one batch with done_when and compact:true. A verified receipt is enough to finish.
- For a bounded Mac task with a concrete final check but unknown steps, use handoff with app, goal, done_when and any text values. It reads and acts locally. If it stops, use its receipt and continue only the remaining work.
- Keep a stopped batch's token across context resets. Use batch with inspect_resume to recover compact progress, then resume only eligible unsent steps with fresh values. Inspection does not execute or consume the checkpoint.
- For a single action, use its tool. Use query or compact get_app_state to identify controls and browser find for web controls. Request screenshots when needed.
- Keep work in the background. Check uncertain delivery before retrying. Sending, deleting or purchasing needs user authorization; honor authorization already given for this task.
"""

public final class StdioMCPServer {
    private static let diffableNativeActions: Set<String> = [
        "click", "set_value", "type_text", "press_key", "press_menu", "scroll"
    ]

    private let service: ComputerUseService
    private let dispatcher: ComputerUseToolDispatcher
    private let backgroundStateReset: () -> Void
    /// Per-connection record of top-level tool calls.
    private let trajectory: TrajectoryLog
    private let recordOperations: Bool

    public convenience init(
        service: ComputerUseService = ComputerUseService(),
        backgroundStateReset: @escaping () -> Void = resetOpenComputerUseBackgroundWindowState,
        trajectoryEnvironment: [String: String]? = nil,
        recordOperations: Bool = false
    ) {
        self.init(dispatcher: ComputerUseToolDispatcher(service: service), backgroundStateReset: backgroundStateReset,
                  trajectoryEnvironment: trajectoryEnvironment, recordOperations: recordOperations)
    }

    init(dispatcher: ComputerUseToolDispatcher,
         backgroundStateReset: @escaping () -> Void = resetOpenComputerUseBackgroundWindowState,
         trajectoryEnvironment: [String: String]? = nil, recordOperations: Bool = false,
         trajectoryLog: TrajectoryLog? = nil) {
        self.recordOperations = recordOperations
        self.service = dispatcher.service
        self.dispatcher = dispatcher
        self.backgroundStateReset = backgroundStateReset
        // App-agent callers supply a raw per-connection environment. Fill saved preferences
        // underneath it too, so the terminal's telemetry switch applies to proxied sessions.
        self.trajectory = trajectoryLog ?? TrajectoryLog(environment: GodspeedSettings.merged(trajectoryEnvironment ?? RequestConfiguration.environment))
    }

    public func run() throws {
        defer { endSession() }
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
            autoreleasepool {
                RequestCancellation.$current.withValue(request.cancellation) {
                    if let response = withOperationJournal({ handle(line: request.line) }) {
                        output.writeLine(response)
                    }
                }
            }
        }
    }

    public func handle(line: String, toolListingEnvironment: [String: String]? = nil, admissionMs: Double? = nil) -> String? {
        var id: Any?
        do {
            guard let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return try encodeJSONRPCError(id: nil, code: -32700, message: "Invalid JSON-RPC payload")
            }

            let method = payload["method"] as? String
            id = payload["id"]
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "protocolVersion": "2025-03-26",
                        "serverInfo": [
                            "name": "godspeed",
                            "version": resolvedOpenComputerUseVersion(),
                        ],
                        "capabilities": [
                            "tools": [
                                "listChanged": false,
                            ],
                        ],
                        "instructions": computerUseServerInstructions,
                    ],
                    stableOrder: true
                )
            case "notifications/initialized", "notifications/cancelled":
                return nil
            case "notifications/turn-ended":
                endSession()
                return nil
            case "ping":
                return try encodeJSONRPCResult(id: id, result: [:])
            case "tools/list":
                let definitions = toolListingEnvironment.map(ToolDefinitions.available(environment:)) ?? ToolDefinitions.all
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "tools": definitions.map(\.asDictionary),
                    ],
                    stableOrder: true
                )
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let startedAt = Date()
                let telemetry = ToolTelemetry()
                let result: ToolCallResult
                do {
                    let call = { try self.dispatcher.callTool(name: name, arguments: arguments) }
                    result = try ToolTelemetry.$current.withValue(telemetry) {
                        try recordOperations ? withOperationJournal(call) : call()
                    }
                } catch {
                    let reply = telemetry.reply(ToolCallResult.failure(error))
                    trajectory.recordFailedToolCall(name: name, arguments: arguments, error: error, startedAt: startedAt,
                                                    admissionMs: admissionMs, telemetry: telemetry.snapshot())
                    return try encodeJSONRPCResult(id: id, result: reply)
                }
                // Keep the full baseline locally. Only shorten the transport reply,
                // after the dispatcher has finished its readback and delivery checks.
                var reply = result
                if name != BatchTool.name, !result.isError,
                   let app = arguments["app"] as? String, let state = LeanOutput.stateText(of: result) {
                    let memory = BatchObservationMemory.shared
                    if LeanOutput.usesCompactReads, Self.diffableNativeActions.contains(name),
                       !result.content.contains(where: { $0.dictionary["type"] as? String == "image" }) {
                        reply = LeanOutput.diffed(result, previous: memory.shownText(app: app))
                    }
                    memory.recordShown(app: app, text: state)
                }
                let response = telemetry.reply(reply)
                trajectory.recordToolCall(name: name, arguments: arguments, result: result, startedAt: startedAt,
                                          admissionMs: admissionMs, telemetry: telemetry.snapshot())
                return try encodeJSONRPCResult(id: id, result: response)
            default:
                // A notification (no id) gets no reply. A request without a usable method must still get one,
                // or the client waits forever for a response that never comes.
                if method == nil {
                    guard id != nil else { return nil }
                    return try encodeJSONRPCError(id: id, code: -32600, message: "Invalid Request: missing method")
                }

                return try encodeJSONRPCError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
            }
        } catch {
            return try? encodeJSONRPCResult(id: id, result: ToolCallResult.failure(error).asDictionary)
        }
    }

    /// Release state that is scoped to one MCP client session. App-hosted MCP
    /// connections call this explicitly because they use `handle(line:)`
    /// instead of the stdio `run()` loop.
    public func recordAdmissionTimeout(tool: String, elapsedMs: Double) {
        trajectory.recordAdmissionTimeout(name: tool, admissionMs: elapsedMs)
    }

    public func flushTrajectory() {
        trajectory.sessionEnded()
    }

    public func endSession() {
        trajectory.sessionEnded()
        service.clearQueryIndexes()
        service.clearSnapshotRefs()
        BrowserBridge.endClientTurn()
        // The cursor is deliberately left alone here. One `ocu call` is one session, so
        // resetting it made every step of a batch start a new cursor from scratch. The
        // idle timer hides it shortly after the last action, and `turn-ended` clears it at once.
        // Window state (pins, parked windows) is shared by every agent on this Mac: it is not reset under
        // another agent that is working right now. That agent's own turn end resets it.
        if !ClientScope.othersActive() { backgroundStateReset() }
    }

    private func encodeJSONRPCResult(id: Any?, result: [String: Any], stableOrder: Bool = false) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ], stableOrder: stableOrder)
    }

    private func encodeJSONRPCError(id: Any?, code: Int, message: String) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private func encode(_ object: [String: Any], stableOrder: Bool = false) throws -> String {
        let options: JSONSerialization.WritingOptions = stableOrder
            ? [.withoutEscapingSlashes, .sortedKeys] : [.withoutEscapingSlashes]
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode JSON-RPC response.")
        }

        return text
    }
}
