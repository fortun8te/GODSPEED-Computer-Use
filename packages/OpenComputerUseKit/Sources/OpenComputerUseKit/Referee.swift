import Foundation

/// Optional local referee: a small decision model served on this Mac (see ~/.ocu-referee) that reads
/// a batch's goal, last step, result and the new state and answers act / look_again / done / stuck.
///
/// Off unless `OPEN_COMPUTER_USE_REFEREE_URL` is set (for example `http://127.0.0.1:8765`). Its answer
/// becomes one hint line in the batch reply; it never changes what OCU does. A slow, missing or broken
/// referee just leaves the line out, so the batch reply is never delayed past the timeout.
enum Referee {
    struct Verdict: Sendable {
        let label: String
        let confidence: Double
        let milliseconds: Int
    }

    static let baseURL: URL? = {
        guard let raw = environment("OPEN_COMPUTER_USE_REFEREE_URL"), !raw.isEmpty else { return nil }
        // Without a scheme and host ("127.0.0.1:8765") URL(string:) gives a URL no request can use.
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }()

    /// Longest the batch waits for an answer. Default 1500 ms: a warm d1-2B (fp16) answers a 1,000-character
    /// view in about 270 ms; a cold one reloads for about 4 s and is skipped.
    static let timeout: TimeInterval = {
        let milliseconds = environment("OPEN_COMPUTER_USE_REFEREE_TIMEOUT_MS").flatMap(Double.init) ?? 1_500
        return max(50, milliseconds) / 1000
    }()

    /// Hints below this confidence are left out. Default 0.6.
    static let minimumConfidence: Double = {
        environment("OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE").flatMap(Double.init) ?? 0.6
    }()

    /// "done" hints need at least this confidence. Default 0.86: the lowest value at which the d1-2B
    /// done answers on the eval2 dev split were all right (9 of 9; 0.85 gave 10 of 11). Chosen on dev only.
    static let doneConfidence: Double = {
        environment("OPEN_COMPUTER_USE_REFEREE_DONE_CONFIDENCE").flatMap(Double.init) ?? 0.86
    }()

    /// The state text sent is cut to this many characters. Default 1200: longer views were slower and
    /// less accurate in the d1-2B measurements (~270 ms at 1,000 characters, ~1.1 s at 6,000).
    static let maxViewCharacters: Int = {
        environment("OPEN_COMPUTER_USE_REFEREE_MAX_VIEW").flatMap(Int.init) ?? 1_200
    }()

    static var isEnabled: Bool { baseURL != nil }

