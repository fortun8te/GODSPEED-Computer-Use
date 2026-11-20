import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Learned read routes: the query arm (targeted search or full tree) and the settle wait. Only verified outcomes
/// reward an arm, risky lookups never explore, a pinned window keeps the direct route, and state persists.
final class ReadRoutingWiringTests: XCTestCase {
    private func tempLearning() throws -> AdaptiveLearning {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AdaptiveLearning(directory: dir)
    }

    func testRiskyLookupsNeverExploreEvenWhenTheFullTreeArmIsMature() throws {
        let learning = try tempLearning()
        for _ in 0..<30 {
            ReadRouting.recordQuery(app: "mail", arm: "full_tree_read", matches: 1, latencyMs: 4, learning: learning)
        }
        for _ in 0..<200 {
            XCTAssertEqual(ReadRouting.queryArm(app: "mail", risky: true, learning: learning), "targeted_query")
            XCTAssertEqual(ReadRouting.queryArm(app: "mail", risky: ReadRouting.isRiskyLookup("Send"), learning: learning), "targeted_query")
        }
        XCTAssertEqual(learning.routes.explorationStats(app: "mail", action: "query").explorations, 0)
    }

    func testRiskyLookupTextIsDetectedInEnglishAndDutch() {
        XCTAssertTrue(ReadRouting.isRiskyLookup("Delete"))
        XCTAssertTrue(ReadRouting.isRiskyLookup("Verzenden"))
        XCTAssertFalse(ReadRouting.isRiskyLookup("Search field"))
        XCTAssertFalse(ReadRouting.isRiskyLookup(nil))
    }

    func testArmWithThreeUnverifiedLookupsIsBenchedAndDropsOut() throws {
        let learning = try tempLearning()
        for _ in 0..<3 {
            ReadRouting.recordQuery(app: "notes", arm: "full_tree_read", matches: 0, latencyMs: 9, learning: learning)
        }
        XCTAssertTrue(learning.routes.isBenched(app: "notes", action: "query", arm: "full_tree_read"))
        for _ in 0..<100 {
            XCTAssertEqual(ReadRouting.queryArm(app: "notes", risky: false, learning: learning), "targeted_query")
        }
    }

    func testVerifiedLookupsAreRewardedAndUnverifiedOnesAreNot() throws {
        let learning = try tempLearning()
        for _ in 0..<5 {
            ReadRouting.recordQuery(app: "notes", arm: "targeted_query", matches: 2, latencyMs: 3, learning: learning)
        }
        // An unverified (empty) lookup is a failure, so the streak of three benches the arm, while the verified ones stay.
        for _ in 0..<3 {
            ReadRouting.recordQuery(app: "notes", arm: "targeted_query", matches: 0, latencyMs: 3, learning: learning)
        }
        XCTAssertTrue(learning.routes.isBenched(app: "notes", action: "query", arm: "targeted_query"))
        XCTAssertFalse(learning.routes.isBenched(app: "notes", action: "query", arm: "full_tree_read"))
    }

    func testSettlePlanNeverWaitsLongerThanAskedAndLearnsOnlyFromItsOwnWait() throws {
        let learning = try tempLearning()
        XCTAssertNil(ReadRouting.settlePlan(requested: nil, app: "a", windowID: nil, learning: learning).wait)
        XCTAssertNil(ReadRouting.settlePlan(requested: 3000, app: "a", windowID: 7, learning: learning).wait)

        let short = ReadRouting.settlePlan(requested: 100, app: "a", windowID: nil, learning: learning)
        XCTAssertEqual(short.wait, 100)
        XCTAssertNil(short.tuned, "a wait shorter than any candidate is the caller's, not the tuner's")

        let long = ReadRouting.settlePlan(requested: 5000, app: "a", windowID: nil, learning: learning)
        let tuned = try XCTUnwrap(long.tuned)
        XCTAssertEqual(long.wait, tuned)
        XCTAssertTrue((AdaptiveLearning.settleBounds.min...AdaptiveLearning.settleBounds.max).contains(tuned))
    }

    func testSettleOutcomeReadsTheSettleNote() {
        XCTAssertEqual(ReadRouting.settleVerified(.text("Settled: the window stayed free of busy signs (waited 300 ms).")), true)
        XCTAssertEqual(ReadRouting.settleVerified(.text("Not settled: no quiet period confirmed after 1750 ms.")), false)
        XCTAssertNil(ReadRouting.settleVerified(.text("ok")))
    }

    func testLearnedStateSurvivesARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let first = AdaptiveLearning(directory: dir)
        ReadRouting.recordQuery(app: "notes", arm: "full_tree_read", matches: 1, latencyMs: 5, learning: first)
        first.routes.record(app: "notes", action: "query", arm: "targeted_query", verified: false, latencyMs: 1)
        first.saveRoutes()
        let tuned = try XCTUnwrap(ReadRouting.settlePlan(requested: 5000, app: "notes", windowID: nil, learning: first).tuned)
        ReadRouting.recordSettle(tuned, result: .text("Settled: quiet."), startedAt: Date(), app: "notes", learning: first)

        let second = AdaptiveLearning(directory: dir)
        XCTAssertEqual(try second.routes.jsonData(), try first.routes.jsonData())
        XCTAssertEqual(try second.settle.jsonData(), try first.settle.jsonData())
    }
}
