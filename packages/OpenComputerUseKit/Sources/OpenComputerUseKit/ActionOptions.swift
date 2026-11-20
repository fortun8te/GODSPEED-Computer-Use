import Foundation
import CoreFoundation
import CoreGraphics

enum ActionOptions {
    // These actions have their own delivery checks. Skip legacy vision, retargeting and focus borrowing.
    static func usesStrictRoute(_ tool: String, _ args: [String: Any]) -> Bool {
        switch tool {
        case "scroll_into_view", "wait_for": return true
        case "drag": return DragOptions.isRequested(args)
        case "scroll": return ScrollChunks.isRequested(args)
        case "click": return ClickPlacement.isRequested(args) || args["modifiers"] != nil
            || (args["click_count"] as? NSNumber)?.intValue == 3 && args["click_method"] == nil
        default: return false
        }
    }

    static func integer(_ key: String, in args: [String: Any], range: ClosedRange<Int>) throws -> Int? {
        guard let raw = args[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(exactly: number.doubleValue), range.contains(value) else {
            throw ComputerUseError.invalidArguments("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return value
    }

    static func string(_ key: String, in args: [String: Any]) throws -> String? {
        guard let raw = args[key] else { return nil }
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf16.count <= 1000 else {
            throw ComputerUseError.invalidArguments("\(key) needs text of 1–1000 UTF-16 units")
        }
        return value
    }
}

struct ScrollChunks {
    enum Unit: String { case lines, pages, points }

    let unit: Unit
    let size: Int
    let limit: Int
    let untilVisible: String?

    static func isRequested(_ args: [String: Any]) -> Bool {
        ["unit", "step_size", "max_steps", "until_visible"].contains { args[$0] != nil }
    }

    init?(_ args: [String: Any]) throws {
        guard Self.isRequested(args) else { return nil }
        guard args["pages"] == nil, args["amount"] == nil else {
            throw ComputerUseError.invalidArguments("Use step_size with unit, or use the legacy pages or amount argument by itself.")
        }
        guard let unit = Unit(rawValue: try ActionOptions.string("unit", in: args) ?? "pages") else {
            throw ComputerUseError.invalidArguments("scroll unit must be lines, pages or points")
        }
        self.unit = unit
        let maximum = unit == .pages ? 1 : unit == .lines ? 100 : 10_000
        size = try ActionOptions.integer("step_size", in: args, range: 1...maximum) ?? 1
        untilVisible = try ActionOptions.string("until_visible", in: args)
        limit = try ActionOptions.integer("max_steps", in: args, range: 1...20) ?? (untilVisible == nil ? 1 : 8)
    }

    struct Outcome {
        enum Stop: Equatable { case visible, stalled, limit }
        var chunks = 0
        let stop: Stop

        func reply(label: String?) throws -> String {
            let progress = "Scrolled \(chunks) chunk\(chunks == 1 ? "" : "s")."
            switch stop {
            case .visible: return "\(progress) \(label ?? "Target") is in view."
            case .stalled, .limit:
                let reason = stop == .stalled ? " No further movement." : ""
                if let label {
                    throw ComputerUseError.stateUnavailable("\(progress)\(reason) Could not confirm \(label) in view.")
                }
                return progress + reason
            }
        }
    }

    /// Each attempt must observe a position change before another chunk can be sent.
    func run(visible: () throws -> Bool, advance: () throws -> Bool) throws -> Outcome {
        if untilVisible != nil, try visible() { return Outcome(stop: .visible) }
        for step in 0..<limit {
            guard BrowserCallBudget.activeRemaining.map({ $0 > 0 }) ?? true else {
                throw ComputerUseError.stateUnavailable("Scroll stopped after \(step) chunks. The step time budget ended.")
            }
            let moved = try advance()
            if untilVisible != nil, try visible() {
                return Outcome(chunks: step + (moved ? 1 : 0), stop: .visible)
            }
            if !moved { return Outcome(chunks: step, stop: .stalled) }
        }
        return Outcome(chunks: limit, stop: .limit)
    }
}


struct ClickPlacement {
    let fraction: CGPoint
    let offset: CGPoint

    static func isRequested(_ args: [String: Any]) -> Bool {
        ["anchor", "offset_x", "offset_y"].contains { args[$0] != nil }
    }

    init(_ args: [String: Any]) throws {
        let anchor = try ActionOptions.string("anchor", in: args) ?? "center"
        switch anchor {
        case "center": fraction = CGPoint(x: 0.5, y: 0.5)
        case "left": fraction = CGPoint(x: 0, y: 0.5)
        case "right": fraction = CGPoint(x: 1, y: 0.5)
        case "top": fraction = CGPoint(x: 0.5, y: 0)
        case "bottom": fraction = CGPoint(x: 0.5, y: 1)
        default: throw ComputerUseError.invalidArguments("anchor must be center, left, right, top or bottom")
        }
        offset = try CGPoint(x: Self.offset("offset_x", in: args), y: Self.offset("offset_y", in: args))
    }

    private static func offset(_ key: String, in args: [String: Any]) throws -> Double {
        guard let raw = args[key] else { return 0 }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw ComputerUseError.invalidArguments("\(key) must be a finite number")
        }
        return number.doubleValue
    }

    func point(in frame: CGRect) throws -> CGPoint {
        // Keep an edge anchor just inside the control, even for a thin track.
        let insetX = min(1, frame.width / 2)
        let insetY = min(1, frame.height / 2)
        let point = CGPoint(x: frame.minX + insetX + (frame.width - 2 * insetX) * fraction.x + offset.x,
                            y: frame.minY + insetY + (frame.height - 2 * insetY) * fraction.y + offset.y)
        guard frame.contains(point) else {
            throw ComputerUseError.invalidArguments("Click offsets place the point outside the control.")
        }
        return point
    }
}


struct DragOptions {
    let steps: Int?
    let hold: TimeInterval

    static func isRequested(_ args: [String: Any]) -> Bool {
        ["label", "element_index", "from_label", "from_index", "to_label", "to_index", "hold_ms", "drag_steps", "files"]
            .contains { args[$0] != nil }
    }

    init(_ args: [String: Any]) throws {
        if args["files"] != nil {
            throw ComputerUseError.backgroundUnsupported("Use a file input upload or an app file command for files. A background pointer drag cannot guarantee OS file delivery.")
        }
        steps = try ActionOptions.integer("drag_steps", in: args, range: 2...30)
        hold = try Double(ActionOptions.integer("hold_ms", in: args, range: 0...1000) ?? 0) / 1000
    }

    static func validateEndpoint(index: String?, x: Double?, y: Double?, name: String) throws {
        if index != nil, x == nil, y == nil { return }
        if index == nil, let x, let y, x.isFinite, y.isFinite { return }
        throw ComputerUseError.invalidArguments("Drag \(name) needs one control or both coordinates.")
    }
}


struct ControlWait {
    enum Condition: String, CaseIterable { case appears, disappears, valueChanged = "value_changed" }

    let label: String
    let condition: Condition
    let timeout: TimeInterval
    let fromValue: String?

    init?(_ args: [String: Any]) throws {
        guard let condition = (args["condition"] as? String).flatMap(Condition.init(rawValue:)) else { return nil }
        guard let label = try ActionOptions.string("label", in: args),
              ["text", "url_contains", "index", "element_index"].allSatisfy({ args[$0] == nil }) else {
            throw ComputerUseError.invalidArguments("This wait needs one exact label.")
        }
        self.label = label
        self.condition = condition
        timeout = try Double(ActionOptions.integer("timeout", in: args, range: 1...30) ?? 10)
        let baseline = args["from_value"] as? String
        guard args["from_value"] == nil || (condition == .valueChanged && baseline != nil) else {
            throw ComputerUseError.invalidArguments("from_value needs a string and condition value_changed.")
        }
        fromValue = baseline
    }

    enum Sample<ID: Equatable> {
        case absent, present, value(ID, String), unreadable
    }

    func run<ID: Equatable>(now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                            read: () throws -> Sample<ID>) throws -> String {
        let deadline = now() + min(timeout, max(0, BrowserCallBudget.activeRemaining ?? timeout))
        var baseline: (id: ID, value: String)?
        return try BrowserCallBudget.withDeadline(deadline) {
            while now() < deadline {
                let sample = try read()
                if now() >= deadline { break }
                switch (condition, sample) {
                case (.appears, .present), (.appears, .value):
                    return "\(label) appeared."
                case (.disappears, .absent):
                    return "\(label) is absent."
                case (.valueChanged, .value(let id, let value)):
                    if let baseline, baseline.id != id {
                        throw ComputerUseError.stateUnavailable("The control changed identity during the wait.")
                    }
                    if let previous = baseline?.value ?? fromValue, previous != value {
                        return "\(label) changed value."
                    }
                    baseline = (id, value)
                default:
                    break
                }
                pause(min(0.15, max(0, deadline - now())))
            }
            throw ComputerUseError.stateUnavailable("Timed out waiting for \(label) to satisfy \(condition.rawValue).")
        }
    }
}
