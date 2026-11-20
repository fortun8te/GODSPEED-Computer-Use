import Foundation

/// Errors from restoring saved bandit state.
public enum RouteBanditError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Learns which already-allowed delivery route works best for each app and action kind.
/// The caller supplies the arms. The first arm is the caller's safe default.
public final class RouteBandit: @unchecked Sendable {
    /// Bench an arm for this many seconds after `benchAfterFailures` failures in a row.
    public static let benchSeconds: Double = 600
    public static let benchAfterFailures = 3
    /// Once an arm has this many trials, exploration is capped.
    public static let matureTrials = 20
    /// Maximum share of choices that may explore once mature.
    public static let exploreCap = 0.10
    /// Words that make an action risky even when the caller forgets the flag.
    public static let riskyWords = ["send", "submit", "pay", "delete", "remove", "purchase", "checkout", "transfer", "publish", "buy"]

    private struct ArmStat: Codable {
        var successes = 0
        var failures = 0
        var streak = 0
        var latencySum = 0.0
        var latencyCount = 0
        var benchedUntil = 0.0
    }

    private struct KeyState: Codable {
        var choices = 0
        var explorations = 0
        var arms: [String: ArmStat] = [:]
    }

    private struct Snapshot: Codable {
        var version: Int
        var apps: [String: [String: KeyState]]
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private var apps: [String: [String: KeyState]] = [:]

    /// `clock` returns seconds; tests inject a fake one.
    public init(clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.clock = clock
    }

    /// Picks one arm. Risky actions return `arms[0]` and never explore.
    public func choose<G: RandomNumberGenerator>(
        app: String, action: String, arms: [String], riskyAction: Bool = false, rng: inout G
    ) -> String {
        precondition(!arms.isEmpty, "RouteBandit needs at least one arm")
        let fallback = arms[0]
        if riskyAction || Self.looksRisky(action) || arms.count == 1 { return fallback }

        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        var key = apps[app]?[action] ?? KeyState()
        let eligible = arms.filter { (key.arms[$0]?.benchedUntil ?? 0) <= now }
        guard !eligible.isEmpty else { return fallback }

        // Thompson sample: one Beta draw per eligible arm.
        var sampled = eligible[0]
        var bestDraw = -1.0
        for arm in eligible {
            let s = key.arms[arm] ?? ArmStat()
            let draw = Self.beta(Double(s.successes + 1), Double(s.failures + 1), &rng)
            if draw > bestDraw {
                bestDraw = draw
                sampled = arm
            }
        }
        let greedy = eligible.reduce(eligible[0]) { current, arm in
            Self.isBetter(key.arms[arm] ?? ArmStat(), than: key.arms[current] ?? ArmStat()) ? arm : current
        }

        key.choices += 1
        var pick = sampled
        if sampled != greedy {
            let mature = key.arms.values.contains { $0.successes + $0.failures >= Self.matureTrials }
            // Once mature, exploring is allowed only while it stays under the cap.
            if !mature || Double(key.explorations + 1) <= Self.exploreCap * Double(key.choices) {
                key.explorations += 1
            } else {
                pick = greedy
            }
        }
        apps[app, default: [:]][action] = key
        return pick
    }

    /// Same as `choose` with the system random generator.
    public func choose(app: String, action: String, arms: [String], riskyAction: Bool = false) -> String {
        var rng = SystemRandomNumberGenerator()
        return choose(app: app, action: action, arms: arms, riskyAction: riskyAction, rng: &rng)
    }

    /// Records one outcome. Only `verified: true` counts as success.
    public func record(app: String, action: String, arm: String, verified: Bool, latencyMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        var key = apps[app]?[action] ?? KeyState()
        var s = key.arms[arm] ?? ArmStat()
        if verified {
            s.successes += 1
            s.streak = 0
        } else {
            s.failures += 1
            s.streak += 1
        }
        if latencyMs.isFinite, latencyMs >= 0 {
            s.latencySum += latencyMs
            s.latencyCount += 1
        }
        if s.streak >= Self.benchAfterFailures {
            // Benched arms get a fresh streak once they return.
            s.benchedUntil = clock() + Self.benchSeconds
            s.streak = 0
        }
        key.arms[arm] = s
        apps[app, default: [:]][action] = key
    }

