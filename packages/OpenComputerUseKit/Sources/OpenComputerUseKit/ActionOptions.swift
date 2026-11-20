import Foundation
import CoreFoundation
import CoreGraphics

enum ActionOptions {
    // These actions have their own delivery checks. Skip legacy vision, retargeting and focus borrowing.
    static func usesStrictRoute(_ tool: String, _ args: [String: Any]) -> Bool {
        switch tool {
        case "scroll_into_view": return true
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
