import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Seeded RNG so every run is repeatable.
struct RouteTestRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Fake clock that tests move forward by hand.
final class RouteTestClock: @unchecked Sendable {
    var seconds = 1_000_000.0
}

final class RouteBanditTests: XCTestCase {
    private let arms = ["background_pointer", "ax_press"]

    func testConvergesToBetterArmOnSimulatedRates() {
        // One simulated second per step, so benched arms can come back.
        let clock = RouteTestClock()
        let bandit = RouteBandit(clock: { clock.seconds })
        var rng = RouteTestRNG(seed: 42)
        var goodPicks = 0
        for step in 0..<1000 {
            clock.seconds += 1
            let arm = bandit.choose(app: "app", action: "press", arms: arms, rng: &rng)
            let successRate = arm == "ax_press" ? 0.8 : 0.4
            let verified = Double.random(in: 0..<1, using: &rng) < successRate
            bandit.record(app: "app", action: "press", arm: arm, verified: verified, latencyMs: 10)
            if step >= 800, arm == "ax_press" { goodPicks += 1 }
        }
        // The last 200 choices should mostly pick the 80% arm.
        XCTAssertGreaterThan(goodPicks, 160)
    }

    func testRiskyActionsNeverExplore() {
        let bandit = RouteBandit(clock: { 0 })
        for _ in 0..<50 {
            bandit.record(app: "mail", action: "press", arm: "ax_press", verified: true, latencyMs: 5)
        }
        var rng = RouteTestRNG(seed: 5)
        for _ in 0..<500 {
            let flagged = bandit.choose(app: "mail", action: "press", arms: arms, riskyAction: true, rng: &rng)
            XCTAssertEqual(flagged, "background_pointer")
            // Action names with a risky word are treated the same way.
            let named = bandit.choose(app: "mail", action: "send_message", arms: arms, rng: &rng)
            XCTAssertEqual(named, "background_pointer")
        }
        let stats = bandit.explorationStats(app: "mail", action: "send_message")
        XCTAssertEqual(stats.choices, 0)
        XCTAssertEqual(stats.explorations, 0)
    }

    func testArmIsBenchedAfterThreeFailuresAndRecovers() {
        let clock = RouteTestClock()
        let bandit = RouteBandit(clock: { clock.seconds })
        var rng = RouteTestRNG(seed: 1)
        for _ in 0..<3 {
            bandit.record(app: "app", action: "press", arm: "ax_press", verified: false, latencyMs: 5)
        }
        XCTAssertTrue(bandit.isBenched(app: "app", action: "press", arm: "ax_press"))
        for _ in 0..<100 {
            XCTAssertEqual(bandit.choose(app: "app", action: "press", arms: arms, rng: &rng), "background_pointer")
        }

        clock.seconds += RouteBandit.benchSeconds + 1
        XCTAssertFalse(bandit.isBenched(app: "app", action: "press", arm: "ax_press"))
        var sawRecovered = false
        for _ in 0..<200 where bandit.choose(app: "app", action: "press", arms: arms, rng: &rng) == "ax_press" {
            sawRecovered = true
        }
        XCTAssertTrue(sawRecovered)

        // A success breaks the streak, so two more failures do not bench it.
        bandit.record(app: "app", action: "press", arm: "ax_press", verified: false, latencyMs: 5)
        bandit.record(app: "app", action: "press", arm: "ax_press", verified: false, latencyMs: 5)
        bandit.record(app: "app", action: "press", arm: "ax_press", verified: true, latencyMs: 5)
        bandit.record(app: "app", action: "press", arm: "ax_press", verified: false, latencyMs: 5)
        bandit.record(app: "app", action: "press", arm: "ax_press", verified: false, latencyMs: 5)
        XCTAssertFalse(bandit.isBenched(app: "app", action: "press", arm: "ax_press"))
    }

    func testAllBenchedFallsBackToDefault() {
        let bandit = RouteBandit(clock: { 0 })
        for arm in arms {
            for _ in 0..<3 {
                bandit.record(app: "app", action: "click", arm: arm, verified: false, latencyMs: 1)
            }
        }
        var rng = RouteTestRNG(seed: 2)
        XCTAssertEqual(bandit.choose(app: "app", action: "click", arms: arms, rng: &rng), "background_pointer")
    }

    func testExplorationStaysUnderCapOnceMature() {
        let bandit = RouteBandit(clock: { 0 })
        // Both arms have the same mixed record, so Thompson sampling wants to explore often.
        for arm in arms {
            for i in 0..<20 {
                bandit.record(app: "app", action: "press", arm: arm, verified: i % 2 == 0, latencyMs: 5)
            }
        }
        var rng = RouteTestRNG(seed: 11)
        let before = bandit.explorationStats(app: "app", action: "press").explorations
        for _ in 0..<1000 {
            _ = bandit.choose(app: "app", action: "press", arms: arms, rng: &rng)
        }
        let stats = bandit.explorationStats(app: "app", action: "press")
        let explored = stats.explorations - before
        XCTAssertEqual(stats.choices, 1000)
        XCTAssertLessThanOrEqual(explored, Int(RouteBandit.exploreCap * 1000))
        XCTAssertGreaterThan(explored, 80, "the cap should bind here, not the sampler")
    }