    /// True while an arm is benched.
    public func isBenched(app: String, action: String, arm: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let until = apps[app]?[action]?.arms[arm]?.benchedUntil ?? 0
        return until > clock()
    }

    /// Choices made and how many of them explored.
    public func explorationStats(app: String, action: String) -> (choices: Int, explorations: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = apps[app]?[action] ?? KeyState()
        return (key.choices, key.explorations)
    }

    /// Saved state as JSON. It holds only numbers and ids.
    public func jsonData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Snapshot(version: 1, apps: apps))
    }

    /// Replaces the state with saved JSON.
    public func restore(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1 else { throw RouteBanditError.unsupportedVersion(snapshot.version) }
        lock.lock()
        defer { lock.unlock() }
        apps = snapshot.apps
    }

    // MARK: - Helpers

    private static func looksRisky(_ action: String) -> Bool {
        let lower = action.lowercased()
        return riskyWords.contains { lower.contains($0) }
    }

    /// Higher posterior mean wins. Equal means go to the lower latency.
    private static func isBetter(_ a: ArmStat, than b: ArmStat) -> Bool {
        let ma = posteriorMean(a)
        let mb = posteriorMean(b)
        if abs(ma - mb) > 1e-12 { return ma > mb }
        return latencyMean(a) < latencyMean(b)
    }

    private static func posteriorMean(_ s: ArmStat) -> Double {
        (Double(s.successes) + 1) / (Double(s.successes + s.failures) + 2)
    }

    private static func latencyMean(_ s: ArmStat) -> Double {
        s.latencyCount > 0 ? s.latencySum / Double(s.latencyCount) : .infinity
    }

    private static func uniform<G: RandomNumberGenerator>(_ rng: inout G) -> Double {
        max(Double.random(in: 0..<1, using: &rng), 1e-300)
    }

    private static func normal<G: RandomNumberGenerator>(_ rng: inout G) -> Double {
        sqrt(-2 * log(uniform(&rng))) * cos(2 * .pi * Double.random(in: 0..<1, using: &rng))
    }

    /// Marsaglia-Tsang gamma sampler.
    private static func gamma<G: RandomNumberGenerator>(_ shape: Double, _ rng: inout G) -> Double {
        if shape < 1 {
            return gamma(shape + 1, &rng) * pow(uniform(&rng), 1 / shape)
        }
        let d = shape - 1.0 / 3.0
        let c = 1 / sqrt(9 * d)
        while true {
            var x = 0.0
            var v = 0.0
            repeat {
                x = normal(&rng)
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = uniform(&rng)
            if u < 1 - 0.0331 * x * x * x * x { return d * v }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
    }

    private static func beta<G: RandomNumberGenerator>(_ a: Double, _ b: Double, _ rng: inout G) -> Double {
        let x = gamma(a, &rng)
        let y = gamma(b, &rng)
        return x / (x + y)
    }
}

/// An integer setting with fixed bounds.
public struct ParameterBounds: Codable, Sendable, Equatable {
    public let min: Int
    public let max: Int
    public let defaultValue: Int

    public init(min: Int, max: Int, defaultValue: Int) {
        precondition(min <= max, "min must not exceed max")
        self.min = min
        self.max = max
        self.defaultValue = Swift.min(max, Swift.max(min, defaultValue))
    }
}

/// Tunes one bounded integer per app with successive halving.
/// Five evenly spaced candidates run in rounds. Each round keeps the better half,
/// ranked by verified success and then by latency.
public final class ParameterTuner: @unchecked Sendable {
    public static let candidateCount = 5

    private struct TuneState: Codable {
        var candidates: [Int]
        var defaultIndex: Int
        var alive: [Bool]
        var trials: [Int]
        var successes: [Int]
        var latencySum: [Double]
        var round = 0
    }

    private struct Snapshot: Codable {
        var version: Int
        var apps: [String: TuneState]
    }

    private let lock = NSLock()
    private let bounds: ParameterBounds
    private let trialsPerRound: Int
    private var apps: [String: TuneState] = [:]

    public init(bounds: ParameterBounds, trialsPerRound: Int = 20) {
        precondition(trialsPerRound >= 1, "trialsPerRound must be at least 1")
        self.bounds = bounds
        self.trialsPerRound = trialsPerRound
    }

    /// The value to use next for this app. Always within bounds.
    public func value(app: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let state = state(for: app)
        return state.candidates[Self.pick(state)]
    }

    /// The tuned value once one candidate is left, otherwise nil.
    public func winner(app: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let state = state(for: app)
        let alive = Self.aliveIndices(state)
        return alive.count == 1 ? state.candidates[alive[0]] : nil
    }

    /// Records one trial. Values that are not current candidates are ignored.
    public func record(app: String, value: Int, verified: Bool, latencyMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        var state = state(for: app)
        guard let i = state.candidates.firstIndex(of: value), state.alive[i] else { return }
        state.trials[i] += 1
        if verified { state.successes[i] += 1 }
        if latencyMs.isFinite, latencyMs >= 0 { state.latencySum[i] += latencyMs }

        let alive = Self.aliveIndices(state)
        if alive.count > 1, alive.allSatisfy({ state.trials[$0] >= trialsPerRound }) {
            let ranked = alive.sorted { Self.rank(state, $0) < Self.rank(state, $1) }
            for dropped in ranked.dropFirst((alive.count + 1) / 2) {
                state.alive[dropped] = false
            }
            for j in state.trials.indices {
                state.trials[j] = 0
                state.successes[j] = 0
                state.latencySum[j] = 0
            }
            state.round += 1
        }
        apps[app] = state
    }

    /// Saved state as JSON. It holds only numbers and ids.
    public func jsonData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Snapshot(version: 1, apps: apps))
    }

    /// Replaces the state with saved JSON.
    public func restore(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1 else { throw RouteBanditError.unsupportedVersion(snapshot.version) }
        lock.lock()
        defer { lock.unlock() }
        apps = snapshot.apps
    }

    // MARK: - Helpers

    private func state(for app: String) -> TuneState {
        if let existing = apps[app] { return existing }
        let state = makeState()
        apps[app] = state
        return state
    }

    private func makeState() -> TuneState {
        let span = bounds.max - bounds.min
        let count = Self.candidateCount
        var candidates: [Int] = []
        for i in 0..<count {
            let offset = (Double(span) * Double(i) / Double(count - 1)).rounded()
            let value = min(bounds.max, max(bounds.min, bounds.min + Int(offset)))
            if !candidates.contains(value) { candidates.append(value) }
        }
        // The candidate nearest the default is tried first.
        let defaultIndex = candidates.indices.min {
            abs(candidates[$0] - bounds.defaultValue) < abs(candidates[$1] - bounds.defaultValue)
        } ?? 0
        let n = candidates.count
        return TuneState(
            candidates: candidates, defaultIndex: defaultIndex, alive: Array(repeating: true, count: n),
            trials: Array(repeating: 0, count: n), successes: Array(repeating: 0, count: n),
            latencySum: Array(repeating: 0, count: n)
        )
    }

    private static func aliveIndices(_ state: TuneState) -> [Int] {
        state.alive.indices.filter { state.alive[$0] }
    }

    /// Fewest trials this round first, then closest to the default.
    private static func pick(_ state: TuneState) -> Int {
        aliveIndices(state).min { a, b in
            (state.trials[a], abs(a - state.defaultIndex), a) < (state.trials[b], abs(b - state.defaultIndex), b)
        } ?? state.defaultIndex
    }

    /// Lower sorts first: higher success rate, then lower latency.
    private static func rank(_ state: TuneState, _ i: Int) -> (Double, Double, Int, Int) {
        let n = Double(max(1, state.trials[i]))
        return (-Double(state.successes[i]) / n, state.latencySum[i] / n, abs(i - state.defaultIndex), i)
    }
}
