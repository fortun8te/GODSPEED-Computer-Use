import CoreFoundation
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

    static var baseURL: URL? {
        guard ModelHelperPolicy.isEnabled,
              let raw = environment("OPEN_COMPUTER_USE_REFEREE_URL"), !raw.isEmpty else { return nil }
        // Without a scheme and host ("127.0.0.1:8765") URL(string:) gives a URL no request can use.
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    /// Longest the batch waits for an answer. Default 1500 ms: a warm d1-2B (fp16) answers a 1,000-character
    /// view in about 270 ms; a cold one reloads for about 4 s and is skipped.
    static var timeout: TimeInterval {
        let milliseconds = finiteSetting("OPEN_COMPUTER_USE_REFEREE_TIMEOUT_MS", fallback: 1_500, range: 0...30_000)
        return max(50, milliseconds) / 1000
    }

    /// Hints below this confidence are left out. Default 0.6.
    static var minimumConfidence: Double {
        finiteSetting("OPEN_COMPUTER_USE_REFEREE_MIN_CONFIDENCE", fallback: 0.6, range: 0...1)
    }

    /// "done" hints need at least this confidence. Default 0.86: the lowest value at which the d1-2B
    /// done answers on the eval2 dev split were all right (9 of 9; 0.85 gave 10 of 11). Chosen on dev only.
    static var doneConfidence: Double {
        finiteSetting("OPEN_COMPUTER_USE_REFEREE_DONE_CONFIDENCE", fallback: 0.86, range: 0...1)
    }

    /// The helper gets at most this many characters of state. Default 1200: longer views were slower and
    /// less accurate in the d1-2B measurements (~270 ms at 1,000 characters, ~1.1 s at 6,000).
    static var maxViewCharacters: Int {
        max(0, environment("OPEN_COMPUTER_USE_REFEREE_MAX_VIEW").flatMap(Int.init) ?? 1_200)
    }

    static var isEnabled: Bool { baseURL != nil }

    private static let warmLock = NSLock()
    nonisolated(unsafe) private static var lastWarm: TimeInterval?

    /// Loads the decision model in the background, so the hint at the end of this batch is not lost to a
    /// cold load (about 2.3 s, longer than the hint timeout). Fire and forget, at most once a minute; the
    /// helper unloads it again after 3 idle minutes. Starts the helper when it is down.
    static func warmInBackground(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                 requestClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                 reserveWarmup: ((TimeInterval) -> Bool)? = nil,
                                 recoverHelper: @escaping @Sendable (URL) -> Void = { HelperAutoStarter.shared.helperUnreachable($0) },
                                 send: (URLRequest, @escaping @Sendable (Bool) -> Void) -> Void = { request, completion in
        URLSession.shared.dataTask(with: request) { _, response, error in
            completion(error == nil && (response as? HTTPURLResponse)?.statusCode == 202)
        }.resume()
    }) {
        let requestEnvironment = GodspeedSettings.environment
        let cancellation = RequestCancellation.current
        let deadline = BrowserCallBudget.activeDeadline
        guard ModelHelperPolicy.isEnabled(environment: requestEnvironment), !RequestCancellation.requested,
              RequestInferenceAdmission.withoutExclusive == nil, let baseURL,
              let budget = HelperHTTP.Budget(timeout: 1, now: requestClock(), inheritedDeadline: deadline),
              var parts = URLComponents(url: baseURL.appendingPathComponent("warm"), resolvingAgainstBaseURL: false)
        else { return }
        parts.queryItems = [URLQueryItem(name: "models", value: "d1")]
        guard let url = parts.url else { return }
        let due: Bool
        if let reserveWarmup {
            guard budget.remaining(now: requestClock()) != nil else { return }
            due = reserveWarmup(now)
        } else {
            warmLock.lock()
            due = budget.remaining(now: requestClock()) != nil && (lastWarm.map { now - $0 >= 60 } ?? true)
            if due { lastWarm = now }
            warmLock.unlock()
        }
        guard due, !RequestCancellation.requested, let remaining = budget.remaining(now: requestClock()) else { return }
        var request = URLRequest(url: url, timeoutInterval: remaining)
        request.httpMethod = "GET"
        send(request) { succeeded in
            guard !succeeded else { return }
            // URLSession callbacks do not inherit the calling client's configuration.
            RequestConfiguration.withEnvironment(requestEnvironment) {
                RequestCancellation.$current.withValue(cancellation) {
                    let recover = {
                        guard !RequestCancellation.requested,
                              deadline.map({ $0.isFinite && $0 > requestClock() }) ?? true else { return }
                        recoverHelper(baseURL)
                    }
                    if let deadline { BrowserCallBudget.withDeadline(deadline, recover) }
                    else { recover() }
                }
            }
        }
    }

    // Completion hints are experimental. Without independent calibration, use
    // deterministic checks for task completion and keep the model for recovery.
    static var allowsCompletionHints: Bool {
        ["1", "true", "yes", "on"].contains(environment("OPEN_COMPUTER_USE_REFEREE_DONE_HINTS")?.lowercased() ?? "")
    }

    /// Asks the helper about one batch. `summary` is the short RefereeSummary text (goal, steps, repeated
    /// failures, screen change, dialog, changed lines), not raw screen text.
    static func decide(goal: String, lastStep: String, result: String, summary: String,
                       imageBase64: String? = nil, remaining: TimeInterval? = nil) -> Verdict? {
        guard let baseURL else { return nil }
        let wait = min(timeout, remaining ?? timeout)
        guard wait > 0 else { return nil }

        var body: [String: Any] = [
            "goal": goal,
            "last_step": lastStep,
            "result": result,
            "view": RefereeSummary.clip(summary, to: maxViewCharacters),
        ]
        if HelperAutoStarter.isLoopback(baseURL) { body["image_base64"] = imageBase64 }
        let started = ProcessInfo.processInfo.systemUptime
        let reply = HelperHTTP.postJSON(baseURL.appendingPathComponent("decide"), body: body, timeout: wait)
        ToolTelemetry.current?.recordHelper("decide", startedAt: started, image: body["image_base64"] != nil, reply: reply)
        // Learning row (see LearningLog): the view sent and the answer, or a timeout. Never changes the verdict.
        recordDecision(kind: "decide", view: body["view"] as? String ?? "", options: [], reply: reply,
                       latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000, log: LearningLog.shared)
        guard let object = reply else {
            if wait == timeout { HelperAutoStarter.shared.helperUnreachable(baseURL) }
            return nil
        }
        return verdict(from: object)
    }

    /// The verdict in a helper reply, or nil when its label or confidence is missing or out of range.
    static func verdict(from object: [String: Any]) -> Verdict? {
        guard let label = object["label"] as? String,
              ["act", "look_again", "done", "stuck"].contains(label),
              let number = object["confidence"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { return nil }
        return Verdict(
            label: label,
            confidence: number.doubleValue,
            milliseconds: (object["ms"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// Longest a handoff waits for one ranking from the helper. Default 3000 ms.
    static var chooseTimeout: TimeInterval {
        let milliseconds = finiteSetting("OPEN_COMPUTER_USE_REFEREE_CHOOSE_TIMEOUT_MS", fallback: 3_000, range: 0...30_000)
        return max(100, milliseconds) / 1000
    }

    /// Asks the helper to score candidate actions for a handoff (POST /choose): one probability per option id
    /// plus "none". Nil when the referee is off, down or answers badly, so the handoff escalates instead of guessing.
    /// A dedicated URL also works when hints are off. An invalid explicit endpoint disables handoff
    /// scoring instead of silently sending evidence to a different helper.
    static func localChooseURL(refereeURL: URL?, setting: String?, configuredURL: String? = nil) -> URL? {
        if let setting, ["0", "false", "off", "no"].contains(setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return nil
        }
        let raw = configuredURL ?? refereeURL?.absoluteString ?? "http://127.0.0.1:8765"
        guard let url = VisionFallback.localURL(raw),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return url
    }

    static var handoffURL: URL? {
        guard ModelHelperPolicy.isEnabled else { return nil }
        return localChooseURL(refereeURL: baseURL, setting: environment("OPEN_COMPUTER_USE_HANDOFF_HELPER"),
                              configuredURL: environment("OPEN_COMPUTER_USE_HANDOFF_URL"))
    }

    private static let pictureCapabilities = RefereePictureCapabilityCache()

    static func picture(url: URL?, state: String, remaining: TimeInterval?, allowRichTree: Bool = false, thin: Bool? = nil, capture: () -> Data?) -> String? {
        guard ModelHelperPolicy.isEnabled, !RequestCancellation.requested else { return nil }
        return RefereePicture.attachment(url: url, visionEnabled: VisionFallback.isEnabled, state: state, remaining: remaining,
            supportsPictures: { url, timeout in
                pictureCapabilities.supports(url, now: ProcessInfo.processInfo.systemUptime) {
                    HelperHTTP.getJSON(url, timeout: timeout).map { $0["decision_image"] as? String == "v1" }
                }
            }, allowRichTree: allowRichTree, thin: thin, capture: capture)
    }

    static func choose(goal: String, doneWhen: String, history: String, screen: String, options: [(id: String, text: String)],
                       imageBase64: String? = nil, remaining: TimeInterval? = nil) -> [String: Double]? {
        guard let baseURL = handoffURL,
              !options.isEmpty else { return nil }
        let wait = min(chooseTimeout, remaining ?? chooseTimeout)
        guard wait > 0 else { return nil }
        var body: [String: Any] = [
            "goal": goal,
            "done_when": doneWhen,
            "history": history,
            "screen": RefereeSummary.clip(screen, to: maxViewCharacters),
            "options": options.map { ["id": $0.id, "text": $0.text] },
        ]
        if HelperAutoStarter.isLoopback(baseURL) { body["image_base64"] = imageBase64 }
        let started = ProcessInfo.processInfo.systemUptime
        let reply = HelperHTTP.postJSON(baseURL.appendingPathComponent("choose"), body: body, timeout: wait)
        ToolTelemetry.current?.recordHelper("choose", startedAt: started, image: body["image_base64"] != nil, reply: reply)
        let learning = LearningLog.shared
        if learning.isEnabled {
            let context = chooserCaptureContext(goal: goal, doneWhen: doneWhen, history: history,
                                                imageSupplied: body["image_base64"] != nil)
            recordDecision(kind: "choose", view: body["screen"] as? String ?? "", options: options, reply: reply,
                           latencyMs: (ProcessInfo.processInfo.systemUptime - started) * 1000, log: learning,
                           chooserContext: context)
        }
        guard let object = reply else {
            if wait == chooseTimeout { HelperAutoStarter.shared.helperUnreachable(baseURL) }
            return nil
        }
        return chooseProbabilities(object, options: options)
    }

    static func chooserCaptureContext(goal: String, doneWhen: String, history: String,
                                      imageSupplied: Bool) -> LearningChooserContext {
        func scrubbedPrefix(_ text: String, _ limit: Int) -> String {
            String(LearningScrubber.scrubText(text).unicodeScalars.prefix(limit))
        }
        return LearningChooserContext(goal: scrubbedPrefix(goal, 500),
                                      done_when: scrubbedPrefix(doneWhen, 300),
                                      history: scrubbedPrefix(history, 500),
                                      image_supplied: imageSupplied)
    }

    /// The usable scores of a choose reply: "none" and every option id must be present.
    static func chooseProbabilities(_ object: [String: Any], options: [(id: String, text: String)]) -> [String: Double]? {
        guard let probabilities = parseChoose(object) else { return nil }
        let expected = Set(options.map(\.id)).union(["none"])
        guard expected.isSubset(of: probabilities.keys) else { return nil }
        return probabilities.filter { expected.contains($0.key) }
    }

    /// Writes one decide or choose row. The outcome comes from the helper's answer only: decide gives act, hint
    /// (a line would be shown) or abstain; choose gives act, or abstain when "none" scores highest. No reply is
    /// timeout and an unusable reply is invalid. Nothing is written unless LearningLog is enabled.
    static func recordDecision(kind: String, view: String, options: [(id: String, text: String)], reply: [String: Any]?,
                               latencyMs: Double, log: LearningLog, chooserContext: LearningChooserContext? = nil) {
        guard log.isEnabled else { return }
        var row = LearningDecisionRow(
            kind: kind, view: view, options: options.map { LearningOption(id: $0.id, text: $0.text) },
            latency_ms: latencyMs, model: reply?["model"] as? String, chooser_context: chooserContext
        )
        if let reply, kind == "choose" {
            if let probabilities = chooseProbabilities(reply, options: options) {
                row.probabilities = probabilities
                let bestAction = options.compactMap { probabilities[$0.id] }.max() ?? 0
                row.outcome = (probabilities["none"] ?? 0) >= bestAction ? "abstain" : "act"
            } else {
                row.outcome = "invalid"
            }
        } else if let reply, let verdict = verdict(from: reply) {
            row.label = verdict.label
            row.confidence = verdict.confidence
            row.outcome = verdict.label == "act" ? "act" : (hint(for: verdict) != nil ? "hint" : "abstain")
        } else {
            row.outcome = reply == nil ? "timeout" : "invalid"
        }
        if reply?[HelperHTTP.busyResponseKey] as? Bool == true { row.outcome = "busy" }
        log.append(row)
    }

    /// `{"probs": {"a": 0.7, "none": 0.1}}` as a dictionary; nil when it has no usable numbers.
    static func parseChoose(_ object: [String: Any]) -> [String: Double]? {
        guard let raw = object["probs"] as? [String: Any] else { return nil }
        var probs: [String: Double] = [:]
        for (key, value) in raw {
            guard let numeric = value as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID() else { continue }
            let number = numeric.doubleValue
            guard number.isFinite, number >= 0, number <= 1 else { continue }
            probs[key] = number
        }
        return probs.isEmpty ? nil : probs
    }

    /// The hint line for a verdict, or nil when it is not worth the model's attention.
    static func hint(for verdict: Verdict, browser: Bool = false) -> String? {
        guard verdict.confidence.isFinite, (0...1).contains(verdict.confidence),
              verdict.confidence >= minimumConfidence else { return nil }
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
            if browser {
                return "Check: the page may be stale or still loading (\(sure)). Use browser wait_for or read on the same tab before acting."
            }
            return "Check: the state may be stale or still loading (\(sure)). Read it again with get_app_state and settle_ms before acting."
        default:
            // "act": nothing to add; the model was going to continue anyway.
            return nil
        }
    }

    private static func finiteSetting(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = environment(key).flatMap(Double.init), value.isFinite, range.contains(value) else {
            return fallback
        }
        return value
    }

    private static func environment(_ key: String) -> String? {
        GodspeedSettings.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The one synchronous HTTP path to the local helper service (referee and vision fallback share it).
/// Every failure (connection refused, a non-200 status, a bad body, a timeout) is nil, so callers just
/// leave their answer out.
enum HelperHTTP {
    static let busyResponseKey = "_godspeed_helper_busy"

    /// Keep one absolute deadline through encoding and temporary admission release.
    /// A helper's timeout cannot extend the enclosing workflow's remaining time.
    struct Budget {
        let deadline: TimeInterval

        init?(timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
              inheritedDeadline: TimeInterval? = BrowserCallBudget.activeDeadline) {
            guard now.isFinite, timeout.isFinite, timeout > 0 else { return nil }
            let limit = now + timeout
            guard limit.isFinite, inheritedDeadline?.isFinite != false else { return nil }
            deadline = min(limit, inheritedDeadline ?? limit)
            guard deadline > now else { return nil }
        }

        func remaining(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
            let remaining = deadline - now
            return remaining.isFinite && remaining > 0 ? remaining : nil
        }
    }

    /// POST JSON. A busy helper returns a busy marker so callers abstain without scheduling a health probe.
    static func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval, followRedirects: Bool = true,
                         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                         transport: ((URLRequest, TimeInterval, Bool, Bool) -> Data?)? = nil) -> [String: Any]? {
        let requestEnvironment = GodspeedSettings.environment
        let cancellation = RequestCancellation.current
        guard ModelHelperPolicy.isEnabled(environment: requestEnvironment), !RequestCancellation.requested,
              let budget = Budget(timeout: timeout, now: now()),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let useProtectedSession = !followRedirects || body["image_base64"] != nil
        let perform = { () -> Data? in
            guard !RequestCancellation.requested, let remaining = budget.remaining(now: now()) else { return nil }
            var boundedRequest = request
            boundedRequest.timeoutInterval = remaining
            if let transport { return transport(boundedRequest, remaining, useProtectedSession, true) }
            return send(boundedRequest, budget: budget, containsImage: useProtectedSession, acceptBusy: true)
        }
        // Encoding can use the last of the budget. Do not release desktop ownership
        // for inference that is already too late to start.
        guard !RequestCancellation.requested, budget.remaining(now: now()) != nil else { return nil }
        let reply: Data?
        if let withoutExclusive = RequestInferenceAdmission.withoutExclusive {
            // Never release an active focus borrow or a protected desktop lease.
            guard !FocusBorrow.shared.isBorrowing, !LockedUseActionScope.requiresScreenCaptureKit else { return nil }
            do {
                reply = try withoutExclusive {
                    RequestConfiguration.withEnvironment(requestEnvironment) {
                        RequestCancellation.$current.withValue(cancellation) {
                            perform()
                        }
                    }
                }
            } catch {
                // The desktop gate was lost. Stop the request so no later step runs on stale observations.
                RequestCancellation.current?.cancel()
                return nil
            }
        } else {
            reply = perform()
        }
        guard !RequestCancellation.requested, budget.remaining(now: now()) != nil, let reply else { return nil }
        let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        guard !RequestCancellation.requested, budget.remaining(now: now()) != nil else { return nil }
        return object
    }

    static func getJSON(_ url: URL, timeout: TimeInterval) -> [String: Any]? {
        guard let budget = Budget(timeout: timeout),
              let reply = send(URLRequest(url: url, timeoutInterval: timeout), budget: budget) else { return nil }
        let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        guard !RequestCancellation.requested, budget.remaining() != nil else { return nil }
        return object
    }

    /// True when a GET answers 200 within `timeout`.
    static func isHealthy(_ url: URL, timeout: TimeInterval) -> Bool {
        guard let budget = Budget(timeout: timeout) else { return false }
        return send(URLRequest(url: url, timeoutInterval: timeout), budget: budget) != nil
    }

    private static let imageSession = URLSession(
        configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil
    )

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func send(_ request: URLRequest, budget: Budget, containsImage: Bool = false,
                             acceptBusy: Bool = false) -> Data? {
        guard ModelHelperPolicy.isEnabled, !RequestCancellation.requested,
              let remaining = budget.remaining() else { return nil }
        var request = request
        request.timeoutInterval = remaining
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        let session = containsImage ? imageSession : URLSession.shared
        let task = session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode
            if acceptBusy && status == 503 {
                box.set(Data("{\"\(busyResponseKey)\":true}".utf8))
            } else if status == 200, let data {
                box.set(data)
            }
        }
        guard !RequestCancellation.requested, budget.remaining() != nil else {
            task.cancel()
            return nil
        }
        task.resume()
        while !RequestCancellation.requested, let remaining = budget.remaining() {
            if done.wait(timeout: .now() + min(remaining, 0.05)) == .success {
                return RequestCancellation.requested || budget.remaining() == nil ? nil : box.get()
            }
        }
        task.cancel()
        return nil
    }
}

/// Starts the local helper service in the background when a helper call finds it down, so later calls
/// get it. The call that found it down is not held up: it skips its hint or fallback.
///
/// Guards: only for a loopback URL, only when the launcher exists, only once per process, and at most one
/// health check a minute while the helper stays down. The master model-helper switch also disables
/// health probes and launches, including the default handoff helper. The helper unloads its
/// models after 10 idle minutes; nothing here keeps it running.
final class HelperAutoStarter: @unchecked Sendable {
    static let shared = HelperAutoStarter(
        launcher: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ocu-referee/run_mlx.sh"),
        log: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ocu-referee/service.log"),
        managedPort: 8765
    )

    /// Seconds between health checks while the helper is down.
    static let checkCooldown: TimeInterval = 60

    private let launcher: URL
    private let log: URL
    private let lock = NSLock()
    private var lastCheck: TimeInterval?
    private var pendingProbe: UUID?
    private var launched = false
    private let restartLocalScorer: Bool
    private let managedPort: Int?

    init(launcher: URL, log: URL, restartLocalScorer: Bool = false, managedPort: Int? = nil) {
        self.launcher = launcher
        self.log = log
        self.restartLocalScorer = restartLocalScorer
        self.managedPort = managedPort
    }

    /// The installed launchers receive no endpoint arguments. Starting one cannot repair an arbitrary
    /// custom service, HTTPS proxy or prefixed URL. Other endpoints can still be queried normally.
    func manages(_ url: URL) -> Bool {
        guard Self.isLoopback(url) else { return false }
        guard let managedPort else { return true }
        return url.scheme?.lowercased() == "http" && url.port == managedPort
            && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
            && (url.path.isEmpty || url.path == "/")
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    /// Called after a helper call got no answer. Checks health off the calling thread and starts the
    /// launcher detached when the helper is really down.
    func helperUnreachable(_ baseURL: URL, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                           schedule: (@escaping @Sendable () -> Void) -> Void = { work in
                               DispatchQueue.global(qos: .utility).async(execute: work)
                           }, healthCheck: @escaping @Sendable (URL) -> Bool = {
                               HelperHTTP.isHealthy($0, timeout: 0.5)
                           }, requestClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let requestEnvironment = GodspeedSettings.environment
        let cancellation = RequestCancellation.current
        let deadline = BrowserCallBudget.activeDeadline
        let hasTime: @Sendable () -> Bool = {
            deadline.map { $0.isFinite && $0 > requestClock() } ?? true
        }
        guard ModelHelperPolicy.isEnabled(environment: requestEnvironment),
              restartLocalScorer || RequestInferenceAdmission.withoutExclusive == nil, !RequestCancellation.requested,
              hasTime(), manages(baseURL) else { return }
        let reservation = UUID()
        lock.lock()
        let check = hasTime() && !launched && Self.shouldCheck(lastCheck: lastCheck, now: now, cooldown: restartLocalScorer ? 2 : Self.checkCooldown)
        let previousCheck = lastCheck
        if check {
            lastCheck = now
            pendingProbe = reservation
        }
        lock.unlock()
        guard check else { return }

        let healthURL = baseURL.appendingPathComponent("health")
        schedule { [self] in
            RequestConfiguration.withEnvironment(requestEnvironment) {
                RequestCancellation.$current.withValue(cancellation) {
                    let probe = { [self] in
                        guard !RequestCancellation.requested, hasTime() else {
                            // Nothing ran. Return this reservation without clearing
                            // a newer caller's independently scheduled probe.
                            lock.withLock {
                                if pendingProbe == reservation {
                                    lastCheck = previousCheck
                                    pendingProbe = nil
                                }
                            }
                            return
                        }
                        let ownsProbe = lock.withLock {
                            guard pendingProbe == reservation else { return false }
                            pendingProbe = nil
                            return true
                        }
                        guard ownsProbe else { return }
                        // Once a probe begins, its cooldown remains even if the
                        // deadline ends during the request; compute was consumed.
                        let healthy = healthCheck(healthURL)
                        let exists = FileManager.default.fileExists(atPath: launcher.path)
                        guard !RequestCancellation.requested, hasTime() else { return }
                        lock.lock()
                        let start = Self.shouldLaunch(loopback: true, healthy: healthy, launcherExists: exists, launchedBefore: launched)
                        if start { launched = true }
                        lock.unlock()
                        if start { launch() }
                    }
                    if let deadline { BrowserCallBudget.withDeadline(deadline, probe) }
                    else { probe() }
                }
            }
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
        if restartLocalScorer {
            process.terminationHandler = { [weak self] _ in
                self?.resetLaunch()
            }
        }
        do {
            // Not waited for: the helper keeps running after this call, and after this agent exits.
            try process.run()
        } catch {
            if restartLocalScorer { resetLaunch() }
            try? output.write(contentsOf: Data("helper auto-start failed: \(error)\n".utf8))
        }
    }

    private func resetLaunch() {
        lock.withLock { launched = false }
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
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
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

    public func nextExitDelay(now: TimeInterval) -> TimeInterval? {
        guard !isExiting, idleLimit > 0, let idleSince else { return nil }
        return max(0, idleLimit - (now - idleSince))
    }

    /// True once, when the agent has been idle for the whole limit. A limit of 0 never exits.
    public mutating func shouldExit(now: TimeInterval) -> Bool {
        guard nextExitDelay(now: now) == 0 else { return false }
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
