import Foundation

/// A control resolved from a focus notification or an accessibility hit test. Never a coordinate or element number.
struct TeachTarget: Equatable {
    var role: String
    var label: String
    var parent: String = ""
    var nearby: [String] = []
    /// A secure (password) field. Text typed into it is never kept.
    var secure = false
}

enum TeachEvent: Equatable {
    case focus(TeachTarget)
    /// The field's full value after an accessibility value change. `nil` when the element gave none.
    case value(TeachTarget, String?)
    /// Plain characters from a key press (shortcuts are not text).
    case typed(String)
    case press(TeachTarget)
    /// A menu command by its titles, e.g. ["File", "Save"].
    case menu([String])
    case windowCreated
    case appQuit
}

struct TeachInput: Equatable {
    /// The process that owns the element. For key presses, the frontmost process.
    let pid: pid_t
    let event: TeachEvent
}

/// Turns one app's observed actions into batch steps and typed slots. Pure: no accessibility or event APIs.
/// Only input from the target process is kept, and recording ends after `timeLimit` or when the app quits.
final class TeachRecorder {
    static let timeLimit: TimeInterval = 600
    static let unlabelledNote = "An unlabelled control was not recorded."
    static let noFocusNote = "Some typing had no focused field and was not recorded."

    struct Recording {
        let steps: [Any]
        let params: [String: String]
        let kinds: [String: BatchRecipes.SlotKind]
        /// Labels of secure fields typed into. Their text was not kept, so the recipe needs the value again.
        let needsValue: [String]
        let notes: [String]
    }

    let app: String
    let goal: String
    let pid: pid_t
    let window: BatchRecipes.Window?
    let startedAt: Date
    /// Set once recording stops: "stopped", "10-minute limit" or "app quit".
    private(set) var ended: String?
    private(set) var steps: [[String: Any]] = []
    private(set) var needsValue: [String] = []
    private(set) var notes: [String] = []

    private var focus: TeachTarget?
    private var buffer: (target: TeachTarget, text: String)?

    init(app: String, goal: String, pid: pid_t, window: BatchRecipes.Window?, startedAt: Date) {
        self.app = app
        self.goal = goal
        self.pid = pid
        self.window = window
        self.startedAt = startedAt
    }

    var isRecording: Bool { ended == nil }

    /// Feeds one observed input. Returns false when it was not recorded.
    @discardableResult
    func handle(_ input: TeachInput, now: Date) -> Bool {
        guard isRecording else { return false }
        if now.timeIntervalSince(startedAt) >= Self.timeLimit {
            end("10-minute limit")
            return false
        }
        if case .appQuit = input.event, input.pid == pid {
            end("app quit")
            return true
        }
        // Nothing outside the target app is kept.
        guard input.pid == pid else { return false }
        switch input.event {
        case .focus(let target):
            moveFocus(to: target)
        case .value(let target, let value):
            moveFocus(to: target)
            if target.secure {
                markSecret(target)
            } else if buffer == nil, let value, !value.isEmpty, let focus {
                buffer = (focus, value)
            }
        case .typed(let text):
            guard let target = focus else {
                addNote(Self.noFocusNote)
                return true
            }
            if target.secure {
                markSecret(target)
                return true
            }
            if buffer == nil { buffer = (target, "") }
            buffer?.text += text
        case .press(let target):
            flush()
            if target.secure {
                focus = target
                return true
            }
            guard !target.label.isEmpty else {
                addNote(Self.unlabelledNote)
                return true
            }
            steps.append(["tool": "click", "label": target.label, "_loc": locator(target)])
            focus = target
        case .menu(let path):
            flush()
            guard !path.isEmpty else { return true }
            steps.append(["tool": "press_menu", "path": path.joined(separator: " > ")])
        case .windowCreated:
            flush()
        case .appQuit:
            break
        }
        return true
    }

    /// Stops recording if it is still running and returns the steps with typed text as named slots.
    func finish() -> Recording {
        end("stopped")
        let parameterized = BatchRecipes.parameterize(steps, values: [:])
        return Recording(
            steps: parameterized.steps,
            params: parameterized.params,
            kinds: parameterized.kinds,
            needsValue: needsValue,
            notes: notes
        )
    }

    // MARK: Private

    private func end(_ reason: String) {
        guard ended == nil else { return }
        flush()
        ended = reason
    }

    private func moveFocus(to target: TeachTarget) {
        guard focus != target else { return }
        flush()
        focus = target
    }

    /// Writes the typed text for the focused field as one step: set_value for a labelled field, type_text otherwise.
    private func flush() {
        guard let pending = buffer else { return }
        buffer = nil
        guard !pending.text.isEmpty else { return }
        if pending.target.label.isEmpty {
            steps.append(["tool": "type_text", "text": pending.text])
        } else {
            steps.append(["tool": "set_value", "label": pending.target.label, "value": pending.text,
                          "_loc": locator(pending.target)])
        }
    }

    /// A placeholder step, marked as needing the value again. No text from the secure field is kept.
    private func markSecret(_ target: TeachTarget) {
        buffer = nil
        let name = target.label.isEmpty ? "secure field" : target.label
        guard !needsValue.contains(name) else { return }
        needsValue.append(name)
        steps.append(["tool": "set_value", "label": target.label, "_needs_value": true, "_loc": locator(target)])
    }

    private func locator(_ target: TeachTarget) -> [String: Any] {
        RecipeLocator.Locator(role: target.role, label: target.label, parent: target.parent, nearby: target.nearby).dictionary
    }

    private func addNote(_ note: String) {
        if !notes.contains(note) { notes.append(note) }
    }
}
