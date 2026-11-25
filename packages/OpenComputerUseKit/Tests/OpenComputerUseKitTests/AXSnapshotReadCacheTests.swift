import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class AXSnapshotReadCacheTests: XCTestCase {
    func testUncachedTextReadsAlsoRequireResolvedPasswordClassification() {
        XCTAssertFalse(AXSnapshotReadCache.permitsTextRead(subroleError: .cannotComplete, subrole: nil))
        XCTAssertFalse(AXSnapshotReadCache.permitsTextRead(subroleError: .success, subrole: nil))
        XCTAssertFalse(AXSnapshotReadCache.permitsTextRead(subroleError: .success, subrole: NSNumber(value: 7)))
        XCTAssertFalse(AXSnapshotReadCache.permitsTextRead(subroleError: .success, subrole: "AXSecureTextField" as CFString))
        XCTAssertTrue(AXSnapshotReadCache.permitsTextRead(subroleError: .attributeUnsupported, subrole: nil))
        XCTAssertTrue(AXSnapshotReadCache.permitsTextRead(subroleError: .noValue, subrole: nil))
        XCTAssertFalse(AXSnapshotReadCache.permitsTextRead(subroleError: .noValue, subrole: "AXSecureTextField" as CFString))
        XCTAssertTrue(AXSnapshotReadCache.permitsTextRead(subroleError: .success, subrole: "AXSearchField" as CFString))
    }

    func testScalarBatchDoesNotReadAnyChildArray() {
        XCTAssertTrue(Set(AXSnapshotReadCache.names).isDisjoint(with: AXSnapshotReadCache.arrayNames))
        var childReads = 0
        let cache = AXSnapshotReadCache(batch: { _ in ["AXRole": .value("AXList" as CFString)] },
            count: { _, _ in childReads += 1; return (.success, 1_000_000) },
            page: { _, _, _ in childReads += 1; return (.success, []) })
        XCTAssertEqual(cache.value(AXUIElementCreateApplication(123), "AXRole") as? String, "AXList")
        XCTAssertEqual(childReads, 0)
    }

    func testWideChildProviderReceivesOnlyTheRemainingBudgetAndReusesItsPrefix() {
        let element = AXUIElementCreateApplication(123)
        var counts = 0
        var requested: [Int] = []
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, count: { _, _ in
            counts += 1; return (.success, 1_000_000)
        }, page: { _, _, limit in
            requested.append(limit)
            return (.success, (0..<limit).map { AXUIElementCreateApplication(Int32(1000 + $0)) })
        })
        let first = cache.array(element, "AXChildren", limit: 7)
        XCTAssertEqual(first.values.count, 7)
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(cache.array(element, "AXChildren", limit: 3).values.count, 3)
        XCTAssertEqual(cache.array(element, "AXChildren", limit: 9).values.count, 9)
        XCTAssertEqual(counts, 1)
        XCTAssertEqual(requested, [7, 9])
    }

    func testZeroChildBudgetNeverFetchesAPageAndStillReportsOmissions() {
        var pages = 0
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, count: { _, _ in (.success, 100) }, page: { _, _, _ in
            pages += 1; return (.success, [])
        })
        let result = cache.array(AXUIElementCreateApplication(123), "AXChildren", limit: 0)
        XCTAssertTrue(result.values.isEmpty)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(pages, 0)
    }

    func testTransientChildCountAndPageFailuresCanRetry() {
        let element = AXUIElementCreateApplication(123)
        var counts = 0, pages = 0
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, count: { _, _ in
            counts += 1
            return counts == 1 ? (.cannotComplete, 0) : (.success, 1)
        }, page: { _, _, _ in
            pages += 1
            return pages == 1 ? (.cannotComplete, nil) : (.success, [element])
        })
        XCTAssertTrue(cache.array(element, "AXChildren", limit: 1).truncated)
        XCTAssertTrue(cache.array(element, "AXChildren", limit: 1).truncated)
        XCTAssertFalse(cache.array(element, "AXChildren", limit: 1).truncated)
        XCTAssertFalse(cache.array(element, "AXChildren", limit: 1).truncated)
        XCTAssertEqual(counts, 2)
        XCTAssertEqual(pages, 2)
    }

    func testShortProviderPageIsIncompleteAndDoesNotPoisonTheNextRead() {
        let element = AXUIElementCreateApplication(123)
        var pages = 0
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, count: { _, _ in (.success, 2) }, page: { _, _, _ in
            pages += 1
            return (.success, pages == 1 ? [element] : [element, element])
        })
        XCTAssertTrue(cache.array(element, "AXChildren", limit: 2).truncated)
        XCTAssertFalse(cache.array(element, "AXChildren", limit: 2).truncated)
        XCTAssertEqual(pages, 2)
    }

    func testGenericArrayReadsAlsoHaveAHardCap() {
        let element = AXUIElementCreateApplication(123)
        var largestRequest = 0
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, count: { _, _ in (.success, Int.max) }, page: { _, _, limit in
            largestRequest = max(largestRequest, limit)
            return (.success, Array(repeating: element, count: limit))
        })
        XCTAssertEqual((cache.value(element, "AXChildren") as? [AXUIElement])?.count, AXSnapshotReadCache.maximumArrayRead)
        XCTAssertEqual(largestRequest, AXSnapshotReadCache.maximumArrayRead)
    }

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
