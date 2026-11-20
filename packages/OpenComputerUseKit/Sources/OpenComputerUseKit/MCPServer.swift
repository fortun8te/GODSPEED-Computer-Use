import Foundation

let computerUseServerInstructions = """
Use Godspeed for Mac apps and Chrome. Keep actions in the background.

- Mac: compact get_app_state, then batch known actions with an observable done_when. For one step, use its tool. Use unique labels or fresh indexes.
- Web: browser in its own tab. Use interactive or find to narrow a read. Request screenshots for visual targets that need them.
- Verify against the result. Model hints are advisory. After a partial failure, read fresh state before retrying uncertain steps. Use receipt.recovery to resume.
- Use handoff for bounded subtasks and remember only verified reusable batches. Use the private clipboard across apps. Ask before sending, deleting, or purchasing.
"""

public final class StdioMCPServer {
    private let service: ComputerUseService
    private let dispatcher: ComputerUseToolDispatcher
    private let backgroundStateReset: () -> Void
    /// Per-connection record of top-level tool calls.
    private let trajectory: TrajectoryLog

    public init(
        service: ComputerUseService = ComputerUseService(),
        backgroundStateReset: @escaping () -> Void = resetOpenComputerUseBackgroundWindowState,
        trajectoryEnvironment: [String: String]? = nil
    ) {
        self.service = service
        self.dispatcher = ComputerUseToolDispatcher(service: service)
        self.backgroundStateReset = backgroundStateReset
        self.trajectory = TrajectoryLog(environment: trajectoryEnvironment ?? GodspeedSettings.environment)
    }

    public func run() throws {
        defer { endSession() }
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            // This thread's autorelease pool never drains on its own: each response's encoded
            // bytes (a screenshot's base64 among them) stayed alive for the whole session.
            autoreleasepool {
                if let response = handle(line: line) {
                    FileHandle.standardOutput.write((response + "\n").data(using: .utf8)!)
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
                    ]
                )
            case "notifications/initialized":
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
                    ]
                )
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let startedAt = Date()
                let result: ToolCallResult
                do {
                    result = try dispatcher.callTool(name: name, arguments: arguments)
                } catch {
                    trajectory.recordFailedToolCall(name: name, arguments: arguments, error: error, startedAt: startedAt, admissionMs: admissionMs)
                    throw error
                }
                trajectory.recordToolCall(name: name, arguments: arguments, result: result, startedAt: startedAt, admissionMs: admissionMs)
                // Remember the state the model was shown, so the next batch can reply with only the changes.
                if name != BatchTool.name, let app = arguments["app"] as? String, let state = LeanOutput.stateText(of: result) {
                    BatchObservationMemory.shared.recordShown(app: app, text: state)
                }
                return try encodeJSONRPCResult(
                    id: id,
                    result: result.asDictionary
                )
            default:
                // A notification (no id) gets no reply. A request without a usable method must still get one,
                // or the client waits forever for a response that never comes.
                if method == nil {
                    guard id != nil else { return nil }
                    return try encodeJSONRPCError(id: id, code: -32600, message: "Invalid Request: missing method")
                }

                return try encodeJSONRPCError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
            }
        } catch let error as ComputerUseError {
            let result = ToolCallResult.text(error.errorDescription ?? String(describing: error), isError: error.toolResultIsError)
            return try? encodeJSONRPCResult(id: id, result: result.asDictionary)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return try? encodeJSONRPCResult(
                id: id,
                result: [
                    "content": [
                        [
                            "type": "text",
                            "text": message,
                        ],
                    ],
                    "isError": true,
                ]
            )
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
        BrowserBridge.endClientTurn()
        // The cursor is deliberately left alone here. One `ocu call` is one session, so
        // resetting it made every step of a batch start a new cursor from scratch. The
        // idle timer hides it shortly after the last action, and `turn-ended` clears it at once.
        // Window state (pins, parked windows) is shared by every agent on this Mac: it is not reset under
        // another agent that is working right now. That agent's own turn end resets it.
        if !ClientScope.othersActive() { backgroundStateReset() }
    }

    private func encodeJSONRPCResult(id: Any?, result: [String: Any]) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ])
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

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode JSON-RPC response.")
        }

        return text
    }
}
