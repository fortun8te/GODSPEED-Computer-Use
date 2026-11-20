import Foundation

/// Delivers one app's observed inputs. The live source (accessibility notifications and a listen-only event tap)
/// is in TeachSources.swift; tests pass a fake.
protocol TeachInputSource: AnyObject {
    /// Starts delivering inputs for the process `pid` and key presses. Returns false when it cannot start.
    func start(pid: pid_t, deliver: @escaping (TeachInput) -> Void) -> Bool
    func stop()
}

/// The `teach` tool's session: start watching one app, then stop and save an unverified batch recipe.
/// A saved recipe only becomes verified after one replay passes its done_when, as for any batch.
final class TeachMode: @unchecked Sendable {  // every mutable field is guarded by `lock`
    static let shared = TeachMode(
        store: .shared,
        makeSource: { nil },
        resolveApp: { _ in nil },
        readWindow: { _ in nil },
        now: { Date() }
    )

    struct AppTarget {
        let pid: pid_t
        let name: String
    }

    static let statusInterval: TimeInterval = 5

    private let lock = NSLock()
    private let store: BatchRecipes
    private let makeSource: () -> TeachInputSource?
    private let resolveApp: (String) -> AppTarget?
    private let readWindow: (String) -> BatchRecipes.Window?
    private let now: () -> Date
    private let scheduleTimer: Bool
    private var recorder: TeachRecorder?
    private var source: TeachInputSource?
    private var timer: DispatchSourceTimer?
    private var lastOutcome: String?

    init(store: BatchRecipes, makeSource: @escaping () -> TeachInputSource?,
         resolveApp: @escaping (String) -> AppTarget?, readWindow: @escaping (String) -> BatchRecipes.Window?,
         now: @escaping () -> Date, scheduleTimer: Bool = true) {
        self.store = store
        self.makeSource = makeSource
        self.resolveApp = resolveApp
        self.readWindow = readWindow
        self.now = now
        self.scheduleTimer = scheduleTimer
    }

    /// Starts recording. The reply says recording is on.
    func start(app: String, goal: String) throws -> String {
        let appName = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty, !trimmedGoal.isEmpty else {
            throw ComputerUseError.invalidArguments("teach start needs an app and a goal.")
        }
        lock.lock()
        defer { lock.unlock() }
        if let recorder, recorder.isRecording {
            throw ComputerUseError.invalidArguments("Recording is already on for \(recorder.app). Say teach stop first.")
        }
        guard let target = resolveApp(appName) else { throw ComputerUseError.appNotFound(appName) }
        let started = TeachRecorder(app: target.name, goal: trimmedGoal, pid: target.pid,
                                    window: readWindow(target.name), startedAt: now())
        guard let live = makeSource(), live.start(pid: target.pid, deliver: { [weak self] in self?.receive($0) }) else {
            throw ComputerUseError.permissionDenied("Teach mode could not watch \(target.name). Check Accessibility and Input Monitoring for Godspeed.")
        }
        recorder = started
        source = live
        lastOutcome = nil
        if scheduleTimer { startTimer() }
        return "Recording is on for \(target.name): \"\(trimmedGoal)\". Only \(target.name) is watched, for up to 10 minutes. Do the task in \(target.name), then say teach stop to save it."
    }

    /// Stops recording and saves what was seen as an unverified recipe. Returns the steps for the reply.
    func stop() -> String {
        lock.lock()
        defer { lock.unlock() }
        // A recording that already ended (time limit, app quit) was saved then; status reports that outcome.
        guard recorder != nil else { return "Recording is not on. \(lastOutcome ?? "")".trimmingCharacters(in: .whitespaces) }
        return finishLocked()
    }

    /// Recording state for the reply. Ends a recording that has passed its time limit.
    func status() -> String {
        lock.lock()
        defer { lock.unlock() }
        tickLocked()
        if let recorder, recorder.isRecording {
            let left = max(0, Int(TeachRecorder.timeLimit - now().timeIntervalSince(recorder.startedAt)))
            return "Recording is on for \(recorder.app): \"\(recorder.goal)\". \(recorder.steps.count) steps so far, \(left / 60) min \(left % 60) s left."
        }
        return lastOutcome ?? "Recording is off."
    }

    /// Ends and saves a recording that has passed its time limit. Called by the timer and by status.
    func tick() {
        lock.lock()
        defer { lock.unlock() }
        tickLocked()
    }

    // MARK: Private

    private func receive(_ input: TeachInput) {
        lock.lock()
        defer { lock.unlock() }
        guard let recorder else { return }
        recorder.handle(input, now: now())
        if !recorder.isRecording { finishLocked() }
    }

    private func tickLocked() {
        guard let recorder, recorder.expireIfNeeded(now: now()) else { return }
        finishLocked()
    }

    /// Stops the source, saves the recipe and returns the reply. Caller holds the lock.
    @discardableResult
    private func finishLocked() -> String {
        guard let recorder else { return "" }
        let reason = recorder.ended ?? "stopped"
        let result = recorder.finish()
        source?.stop()
        source = nil
        timer?.cancel()
        timer = nil
        self.recorder = nil

        var lines = ["Recording stopped (\(reason))."]
        if result.steps.isEmpty {
            lines.append("Nothing was recorded, so no recipe was saved.")
        } else if store.save(app: recorder.app, goal: recorder.goal, steps: result.steps, params: result.params,
                             slotKinds: result.kinds, doneWhen: [], window: recorder.window, verified: false) != nil {
            lines.append("Saved an unverified recipe for \"\(recorder.goal)\" with \(result.steps.count) steps:")
            for (index, step) in result.steps.enumerated() {
                lines.append("\(index + 1). \(Self.describe(step as? [String: Any] ?? [:]))")
            }
            if !result.needsValue.isEmpty {
                lines.append("The recipe needs the value for \(result.needsValue.joined(separator: ", ")) again before it can run. Secure field text is never stored.")
            }
            lines.append("It becomes verified only after one replay passes its check.")
        } else {
            lines.append("The recipe could not be saved.")
        }
        lines.append(contentsOf: result.notes)
        let text = lines.joined(separator: "\n")
        lastOutcome = text
        return text
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.statusInterval, repeating: Self.statusInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// One plain line per step, for the reply.
    static func describe(_ step: [String: Any]) -> String {
        switch step["tool"] as? String {
        case "click":
            return "Click \"\(step["label"] as? String ?? "")\""
        case "set_value":
            let label = step["label"] as? String ?? ""
            if step["_needs_value"] as? Bool == true { return "Set \"\(label)\" (value needed again)" }
            return "Set \"\(label)\" to \(step["value"] as? String ?? "")"
        case "type_text":
            return "Type \(step["text"] as? String ?? "")"
        case "press_menu":
            return "Menu \(step["path"] as? String ?? "")"
        default:
            return "Step"
        }
    }
}
