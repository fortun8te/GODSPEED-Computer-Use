import ApplicationServices
import CoreGraphics
import Foundation

/// Two ways to tell that a window has settled, kept together:
/// - Still (action read-back): the window's pixels stopped changing.
/// - Not busy (get_app_state settle and batch): the window shows no busy sign.
///
/// Frame-driven settle for action read-back. Instead of always sleeping a fixed
/// interval before reading a window back, sample a small grayscale thumbnail of
/// the window and return once two consecutive samples match (the window has
/// stopped animating: a sheet slide, a menu fade, a window open). The fixed
/// interval stays the cap, so a window still changing at the cap is read exactly
/// as before; a missing sample falls back to the full cap.
/// Disable with OPEN_COMPUTER_USE_SETTLE_BY_FRAME=0.
///
/// Waiting for a window to settle the way Codex's `waitForUIToSettle` judges it: by busy signs in the window
/// (an AXBusyIndicator, an AXWebArea whose AXLoaded is false, an element whose AXElementBusy is true), with no
/// quiet period first. A quiet period is paid by every read whether or not anything moved; a window showing no
/// busy sign is read after one scan.
enum WindowSettle {
    // MARK: Still: frame-driven settle for action read-back

    static var enabled: Bool {
        let value = RequestConfiguration.environment["OPEN_COMPUTER_USE_SETTLE_BY_FRAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }

    /// Minimum wait before the first comparison, so an animation that has not started yet is not missed.
    static let floor: TimeInterval = 0.02
    /// One 60 Hz frame: sampling faster than the display refreshes would compare a frame with itself.
    static let sampleInterval: TimeInterval = 0.017
    static let thumbnailSide = 24

    /// Matching comparisons needed in a row before the window counts as still. Two
    /// guards against an animation's eased start, where frames look identical for a moment.
    static let requiredMatches = 2

    /// Waits until `sample()` returns the same fingerprint `requiredMatches` times in a row
    /// (after `floor`), or until `cap` elapses. Returns the elapsed time.
    @discardableResult
    static func waitUntilStill(
        floor: TimeInterval = floor,
        cap: TimeInterval,
        sample: () -> UInt64?
    ) -> TimeInterval {
        let start = TimingLog.now()
        let floor = min(floor, cap)
        Thread.sleep(forTimeInterval: floor)
        var previous = sample()
        var matches = 0
        while !RequestCancellation.requested && TimingLog.now() - start < cap {
            Thread.sleep(forTimeInterval: min(sampleInterval, max(0, cap - (TimingLog.now() - start))))
            guard let current = sample() else {
                previous = nil
                matches = 0
                continue
            }
            matches = current == previous ? matches + 1 : 0
            if matches >= requiredMatches { return TimingLog.now() - start }
            previous = current
        }
        return TimingLog.now() - start
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

    /// Looks at `busy` until it is false, again `interval` after each busy look, within `timeout`. Returns
    /// whether the window stopped looking busy; no look starts past the deadline. Clock and sleep are
    /// injectable for tests.
    static func wait(
        timeout: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        busy: () throws -> Bool
    ) rethrows -> Bool {
        let deadline = now() + timeout
        while !RequestCancellation.requested, try busy() {
            guard now() + interval < deadline else { return false }
            sleep(interval)
        }
        return true
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
