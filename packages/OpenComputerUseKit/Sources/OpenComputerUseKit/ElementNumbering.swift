import ApplicationServices
import Foundation

/// Stable element numbers. Every read of an app used to renumber its tree from 0, so one new row shifted
/// every number after it and a model acting on an old number hit the wrong control. Here an element keeps
/// the number it first got (matched by CFHash, then CFEqual, plus its role) for as long as the app keeps
/// it; a new element gets the next free number; a number is never reused for another element.
///
/// One registry per app (pid) per agent (`ClientScope`), so parallel agents never share or disturb numbers.
/// `OPEN_COMPUTER_USE_STABLE_INDEXES=0` brings back per-read numbering from 0.
final class ElementNumbering: @unchecked Sendable {
    static var isEnabled: Bool {
        let value = GodspeedSettings.environment["OPEN_COMPUTER_USE_STABLE_INDEXES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        return !["0", "false", "no", "off"].contains(value)
    }

    /// The registry for `pid` in the current agent's scope.
    static func forApp(pid: pid_t) -> ElementNumbering {
        store.current.numbering(for: pid)
    }

    /// Whether a process still runs. Tests replace it; a registry of a dead process is dropped.
    nonisolated(unsafe) static var isProcessAlive: (pid_t) -> Bool = { pid in
        kill(pid, 0) == 0 || errno == EPERM
    }

    final class PerAgent {
        private let lock = NSLock()
        private var byPID: [pid_t: ElementNumbering] = [:]
        /// Highest number any dropped (quit) app's registry had reached. A registry made after it starts here,
        /// so a relaunched app (new pid) never reuses a number the model may still hold from the old run.
        private(set) var floor = 0

        func numbering(for pid: pid_t) -> ElementNumbering {
            lock.lock()
            defer { lock.unlock() }
            if let existing = byPID[pid] { return existing }
            // A new registry: first forget those of apps that quit (their elements are dead; memory stays bounded).
            for (key, registry) in byPID where key != pid && !ElementNumbering.isProcessAlive(key) {
                floor = max(floor, registry.highWater)
                byPID[key] = nil
            }
            let made = ElementNumbering(startingAt: floor)
            byPID[pid] = made
            // A very long list of live apps: drop the least recently used.
            if byPID.count > 40 {
                for (key, registry) in byPID.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(10) where key != pid {
                    floor = max(floor, registry.highWater)
                    byPID[key] = nil
                }
            }
            return made
        }
    }
    private static let store = ScopedStore<PerAgent>(make: { _ in PerAgent() })

    /// Reads that may pass before an element that stopped appearing loses its number.
    static let keptGenerations = 3
    static let maxEntries = 40_000

    private struct Entry {
        let element: AXUIElement
        let role: String
        let number: Int
        var lastSeen: Int
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var numbersByHash: [UInt: [Int]] = [:]
    private var nextNumber = 0
    private var generation = 0
    private(set) var lastUsed = Date()
    /// The window the latest read was rooted in (a batch compares it before each element step).
    private(set) var lastWindowID: UInt32?

    init(startingAt first: Int = 0) {
        nextNumber = first
    }

    /// Numbers below this have been handed out at some point. A number below it that a read does not
    /// show belongs to an element that is gone.
    var currentWindowID: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return lastWindowID
    }

    var highWater: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextNumber
    }

    /// Starts one read of the tree. Call again before a re-walk of the same window.
    func beginSnapshot() {
        lock.lock()
        generation += 1
        lastUsed = Date()
        lock.unlock()
    }

    /// Ends a read: elements unseen for `keptGenerations` reads lose their entry (their number stays retired).
    func endSnapshot(windowID: UInt32? = nil) {
        lock.lock()
        defer { lock.unlock() }
        lastWindowID = windowID
        let cutoff = generation - Self.keptGenerations
        var drop = entries.values.filter { $0.lastSeen < cutoff }.map(\.number)
        if entries.count - drop.count > Self.maxEntries {
            let rest = entries.values.filter { $0.lastSeen >= cutoff }.sorted { $0.lastSeen < $1.lastSeen }
            drop += rest.prefix(entries.count - drop.count - Self.maxEntries).map(\.number)
        }
        for number in drop { remove(number) }
    }

    /// The element's number: the one it already has, or the next free one.
    /// `kind` tells apart things drawn from one element (an element and its summary text line).
    func number(for element: AXUIElement, role: String) -> Int {
        let hash = CFHash(element)
        lock.lock()
        defer { lock.unlock() }
        if let candidates = numbersByHash[hash] {
            for number in candidates {
                guard var entry = entries[number], entry.role == role, entry.lastSeen != generation,
                      CFEqual(entry.element, element) else { continue }
                entry.lastSeen = generation
                entries[number] = entry
                return number
            }
        }
        let number = nextNumber
        nextNumber += 1
        entries[number] = Entry(element: element, role: role, number: number, lastSeen: generation)
        numbersByHash[hash, default: []].append(number)
        return number
    }

