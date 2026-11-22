import Foundation

/// Typed local scoring. A result is advice, with no path from a score to input dispatch.
enum LocalDecisionTool {
    static let name = "local_decision"
    static let roles = ["action", "read", "recover"]
    private static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ocu-referee")
    private static let starter = HelperAutoStarter(launcher: directory.appendingPathComponent("run_gsd1.sh"),
                                                   log: directory.appendingPathComponent("gsd1-service.log"),
                                                   restartLocalScorer: true)

    static func baseURL(environment: [String: String] = GodspeedSettings.environment) -> URL? {
        guard let raw = environment["OPEN_COMPUTER_USE_GSD1_URL"], let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              HelperAutoStarter.isLoopback(url), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func run(arguments: [String: Any], baseURL: URL?,
                    score: (URL, [String: Any], TimeInterval) -> [String: Any]? = {
                        HelperHTTP.postJSON($0, body: $1, timeout: $2, followRedirects: false)
                    }) throws -> ToolCallResult {
        guard let baseURL, HelperAutoStarter.isLoopback(baseURL) else {
            throw ComputerUseError.invalidArguments("Configure the loopback GSD1 helper first.")
        }
        guard let role = arguments["role"] as? String, roles.contains(role),
              let state = arguments["state"], state is [String: Any] || state is String,
              let question = arguments["question"] as? [String: Any], question["type"] as? String == "choice",
              let instructions = question["instructions"] as? String, !instructions.isEmpty,
              let options = question["criteria"] as? [String: String], (2...15).contains(options.count),
              options.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
            throw ComputerUseError.invalidArguments("Give a role, observed state and a choice question with 2 to 15 named options.")
        }
        let body: [String: Any] = ["role": role, "state": state, "question": [
            "type": "choice", "instructions": instructions, "criteria": options
        ]]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64 * 1024 else {
            throw ComputerUseError.invalidArguments("The typed decision must fit within 64 KiB.")
        }
        let metricPrefix = "gsd1_" + role
        let telemetry = ToolTelemetry.current
        let deadline = BrowserCallBudget.activeRemaining ?? 8
        guard deadline > 0.25 else {
            telemetry?.add("\(metricPrefix)_skipped_deadline")
            return .text("No local recommendation. The request deadline is too close.", deliveryState: .notSent)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let reply = score(baseURL.appendingPathComponent("gsd1").appendingPathComponent("score"), body, min(deadline, 8))
        telemetry?.recordHelper(metricPrefix, startedAt: start, image: false, reply: reply)
        if reply == nil, baseURL.port == 18765 { starter.helperUnreachable(baseURL) }
        guard let reply, reply["model"] as? String == "gsd1-" + role,
              let probabilities = Referee.parseChoose(reply),
              Set(probabilities.keys) == Set(options.keys) else {
            if reply == nil {
                telemetry?.add("\(metricPrefix)_unavailable")
            } else if reply?[HelperHTTP.busyResponseKey] as? Bool == true {
                telemetry?.add("\(metricPrefix)_busy")
            } else {
                telemetry?.add("\(metricPrefix)_invalid_scores")
            }
            return .text("No local recommendation. The helper was busy, unavailable or returned invalid scores.", deliveryState: .notSent)
        }
        let ranked = probabilities.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        guard let first = ranked.first, first.value >= HandoffTool.minProbability,
              first.value - (ranked.dropFirst().first?.value ?? 0) >= HandoffTool.minMargin else {
            telemetry?.add("\(metricPrefix)_abstained")
            return .text("No clear local recommendation. Check the current evidence.", deliveryState: .notSent)
        }
        telemetry?.add("\(metricPrefix)_suggested")
        return .text("GSD1 \(role) suggests \(first.key) (\(HandoffTool.percent(first.value))).",
                     deliveryState: .notSent)
    }
}
