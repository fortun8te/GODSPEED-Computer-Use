import Foundation
import XCTest
@testable import OpenComputerUseKit

final class NegativeLookupCacheTests: XCTestCase {
    private func key(app: String = "com.example.app", window: Int = 1,
                     label: String = "Save", role: String = "AXButton") -> NegativeLookupCache.Key {
        NegativeLookupCache.Key(app: app, windowID: window, label: label, role: role)
    }

    func testMissIsKnownWithinTTL() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(), generation: 5, now: 10)
        XCTAssertTrue(cache.isKnownMiss(key: key(), generation: 5, now: 10))
        XCTAssertTrue(cache.isKnownMiss(key: key(), generation: 5, now: 11.9))
    }

    func testMissExpiresAtTTL() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(), generation: 5, now: 10)
        // The TTL is "younger than", so exactly 2 seconds later is already unknown.
        XCTAssertFalse(cache.isKnownMiss(key: key(), generation: 5, now: 12))
        XCTAssertFalse(cache.isKnownMiss(key: key(), generation: 5, now: 20))
    }

    func testClockGoingBackwardsIsUnknown() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(), generation: 5, now: 10)
        XCTAssertFalse(cache.isKnownMiss(key: key(), generation: 5, now: 9))
    }

    func testNewerGenerationIsUnknown() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(), generation: 5, now: 10)
        XCTAssertFalse(cache.isKnownMiss(key: key(), generation: 6, now: 10.5))
        XCTAssertFalse(cache.isKnownMiss(key: key(), generation: 4, now: 10.5))
    }

    func testDifferentWindowIsUnknown() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(window: 1), generation: 5, now: 10)
        XCTAssertFalse(cache.isKnownMiss(key: key(window: 2), generation: 5, now: 10))
        XCTAssertTrue(cache.isKnownMiss(key: key(window: 1), generation: 5, now: 10))
    }

    func testLabelIsNormalizedButRoleIsNot() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(label: "  Save  ", role: "AXButton"), generation: 1, now: 0)
        XCTAssertTrue(cache.isKnownMiss(key: key(label: "save", role: "AXButton"), generation: 1, now: 0))
        XCTAssertTrue(cache.isKnownMiss(key: key(label: "SAVE\n", role: "AXButton"), generation: 1, now: 0))
        XCTAssertFalse(cache.isKnownMiss(key: key(label: "save", role: "AXLink"), generation: 1, now: 0))
        XCTAssertFalse(cache.isKnownMiss(key: key(label: "saved", role: "AXButton"), generation: 1, now: 0))
    }

    func testOldestEntryIsEvictedFirst() {
        let cache = NegativeLookupCache(ttl: 2, capacity: 2)
        cache.recordMiss(key: key(label: "a"), generation: 1, now: 0)
        cache.recordMiss(key: key(label: "b"), generation: 1, now: 0)
        cache.recordMiss(key: key(label: "c"), generation: 1, now: 0)
        XCTAssertFalse(cache.isKnownMiss(key: key(label: "a"), generation: 1, now: 0))
        XCTAssertTrue(cache.isKnownMiss(key: key(label: "b"), generation: 1, now: 0))
        XCTAssertTrue(cache.isKnownMiss(key: key(label: "c"), generation: 1, now: 0))
    }

    func testRerecordingRefreshesEvictionOrder() {
        let cache = NegativeLookupCache(ttl: 2, capacity: 2)
        cache.recordMiss(key: key(label: "a"), generation: 1, now: 0)
        cache.recordMiss(key: key(label: "b"), generation: 1, now: 0)
        cache.recordMiss(key: key(label: "a"), generation: 1, now: 0.5)
        cache.recordMiss(key: key(label: "c"), generation: 1, now: 0.5)
        XCTAssertTrue(cache.isKnownMiss(key: key(label: "a"), generation: 1, now: 0.5))
        XCTAssertFalse(cache.isKnownMiss(key: key(label: "b"), generation: 1, now: 0.5))
    }

    func testInvalidateRemovesOnlyThatApp() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(app: "com.example.one"), generation: 1, now: 0)
        cache.recordMiss(key: key(app: "com.example.two"), generation: 1, now: 0)
        cache.invalidate(app: "com.example.one")
        XCTAssertFalse(cache.isKnownMiss(key: key(app: "com.example.one"), generation: 1, now: 0))
        XCTAssertTrue(cache.isKnownMiss(key: key(app: "com.example.two"), generation: 1, now: 0))
    }

    func testRemoveAllClearsEverything() {
        let cache = NegativeLookupCache(ttl: 2)
        cache.recordMiss(key: key(app: "com.example.one"), generation: 1, now: 0)
        cache.recordMiss(key: key(app: "com.example.two"), generation: 1, now: 0)
        cache.removeAll()
        XCTAssertFalse(cache.isKnownMiss(key: key(app: "com.example.one"), generation: 1, now: 0))
        XCTAssertFalse(cache.isKnownMiss(key: key(app: "com.example.two"), generation: 1, now: 0))
    }

    func testConcurrentRecordLookupAndInvalidateStayBounded() {
        let cache = NegativeLookupCache(ttl: 2, capacity: 16)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<500 {
                let k = key(label: "item \(worker)-\(i)")
                cache.recordMiss(key: k, generation: 1, now: 10)
                _ = cache.isKnownMiss(key: k, generation: 1, now: 10)
                cache.invalidate(app: "com.example.other")
            }
        }
        var known = 0
        for worker in 0..<8 {
            for i in 0..<500
            where cache.isKnownMiss(key: key(label: "item \(worker)-\(i)"), generation: 1, now: 10) {
                known += 1
            }
        }
        XCTAssertLessThanOrEqual(known, 16)
    }
}
