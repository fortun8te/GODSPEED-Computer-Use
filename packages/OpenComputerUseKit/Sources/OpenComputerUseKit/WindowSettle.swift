import ApplicationServices
import CoreGraphics
import Foundation

/// Bounded settling for window reads. Action readback samples small frames.
/// An explicit settle also waits out AX busy indicators.
enum WindowSettle {
    // MARK: Still: frame-driven settle for action read-back

    static let enabled: Bool = {
        let value = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_SETTLE_BY_FRAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }()

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
        while now() < deadline {
            let current = sample()
            if let current, now() < deadline, !axBusy() {
                let sampledAt = now()
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

    /// Whether the window under `root` shows a busy sign, breadth first to `scanNodes` nodes and `scanDepth`
    /// levels. When the walk has read every node it queued, it reads all newly queued ones in one `read` call
    /// (in order), so it visits the same nodes in the same order, with the same answer, as reading one at a time.
    static func busy<Element>(from root: Element, read: ([Element]) -> [Signs<Element>?]) -> Bool {
        var nodes: [(element: Element, depth: Int)] = [(root, 0)]
        var signs: [Signs<Element>?] = []
        var next = 0
        while next < nodes.count {
            if next == signs.count { signs += read(nodes[next...].map(\.element)) }
            let depth = nodes[next].depth
            next += 1
            guard let node = signs[next - 1] else { continue }
            if node.role == kAXBusyIndicatorRole || (node.role == "AXWebArea" && node.loaded == false) || node.busy == true {
                return true
            }
            if depth < scanDepth {
                nodes += node.children.prefix(max(0, scanNodes - nodes.count)).map { ($0, depth + 1) }
            }
        }
        return false
    }

    /// Requires a quiet interval between successful non-busy scans. A busy scan resets the timer.
    static func wait(
        timeout: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        busy: () throws -> Bool
    ) rethrows -> Bool {
        let deadline = now() + timeout
        var quietSince: TimeInterval?
        while now() < deadline {
            let sawBusy = try busy()
            let sampledAt = now()
            guard sampledAt <= deadline else { return false }
            if sawBusy {
                quietSince = nil
            } else if let since = quietSince {
                if sampledAt - since >= quietPeriod { return true }
            } else {
                quietSince = sampledAt
            }
            let remaining = deadline - sampledAt
            if remaining <= 0 { break }
            sleep(min(interval, remaining))
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

    /// Each element's signs, read side by side: the app answers one read while the next is on its way.
    static func readAll(_ elements: [AXUIElement]) -> [Signs<AXUIElement>?] {
        // Each slot is written by its own iteration only.
        nonisolated(unsafe) let signs = UnsafeMutableBufferPointer<Signs<AXUIElement>?>.allocate(capacity: elements.count)
        nonisolated(unsafe) let elements = elements
        signs.initialize(repeating: nil)
        defer { signs.deinitialize(); signs.deallocate() }
        DispatchQueue.concurrentPerform(iterations: elements.count) { signs[$0] = read(elements[$0]) }
        return Array(signs)
    }

    private static let attributes = [kAXRoleAttribute, kAXChildrenAttribute, "AXElementBusy", "AXLoaded"]

    private static func read(_ element: AXUIElement) -> Signs<AXUIElement>? {
        var copied: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &copied) == .success,
              let values = copied as? [Any], values.count == 4 else { return nil }
        return Signs(role: values[0] as? String, children: values[1] as? [AXUIElement] ?? [],
                     busy: values[2] as? Bool, loaded: values[3] as? Bool)
    }
}
