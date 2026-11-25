import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class AXSnapshotReadCacheTests: XCTestCase {
    func testPasswordReadsStopBeforeValueOrSelectionRequest() {
        XCTAssertFalse(AXSnapshotReadCache.names.contains("AXValue"))
        XCTAssertFalse(AXSnapshotReadCache.names.contains("AXSelectedText"))
        let element = AXUIElementCreateApplication(120999)
        var reads: [String] = []
        let cache = AXSnapshotReadCache(batch: { _ in
            ["AXSubrole": .value("AXSecureTextField" as CFString)]
        }, single: { _, name in
            reads.append(name)
            return (.success, "secret" as CFString)
        })
        XCTAssertNil(cache.value(element, "AXValue"))
        XCTAssertNil(cache.value(element, "AXSelectedText"))
        XCTAssertTrue(reads.isEmpty)
    }

    func testUnknownPasswordClassificationCannotTriggerATextRead() {
        let element = AXUIElementCreateApplication(120999)
        var reads: [String] = []
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, single: { _, name in
            reads.append(name)
            if name == "AXSubrole" {
                return reads.count == 1 ? (.cannotComplete, nil) : (.success, "AXSecureTextField" as CFString)
            }
            return (.success, "secret" as CFString)
        })
        XCTAssertNil(cache.value(element, "AXValue"))
        XCTAssertNil(cache.value(element, "AXSelectedText"))
        XCTAssertEqual(reads, ["AXSubrole", "AXSubrole"])
    }

    func testOrdinaryFieldTextCanRetryAfterTransientClassificationFailure() {
        let element = AXUIElementCreateApplication(120999)
        var classifications = 0
        var textReads = 0
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, single: { _, name in
            if name == "AXSubrole" {
                classifications += 1
                return classifications == 1 ? (.cannotComplete, nil) : (.attributeUnsupported, nil)
            }
            textReads += 1
            return (.success, "ordinary text" as CFString)
        })
        XCTAssertNil(cache.value(element, "AXValue"))
        XCTAssertEqual(textReads, 0)
        XCTAssertEqual(cache.value(element, "AXValue") as? String, "ordinary text")
        XCTAssertEqual(cache.value(element, "AXValue") as? String, "ordinary text")
        XCTAssertEqual(classifications, 2)
        XCTAssertEqual(textReads, 1)
    }

    func testMalformedSubroleCannotAuthorizeTextReads() {
        var textReads = 0
        let cache = AXSnapshotReadCache(batch: { _ in ["AXSubrole": .value(NSNumber(value: 7))] }, single: { _, _ in
            textReads += 1
            return (.success, "secret" as CFString)
        })
        XCTAssertNil(cache.value(AXUIElementCreateApplication(120999), "AXValue"))
        XCTAssertEqual(textReads, 0)
    }

    func testEqualAXReferencesShareTheBatchAndAbsentValuesDoNotRefetch() {
        var batches = 0, singles = 0
        let cache = AXSnapshotReadCache(batch: { _ in
            batches += 1
            return ["AXRole": .value("AXButton" as CFString), "AXHelp": .absent]
        }, single: { _, _ in singles += 1; return (.attributeUnsupported, nil) })
        let first = AXUIElementCreateApplication(123)
        let equalReference = AXUIElementCreateApplication(123)
        XCTAssertEqual(cache.value(first, "AXRole") as? String, "AXButton")
        XCTAssertEqual(cache.value(equalReference, "AXRole") as? String, "AXButton")
        XCTAssertNil(cache.value(first, "AXHelp"))
        XCTAssertNil(cache.value(equalReference, "AXHelp"))
        XCTAssertEqual(batches, 1)
        XCTAssertEqual(singles, 0)
    }

    func testUnavailableBatchFallsBackAndDoesNotCacheTransientFailure() {
        var singles = 0
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, single: { _, _ in
            singles += 1
            return singles == 1 ? (.cannotComplete, nil) : (.success, "fresh" as CFString)
        })
        let element = AXUIElementCreateApplication(123)
        XCTAssertNil(cache.value(element, "AXTitle"))
        XCTAssertEqual(cache.value(element, "AXTitle") as? String, "fresh")
        XCTAssertEqual(cache.value(element, "AXTitle") as? String, "fresh")
        XCTAssertEqual(singles, 2)
    }

    func testEachSnapshotHasFreshStorageAndRestoresOuterScopeOnFailure() {
        enum Probe: Error { case stop }
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[AXSnapshotReadCache.key]
        defer { dictionary[AXSnapshotReadCache.key] = previous }
        let outer = AXSnapshotReadCache(batch: { _ in [:] })
        dictionary[AXSnapshotReadCache.key] = outer
        var first: AXSnapshotReadCache?
        AXSnapshotReadCache.withSnapshot { first = AXSnapshotReadCache.current }
        XCTAssertTrue(AXSnapshotReadCache.current === outer)
        XCTAssertThrowsError(try AXSnapshotReadCache.withSnapshot {
            XCTAssertFalse(AXSnapshotReadCache.current === first)
            throw Probe.stop
        })
        XCTAssertTrue(AXSnapshotReadCache.current === outer)
    }
    func testBatchErrorsNullsAndMalformedResponsesFallBackSafely() {
        func errorValue(_ error: AXError) -> AXValue {
            var value = error
            return AXValueCreate(.axError, &value)!
        }
        let decoded = AXSnapshotReadCache.decodeBatch([
            "AXButton" as CFString, errorValue(.attributeUnsupported), errorValue(.noValue),
            errorValue(.cannotComplete), NSNull(),
        ], names: ["role", "unsupported", "empty", "retry", "null"])
        XCTAssertEqual(decoded["role"]?.value as? String, "AXButton")
        XCTAssertNotNil(decoded["unsupported"])
        XCTAssertNil(decoded["unsupported"]?.value)
        XCTAssertNotNil(decoded["empty"])
        XCTAssertNil(decoded["retry"])
        XCTAssertNil(decoded["null"])
        XCTAssertTrue(AXSnapshotReadCache.decodeBatch([], names: ["role"]).isEmpty)
    }

    func testActionsAndSettableFailuresRetryButSuccessIsCached() {
        var actions = 0, settable = 0
        let cache = AXSnapshotReadCache(actions: { _ in
            actions += 1
            return actions == 1 ? (.cannotComplete, nil) : (.success, ["AXPress"])
        }, settable: { _, _ in
            settable += 1
            return settable == 1 ? (.cannotComplete, false) : (.success, true)
        })
        let element = AXUIElementCreateApplication(123)
        XCTAssertNil(cache.actionNames(element))
        XCTAssertEqual(cache.actionNames(element), ["AXPress"])
        XCTAssertEqual(cache.actionNames(element), ["AXPress"])
        XCTAssertFalse(cache.isSettable(element, "AXValue"))
        XCTAssertTrue(cache.isSettable(element, "AXValue"))
        XCTAssertTrue(cache.isSettable(element, "AXValue"))
        XCTAssertEqual(actions, 2)
        XCTAssertEqual(settable, 2)
    }
}