    func testTunerStaysInBoundsAndFindsBestOnCurve() {
        let tuner = ParameterTuner(bounds: ParameterBounds(min: 0, max: 1000, defaultValue: 500), trialsPerRound: 40)
        var rng = RouteTestRNG(seed: 3)
        for _ in 0..<600 {
            let value = tuner.value(app: "mail")
            XCTAssertTrue((0...1000).contains(value))
            // Simulated success curve that peaks at 250.
            let successRate = max(0.05, 0.9 - 0.8 * abs(Double(value) - 250) / 1000)
            let verified = Double.random(in: 0..<1, using: &rng) < successRate
            tuner.record(app: "mail", value: value, verified: verified, latencyMs: Double(value))
        }
        XCTAssertEqual(tuner.winner(app: "mail"), 250)
    }

    func testTunerClampsDefaultAndNeverLeavesBounds() {
        let bounds = ParameterBounds(min: 5, max: 7, defaultValue: 99)
        XCTAssertEqual(bounds.defaultValue, 7)
        let tuner = ParameterTuner(bounds: bounds)
        var rng = RouteTestRNG(seed: 8)
        for _ in 0..<100 {
            let value = tuner.value(app: "app")
            XCTAssertTrue((5...7).contains(value))
            tuner.record(app: "app", value: value, verified: Bool.random(using: &rng), latencyMs: 3)
        }
    }

    func testPersistenceRoundTrip() throws {
        let bandit = RouteBandit(clock: { 0 })
        var rng = RouteTestRNG(seed: 21)
        for _ in 0..<60 {
            let arm = bandit.choose(app: "app", action: "press", arms: arms, rng: &rng)
            bandit.record(app: "app", action: "press", arm: arm, verified: arm == "ax_press", latencyMs: 12)
        }
        let data = try bandit.jsonData()

        let restored = RouteBandit(clock: { 0 })
        try restored.restore(data)
        XCTAssertEqual(try restored.jsonData(), data)

        // The restored bandit makes the same choices with the same RNG.
        var rngA = RouteTestRNG(seed: 4)
        var rngB = RouteTestRNG(seed: 4)
        for _ in 0..<50 {
            XCTAssertEqual(
                bandit.choose(app: "app", action: "press", arms: arms, rng: &rngA),
                restored.choose(app: "app", action: "press", arms: arms, rng: &rngB)
            )
        }

        // Round trip through a file in a temp directory.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-bandit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routes.json")
        try data.write(to: file)
        let fromDisk = RouteBandit(clock: { 0 })
        try fromDisk.restore(Data(contentsOf: file))
        XCTAssertEqual(try fromDisk.jsonData(), data)

        let tuner = ParameterTuner(bounds: ParameterBounds(min: 0, max: 100, defaultValue: 50))
        tuner.record(app: "app", value: tuner.value(app: "app"), verified: true, latencyMs: 4)
        let tunerData = try tuner.jsonData()
        let tunerRestored = ParameterTuner(bounds: ParameterBounds(min: 0, max: 100, defaultValue: 50))
        try tunerRestored.restore(tunerData)
        XCTAssertEqual(try tunerRestored.jsonData(), tunerData)
    }

    func testRestoreRejectsInvalidRouteCountsAndInconsistentTunerArrays() throws {
        let bandit = RouteBandit()
        let invalidRoute = Data(#"{"version":1,"apps":{"app":{"query":{"choices":0,"explorations":0,"arms":{"ax":{"successes":-2,"failures":0,"streak":0,"latencySum":0,"latencyCount":0,"benchedUntil":0}}}}}}"#.utf8)
        XCTAssertThrowsError(try bandit.restore(invalidRoute)) { error in
            XCTAssertEqual(error as? RouteBanditError, .invalidSnapshot)
        }
        let tuner = ParameterTuner(bounds: .init(min: 0, max: 4, defaultValue: 0))
        let invalidTuner = Data(#"{"version":1,"apps":{"app":{"candidates":[0,1,2,3,4],"defaultIndex":0,"alive":[true],"trials":[],"successes":[],"latencySum":[],"round":0}}}"#.utf8)
        XCTAssertThrowsError(try tuner.restore(invalidTuner)) { error in
            XCTAssertEqual(error as? RouteBanditError, .invalidSnapshot)
        }
        XCTAssertEqual(tuner.value(app: "app"), 0)
    }

    func testRestoreRejectsUnknownVersion() {
        let bandit = RouteBandit(clock: { 0 })
        let data = Data(#"{"version":9,"apps":{}}"#.utf8)
        XCTAssertThrowsError(try bandit.restore(data)) { error in
            XCTAssertEqual(error as? RouteBanditError, .unsupportedVersion(9))
        }
    }
}