    private func remove(_ number: Int) {
        guard let entry = entries.removeValue(forKey: number) else { return }
        let hash = CFHash(entry.element)
        numbersByHash[hash]?.removeAll { $0 == number }
        if numbersByHash[hash]?.isEmpty == true { numbersByHash[hash] = nil }
    }

    // MARK: - Remembered names (restore healing)

    /// Role and visible name an element had when a read showed it, kept per number even after the element's
    /// own entry is dropped, so a number that went away can be matched to its redrawn twin.
    private var remembered: [Int: (role: String, label: String)] = [:]
    static let maxRemembered = 20_000

    /// Records the named elements of a read. Called after each get_app_state.
    func remember(snapshot: AppSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        if remembered.count > Self.maxRemembered { remembered.removeAll() }
        for record in snapshot.elements.values {
            guard let label = SmartSteps.name(of: record) else { continue }
            remembered[record.index] = (SmartSteps.roleKey(record.role), label)
        }
    }

    func remembered(_ number: Int) -> (role: String, label: String)? {
        lock.lock()
        defer { lock.unlock() }
        return remembered[number]
    }

    /// The error for an element number that an earlier read showed and the app has since dropped.
    /// `what` is the role and name it had, when known.
    static func goneMessage(index: String, role: String? = nil, label: String? = nil) -> String {
        var what = ""
        if let label, !label.isEmpty {
            what = " (" + (role.flatMap { $0.isEmpty ? nil : $0 + " " } ?? "") + "\"\(label.prefix(40))\")"
        }
        return "stale: element \(index)\(what) is gone, nothing sent. Call get_app_state for the current numbers."
    }

    static func isGone(_ error: Error) -> Bool {
        if case .elementGone? = error as? ComputerUseError { return true }
        return false
    }
}

/// Restore healing: when element N is gone but its role and name are known, the one control now showing that
/// role and name is the same control redrawn. Zero or several matches are never guessed between.
enum StaleHealing {
    enum Outcome: Equatable {
        case use(index: Int, note: String)
        case refuse(String)
    }

    /// A matching name proves nothing across documents or application lifetimes. Recovery is local to
    /// the original observation; the caller keeps this same window pin through the eventual dispatch.
    static func recover(index: String, role: String?, label: String?, observedWindow: NativeWindowObservation?,
                        currentWindow: NativeWindowObservation?, nodes: [SmartSteps.Node]) -> Outcome {
        guard let observedWindow, let currentWindow,
              observedWindow.matches(windowID: currentWindow.id, app: currentWindow.app) else {
            return .refuse("The observed window or application changed. Read the intended window again; nothing was sent.")
        }
        return resolve(index: index, role: role, label: label, nodes: nodes)
    }

    static func resolve(index: String, role: String?, label: String?, nodes: [SmartSteps.Node]) -> Outcome {
        let wantedRole = role.map { SmartSteps.roleKey($0) }.flatMap { $0.isEmpty ? nil : $0 }
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else {
            return .refuse(ElementNumbering.goneMessage(index: index))
        }
        let named = nodes.filter { $0.name?.trimmingCharacters(in: .whitespaces) == label }
        let matches = named.filter { wantedRole == nil || SmartSteps.roleKey($0.role) == wantedRole }
        if matches.count == 1, let found = matches.first {
            return .use(index: found.index, note: "(element \(index) was redrawn; used \(found.index) \"\(label.prefix(40))\")")
        }
        var message = ElementNumbering.goneMessage(index: index, role: wantedRole, label: label)
        let candidates: [SmartSteps.Node]
        if matches.count > 1 {
            candidates = matches
            message += " \(matches.count) controls match now: "
        } else {
            let lowered = label.lowercased()
            candidates = nodes.filter {
                guard let name = $0.name?.lowercased(), name.count >= 3 else { return false }
                return name.contains(lowered) || lowered.contains(name)
            }
            message += candidates.isEmpty ? " No control has that name now." : " None matches exactly. Close: "
        }
        let shown = candidates.sorted { $0.index < $1.index }.prefix(5).map {
            "\($0.index) \(SmartSteps.roleKey($0.role)) \"\(($0.name ?? "").prefix(40))\""
        }
        return .refuse(message + shown.joined(separator: ", "))
    }
}
