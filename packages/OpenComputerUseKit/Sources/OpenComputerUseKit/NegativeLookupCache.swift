import Foundation

/// Remembers element searches that just found nothing, so the same search is not repeated at once.
///
/// A miss is trusted only for the same window, snapshot and observed-change generation, and for a short
/// time (`ttl`). A newer generation, another window, or an expired entry means "search again".
/// The cache never reports a hit. The caller passes in the time, so tests can drive it.
/// It is thread-safe. Its size is bounded: the oldest recorded entry is dropped first.
final class NegativeLookupCache {
    /// Identifies one search: the app, the window, and the normalized query.
    struct Key: Hashable {
        let app: String
        let windowID: Int
        let label: String
        let role: String

        init(app: String, windowID: Int, label: String, role: String) {
            self.app = app
            self.windowID = windowID
            // Letter case and outer spaces do not make a different search.
            self.label = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            self.role = role
        }
    }

    private struct Entry {
        let generation: Int
        let changeGeneration: UInt64?
        let recordedAt: TimeInterval
        // Higher means recorded later. Used to find the oldest entry.
        let sequence: UInt64
    }

    let ttl: TimeInterval
    let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var nextSequence: UInt64 = 0

    init(ttl: TimeInterval = 2, capacity: Int = 256) {
        self.ttl = ttl
        self.capacity = max(1, capacity)
    }

    /// Records that the search for `key` found nothing at this generation and time.
    func recordMiss(key: Key, generation: Int, changeGeneration: UInt64? = nil, now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        nextSequence += 1
        entries[key] = Entry(generation: generation, changeGeneration: changeGeneration, recordedAt: now, sequence: nextSequence)
        evictIfNeeded()
    }

    /// True only if the same search missed at this generation and is still younger than `ttl`.
    func isKnownMiss(key: Key, generation: Int, changeGeneration: UInt64? = nil, now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return false }
        let age = now - entry.recordedAt
        // A newer generation, an expired entry, or a clock that went backwards means "unknown".
        return entry.generation == generation && entry.changeGeneration == changeGeneration && age >= 0 && age < ttl
    }

    /// Forgets every miss recorded for `app`.
    func invalidate(app: String) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.key.app != app }
    }

    /// Forgets every recorded miss.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// A label search in two steps, as `resolveLabel` runs it: `find` on the cached state first, then, unless this
    /// same search already missed on the current generation, one `readFresh` and `find` again. A miss is recorded
    /// only after a fresh read with no observed change during it, so a repeat within the TTL does not extend
    /// the trust. Returns the state the last search ran on, its hit, and whether a fresh read ran.
    func searchTwoStep<State, Hit>(
        keyFor: (State) -> Key,
        cached: State?,
        generation: () -> Int,
        changeGeneration: (State) -> UInt64? = { _ in nil },
        now: () -> TimeInterval,
        find: (State) throws -> Hit?,
        readFresh: () throws -> State
    ) rethrows -> (state: State, hit: Hit?, freshRead: Bool) {
        if let cached {
            if let hit = try find(cached) { return (cached, hit, false) }
            if isKnownMiss(key: keyFor(cached), generation: generation(), changeGeneration: changeGeneration(cached), now: now()) {
                return (cached, nil, false)
            }
        }
        let beforeRead = cached.flatMap(changeGeneration)
        let fresh = try readFresh()
        let hit = try find(fresh)
        let afterRead = changeGeneration(fresh)
        if hit == nil, beforeRead == afterRead {
            recordMiss(key: keyFor(fresh), generation: generation(), changeGeneration: afterRead, now: now())
        }
        return (fresh, hit, true)
    }

    /// Drops the oldest entry when the cache grows past its capacity.
    /// Caller must hold the lock.
    private func evictIfNeeded() {
        guard entries.count > capacity,
              let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence }) else { return }
        entries[oldest.key] = nil
    }
}