    /// Asks the helper about one batch. `summary` is the short RefereeSummary text (goal, steps, repeated
    /// failures, screen change, dialog, changed lines), not raw screen text.
    static func decide(goal: String, lastStep: String, result: String, summary: String) -> Verdict? {
        guard let baseURL else { return nil }

        let body: [String: Any] = [
            "goal": goal,
            "last_step": lastStep,
            "result": result,
            "view": String(summary.prefix(maxViewCharacters)),
        ]
        guard let object = HelperHTTP.postJSON(baseURL.appendingPathComponent("decide"), body: body, timeout: timeout) else {
            HelperAutoStarter.shared.helperUnreachable(baseURL)
            return nil
        }
        guard let label = object["label"] as? String else { return nil }
        return Verdict(
            label: label,
            confidence: (object["confidence"] as? NSNumber)?.doubleValue ?? 0,
            milliseconds: (object["ms"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// Longest a handoff waits for the helper to score its candidate actions. Default 3000 ms (a cold d1 is
    /// skipped; the retry below usually finds it warm).
    static let chooseTimeout: TimeInterval = {
        let milliseconds = environment("OPEN_COMPUTER_USE_REFEREE_CHOOSE_TIMEOUT_MS").flatMap(Double.init) ?? 3_000
        return max(100, milliseconds) / 1000
    }()

    /// Asks the helper to score candidate actions for a handoff (POST /choose): one probability per option id
    /// plus "none". Nil when the referee is off, down or answers badly, so the handoff escalates instead of guessing.
    /// The handoff needs the helper even when batch hints are off, so it falls back to the default local helper.
    static let chooseURL: URL? = baseURL ?? {
        if let off = environment("OPEN_COMPUTER_USE_HANDOFF_HELPER"), ["0", "false", "off", "no"].contains(off.lowercased()) { return nil }
        return URL(string: "http://127.0.0.1:8765")
    }()

    static func choose(goal: String, doneWhen: String, history: String, screen: String, options: [(id: String, text: String)]) -> [String: Double]? {
        guard let baseURL = chooseURL, !options.isEmpty else { return nil }
        let body: [String: Any] = [
            "goal": goal,
            "done_when": doneWhen,
            "history": history,
            "screen": String(screen.prefix(maxViewCharacters)),
            "options": options.map { ["id": $0.id, "text": $0.text] },
        ]
        guard let object = HelperHTTP.postJSON(baseURL.appendingPathComponent("choose"), body: body, timeout: chooseTimeout) else {
            HelperAutoStarter.shared.helperUnreachable(baseURL)
            return nil
        }
        return parseChoose(object)
    }

    /// `{"probs": {"a": 0.7, "none": 0.1}}` as a dictionary; nil when it has no usable numbers.
    static func parseChoose(_ object: [String: Any]) -> [String: Double]? {
        guard let raw = object["probs"] as? [String: Any] else { return nil }
        var probs: [String: Double] = [:]
        for (key, value) in raw {
            guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number >= 0, number <= 1 else { continue }
            probs[key] = number
        }
        return probs.isEmpty ? nil : probs
    }

    /// The hint line for a verdict, or nil when it is not worth the model's attention.
    static func hint(for verdict: Verdict) -> String? {
        guard verdict.confidence >= minimumConfidence else { return nil }
        let sure = "\(Int((verdict.confidence * 100).rounded()))% sure"
        switch verdict.label {
        case "done":
            // A wrong "done" is worse than none (it was right 14 of 30 times above 0.6 on a harder set),
            // so it needs much more confidence, and the model must confirm it.
            guard verdict.confidence >= doneConfidence else { return nil }
            return "Check: the goal may be reached (\(sure)). Confirm it in the state below before you stop."
        case "stuck":
            return "Check: this looks stuck (\(sure)). Try a different element or approach, or ask the user."
        case "look_again":
            return "Check: the state may be stale or still loading (\(sure)). Read it again with get_app_state and settle_ms before acting."
        default:
            // "act": nothing to add; the model was going to continue anyway.
            return nil
        }
    }

    private static func environment(_ key: String) -> String? {
        GodspeedSettings.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The one synchronous HTTP path to the local helper service (referee and vision fallback share it).
/// Every failure (connection refused, a non-200 status, a bad body, a timeout) is nil, so callers just
/// leave their answer out.
enum HelperHTTP {
    /// POST a JSON body and return the JSON object of a 200 reply.
    static func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        guard let reply = send(request, timeout: timeout) else { return nil }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    /// True when a GET answers 200 within `timeout`.
    static func isHealthy(_ url: URL, timeout: TimeInterval) -> Bool {
        send(URLRequest(url: url, timeoutInterval: timeout), timeout: timeout) != nil
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) -> Data? {
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return }
            box.set(data)
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 0.05) == .timedOut {
            task.cancel()
            return nil
        }
        return box.get()
    }
}

/// Starts the local helper service in the background when a helper call finds it down, so later calls
/// get it. The call that found it down is not held up: it skips its hint or fallback.
///
/// Guards: only for a loopback URL, only when the launcher exists, only once per process, and at most one
/// health check a minute while the helper stays down. The callers reach this only when the referee or
/// vision URL is set, so nothing starts when hints and find-on-screen are off. The helper unloads its
/// models after 10 idle minutes; nothing here keeps it running.
final class HelperAutoStarter: @unchecked Sendable {
    static let shared = HelperAutoStarter(
        launcher: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ocu-referee/run_mlx.sh"),
        log: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ocu-referee/service.log")
    )

    /// Seconds between health checks while the helper is down.
    static let checkCooldown: TimeInterval = 60

    private let launcher: URL
    private let log: URL
    private let lock = NSLock()
    private var lastCheck: TimeInterval?
    private var launched = false

    init(launcher: URL, log: URL) {
        self.launcher = launcher
        self.log = log
    }

    /// Called after a helper call got no answer. Checks health off the calling thread and starts the
    /// launcher detached when the helper is really down.
    func helperUnreachable(_ baseURL: URL, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard Self.isLoopback(baseURL) else { return }
        lock.lock()
        let check = !launched && Self.shouldCheck(lastCheck: lastCheck, now: now, cooldown: Self.checkCooldown)
        if check { lastCheck = now }
        lock.unlock()
        guard check else { return }

        let healthURL = baseURL.appendingPathComponent("health")
        DispatchQueue.global(qos: .utility).async { [self] in
            let healthy = HelperHTTP.isHealthy(healthURL, timeout: 0.5)
            let exists = FileManager.default.fileExists(atPath: launcher.path)
            lock.lock()
            let start = Self.shouldLaunch(loopback: true, healthy: healthy, launcherExists: exists, launchedBefore: launched)
            if start { launched = true }
            lock.unlock()
            if start { launch() }
        }
    }

    private func launch() {
        let output = Self.logHandle(log) ?? FileHandle.nullDevice
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher.path]
        process.currentDirectoryURL = launcher.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            // Not waited for: the helper keeps running after this call, and after this agent exits.
            try process.run()
        } catch {
            try? output.write(contentsOf: Data("helper auto-start failed: \(error)\n".utf8))
        }
    }

    private static func logHandle(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    static func shouldCheck(lastCheck: TimeInterval?, now: TimeInterval, cooldown: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now - lastCheck >= cooldown
    }

    static func shouldLaunch(loopback: Bool, healthy: Bool, launcherExists: Bool, launchedBefore: Bool) -> Bool {
        loopback && !healthy && launcherExists && !launchedBefore
    }
}

/// Idle bookkeeping for the GODSPEED app agent. The agent exits once it has had no connected client for
/// `idleLimit` seconds. A connected client keeps it alive, including while its call is still running,
/// because a client is connected for the whole call. Pure: the caller passes the clock.
public struct AgentIdleTimer: Sendable {
    public let idleLimit: TimeInterval
    public private(set) var connectedClients = 0
    /// Set once the agent has decided to exit; it then refuses new clients.
    public private(set) var isExiting = false
    private var idleSince: TimeInterval?

    /// `now` is when the agent started, so an agent nobody connects to still exits.
    public init(idleLimit: TimeInterval, now: TimeInterval) {
        self.idleLimit = max(0, idleLimit)
        idleSince = now
    }

    /// False when the agent is exiting: the caller must close the new connection.
    public mutating func clientConnected() -> Bool {
        guard !isExiting else { return false }
        connectedClients += 1
        idleSince = nil
        return true
    }

    public mutating func clientDisconnected(now: TimeInterval) {
        connectedClients = max(0, connectedClients - 1)
        if connectedClients == 0 { idleSince = now }
    }

    /// True once, when the agent has been idle for the whole limit. A limit of 0 never exits.
    public mutating func shouldExit(now: TimeInterval) -> Bool {
        guard !isExiting, idleLimit > 0, connectedClients == 0, let idleSince else { return false }
        guard now - idleSince >= idleLimit else { return false }
        isExiting = true
        return true
    }
}

public enum AgentIdlePolicy {
    public static let environmentKey = "OPEN_COMPUTER_USE_AGENT_IDLE_EXIT_SECONDS"
    public static let defaultIdleExitSeconds: TimeInterval = 900

    /// Seconds of no connected client before the app agent exits. 0 means never. A missing, negative or
    /// non-numeric value means the default (15 minutes).
    public static func idleExitSeconds(environment: [String: String]) -> TimeInterval {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(raw), value.isFinite, value >= 0
        else { return defaultIdleExitSeconds }
        return value
    }

    /// The configured value, read through the settings file like every other GODSPEED setting.
    public static func configuredIdleExitSeconds() -> TimeInterval {
        idleExitSeconds(environment: GodspeedSettings.environment)
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func set(_ data: Data) {
        lock.lock(); value = data; lock.unlock()
    }

    func get() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
