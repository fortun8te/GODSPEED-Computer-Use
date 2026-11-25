import ApplicationServices
import CoreGraphics
import Foundation

/// Bounded settling for window reads. Action readback samples small frames.
/// An explicit settle also waits out AX busy indicators.
enum WindowSettle {
    // MARK: Still: frame-driven settle for action read-back

    static var enabled: Bool { frameSamplingEnabled(environment: RequestConfiguration.environment) }

    static func frameSamplingEnabled(environment: [String: String]) -> Bool {
        let value = environment["OPEN_COMPUTER_USE_SETTLE_BY_FRAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }

    static let floor: TimeInterval = 0.02
    static let sampleInterval: TimeInterval = 0.04
    static let quietPeriod: TimeInterval = 0.12
    static let thumbnailSide = 24

    /// Reads at the cap if the frame keeps changing, capture fails, or AX is still busy.
    @discardableResult
    static func waitUntilStill(
        floor: TimeInterval = floor,
        cap: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        axBusy: () -> Bool = { false },
        sample: () -> UInt64?
    ) -> TimeInterval {
        guard !RequestCancellation.requested else { return 0 }
        let start = now()
        let deadline = start + cap
        // Skip capture entirely if there is no room to establish a quiet period.
        guard cap > floor + quietPeriod else {
            if cap > 0 { sleep(cap) }
            return now() - start
        }
        sleep(min(floor, cap))
        var previous: UInt64?
        var stableSince: TimeInterval?
        while !RequestCancellation.requested, now() < deadline {
            let current = sample()
            guard !RequestCancellation.requested, now() < deadline else { break }
            let sawBusy = current == nil || axBusy()
            let sampledAt = now()
            guard !RequestCancellation.requested, sampledAt < deadline else { break }
            if let current, !sawBusy {
                if current != previous || stableSince == nil { stableSince = sampledAt }
                if let since = stableSince, sampledAt - since >= quietPeriod { break }
            } else {
                stableSince = nil
            }
            previous = current
            let remaining = deadline - now()
            if remaining <= 0 { break }
            sleep(min(sampleInterval, remaining))
        }
        return now() - start
    }

    /// FNV-1a over a 24x24 grayscale rendering of the image.
    static func fingerprint(of image: CGImage) -> UInt64? {
        let side = thumbnailSide
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
              ),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for index in 0..<(side * side) {
            hash ^= UInt64(bytes[index])
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: Not busy: busy-sign settle for get_app_state

    /// Breadth first, so the toolbar and a page's top levels come first; deep enough for a web area's spinner.
    static let scanNodes = 100
    static let scanDepth = 25
    /// How long a busy window waits before it is looked at again.
    static let interval: TimeInterval = 0.05

    /// What the scan reads from one node.
    struct Signs<Element> {
        let role: String?
        let children: [Element]
        let busy: Bool?
        let loaded: Bool?
    }

    /// Bounded breadth-first scan. For a settle decision, unread branches veto quiescence.
    static func busy<Element>(from root: Element, requireComplete: Bool = false,
                              read: ([Element]) -> [Signs<Element>?]) -> Bool {
        var nodes: [(element: Element, depth: Int)] = [(root, 0)]
        var signs: [Signs<Element>?] = []
        var next = 0
        while next < nodes.count {
            guard !RequestCancellation.requested else { return true }
            if next == signs.count { signs += read(nodes[next...].map(\.element)) }
            guard !RequestCancellation.requested else { return true }
            let depth = nodes[next].depth
            defer { next += 1 }
            guard next < signs.count, let node = signs[next] else {
                if requireComplete { return true }
                continue
            }
            if node.role == kAXBusyIndicatorRole || (node.role == "AXWebArea" && node.loaded == false) || node.busy == true {
                return true
            }
            let remaining = depth < scanDepth ? scanNodes - nodes.count : 0
            if requireComplete, node.children.count > remaining { return true }
            nodes += node.children.prefix(remaining).map { ($0, depth + 1) }
        }
        return false
    }

    /// Requires a quiet interval between successful non-busy scans. A busy scan resets the timer.
    static func wait(
        timeout: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        // With a pid, the interval sleep ends early on an AX notification for that app. The quiet-period rule is unchanged.
        pid: pid_t? = nil,
        monitor: AXChangeMonitor? = nil,
        busy: () throws -> Bool
    ) rethrows -> Bool {
        let deadline = now() + timeout
        var quietSince: TimeInterval?
        while !RequestCancellation.requested, now() < deadline {
            let watch = pid.map { (monitor ?? AXChangeMonitor.shared, $0) }
            let token = watch.map { $0.0.track($0.1) }
            guard !RequestCancellation.requested, now() < deadline else { return false }
            let sawBusy = try busy()
            let sampledAt = now()
            guard !RequestCancellation.requested, sampledAt < deadline else { return false }
            if sawBusy {
                quietSince = nil
            } else if let since = quietSince {
                if sampledAt - since >= quietPeriod { return true }
            } else {
                quietSince = sampledAt
            }
            let remaining = deadline - sampledAt
            if remaining <= 0 { break }
            if let watch, let token {
                watch.0.awaitChange(pid: watch.1, since: token, upTo: min(interval, remaining))
            } else {
                sleep(min(interval, remaining))
            }
        }
        return false
    }

    /// A cheap AX veto on the frame path. A full tree scan is reserved for explicit settle reads.
    static func rootShowsBusy(_ root: AXUIElement?) -> Bool {
        guard let root else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(root, "AXElementBusy" as CFString, &value) == .success
            && value as? Bool == true
    }

    /// Split a frontier into a fixed number of lanes. Read signs in the
    /// original node order without making one concurrent AX call per node.
    static let scanConcurrency = 4

    static func scanRanges(count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let lanes = min(scanConcurrency, count)
        return (0..<lanes).map { lane in
            (lane * count / lanes)..<((lane + 1) * count / lanes)
        }
    }

    static func readAll(_ elements: [AXUIElement]) -> [Signs<AXUIElement>?] {
        // Each slot is written by its own iteration only.
        nonisolated(unsafe) let signs = UnsafeMutableBufferPointer<Signs<AXUIElement>?>.allocate(capacity: elements.count)
        nonisolated(unsafe) let elements = elements
        signs.initialize(repeating: nil)
        defer { signs.deinitialize(); signs.deallocate() }
        let ranges = scanRanges(count: elements.count)
        // Dispatch workers do not inherit the request's TaskLocal cancellation token.
        let cancellation = RequestCancellation.current
        DispatchQueue.concurrentPerform(iterations: ranges.count) { lane in
            for index in ranges[lane] {
                guard cancellation?.isCancelled != true else { break }
                signs[index] = read(elements[index])
            }
        }
        return Array(signs)
    }

    private static let attributes = [kAXRoleAttribute, kAXChildrenAttribute, "AXElementBusy", "AXLoaded"]

    private static func read(_ element: AXUIElement) -> Signs<AXUIElement>? {
        var copied: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &copied) == .success,
              let values = copied as? [AnyObject] else { return nil }
        return decodeSigns(values)
    }

    /// AX can report success for the batch while individual attributes failed.
    /// Unsupported optional attributes are ordinary absence; transient failures
    /// and malformed values leave this branch unread, so it cannot prove quiet.
    static func decodeSigns(_ values: [AnyObject]) -> Signs<AXUIElement>? {
        guard values.count == attributes.count else { return nil }
        var decoded = AXSnapshotReadCache.decodeBatch(values, names: attributes)
        // The multiple-attribute API also uses CFNull for unsupported attributes.
        for (name, value) in zip(attributes, values) where value is NSNull { decoded[name] = .absent }
        guard decoded.count == attributes.count,
              let role = decoded[kAXRoleAttribute]?.value as? String else { return nil }
        var children: [AXUIElement] = []
        if let value = decoded[kAXChildrenAttribute]?.value {
            guard let elements = value as? [AXUIElement] else { return nil }
            children = elements
        }
        for name in ["AXElementBusy", "AXLoaded"] {
            if let value = decoded[name]?.value, value as? Bool == nil { return nil }
        }
        return Signs(role: role, children: children,
                     busy: decoded["AXElementBusy"]?.value as? Bool,
                     loaded: decoded["AXLoaded"]?.value as? Bool)
    }
}
