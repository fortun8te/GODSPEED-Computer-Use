import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

final class ModelHelperPolicyTests: XCTestCase {
    private let helper = URL(string: "http://127.0.0.1:8765")!
    private let scorer = URL(string: "http://127.0.0.1:18765")!

    private func environment(_ setting: String) -> [String: String] {
        [ModelHelperPolicy.environmentKey: setting,
         "OPEN_COMPUTER_USE_REFEREE_URL": helper.absoluteString,
         "OPEN_COMPUTER_USE_VISION_URL": helper.absoluteString,
         "OPEN_COMPUTER_USE_GSD1_URL": scorer.absoluteString,
         "OPEN_COMPUTER_USE_HANDOFF_HELPER": "1"]
    }

    func testDefaultAndExplicitFlags() {
        XCTAssertTrue(ModelHelperPolicy.isEnabled(environment: [:]))
        for value in ["0", "false", "OFF", "No", " \n off \t"] {
            XCTAssertFalse(ModelHelperPolicy.isEnabled(environment: [ModelHelperPolicy.environmentKey: value]), value)
        }
        for value in ["1", "true", "on", "yes", "", "unknown"] {
            XCTAssertTrue(ModelHelperPolicy.isEnabled(environment: [ModelHelperPolicy.environmentKey: value]), value)
        }
    }

    func testPerClientOverridesCoverEveryHelperAndRestoreAfterNestedRequest() {
        RequestConfiguration.withEnvironment(environment("off")) {
            XCTAssertFalse(ModelHelperPolicy.isEnabled)
            XCTAssertNil(Referee.baseURL)
            XCTAssertNil(Referee.handoffURL)
            XCTAssertNil(VisionFallback.baseURL)
            XCTAssertNil(LocalDecisionTool.baseURL())
            RequestConfiguration.withEnvironment(environment("on")) {
                XCTAssertTrue(ModelHelperPolicy.isEnabled)
                XCTAssertEqual(Referee.baseURL, helper)
                XCTAssertEqual(Referee.handoffURL, helper)
                XCTAssertEqual(VisionFallback.baseURL, helper)
                XCTAssertEqual(LocalDecisionTool.baseURL(), scorer)
            }
            XCTAssertFalse(ModelHelperPolicy.isEnabled)
            XCTAssertNil(Referee.handoffURL)
            XCTAssertNil(LocalDecisionTool.baseURL())
        }
    }

    func testDefaultLocalHandoffCannotBypassModelFreeSetting() {
        RequestConfiguration.withEnvironment([ModelHelperPolicy.environmentKey: "0"]) {
            XCTAssertNil(Referee.handoffURL)
        }
        XCTAssertNil(LocalDecisionTool.baseURL(environment: environment("0")))
        XCTAssertEqual(LocalDecisionTool.baseURL(environment: environment("1")), scorer)
    }

    func testDedicatedHandoffURLWinsWithoutEnablingHintsOrWarmup() {
        let custom = "http://127.0.0.1:9876/helper"
        var values = environment("on")
        values["OPEN_COMPUTER_USE_HANDOFF_URL"] = custom
        RequestConfiguration.withEnvironment(values) {
            XCTAssertEqual(Referee.handoffURL?.absoluteString, custom)
            XCTAssertEqual(Referee.baseURL, helper, "Handoff must not replace the separately configured hint endpoint")
        }
        values["OPEN_COMPUTER_USE_REFEREE_URL"] = ""
        values["OPEN_COMPUTER_USE_VISION_URL"] = ""
        RequestConfiguration.withEnvironment(values) {
            XCTAssertEqual(Referee.handoffURL?.absoluteString, custom)
            XCTAssertFalse(Referee.isEnabled)
            XCTAssertFalse(VisionFallback.isEnabled)
            Referee.warmInBackground(send: { _, _ in XCTFail("A handoff URL must not enable hint warmup") })
        }
    }

    func testInvalidExplicitHandoffURLNeverFallsBackToRefereeOrDefault() {
        for value in ["", "not a URL", "https://example.com/helper", "http://user:secret@localhost:9876",
                      "http://localhost:9876?key=secret", "http://localhost:9876#fragment", "http://localhost:65536"] {
            var values = environment("on")
            values["OPEN_COMPUTER_USE_HANDOFF_URL"] = value
            RequestConfiguration.withEnvironment(values) {
                XCTAssertNil(Referee.handoffURL, value)
            }
        }
    }

    func testDedicatedHandoffURLStillRespectsBothDisableSwitches() {
        var values = environment("off")
        values["OPEN_COMPUTER_USE_HANDOFF_URL"] = "http://localhost:9876"
        RequestConfiguration.withEnvironment(values) { XCTAssertNil(Referee.handoffURL) }
        values[ModelHelperPolicy.environmentKey] = "on"
        for setting in ["0", "false", "OFF", " no "] {
            values["OPEN_COMPUTER_USE_HANDOFF_HELPER"] = setting
            RequestConfiguration.withEnvironment(values) { XCTAssertNil(Referee.handoffURL) }
        }
    }

    func testAbsentDedicatedHandoffURLPreservesExistingFallbacks() {
        XCTAssertEqual(Referee.localChooseURL(refereeURL: helper, setting: nil), helper)
        XCTAssertEqual(Referee.localChooseURL(refereeURL: nil, setting: nil), helper)
        XCTAssertNil(Referee.localChooseURL(refereeURL: URL(string: "https://example.com"), setting: nil))
    }

    func testDisabledEntryPointsDoNotCapturePicturesOrReleaseDesktopAdmission() {
        RequestConfiguration.withEnvironment(environment("off")) {
            RequestInferenceAdmission.$withoutExclusive.withValue({ _ in
                XCTFail("A model-free request must not release admission for helper HTTP")
                return nil
            }) {
                XCTAssertNil(Referee.decide(goal: "Inspect", lastStep: "Read", result: "OK", summary: "Fixture"))
                XCTAssertNil(Referee.choose(goal: "Inspect", doneWhen: "Read", history: "", screen: "Fixture",
                                           options: [(id: "a", text: "Inspect")]))
                XCTAssertNil(VisionFallback.locate(imageBase64: "AQID", query: "Save"))
                XCTAssertNil(HelperHTTP.postJSON(helper, body: ["goal": "Fixture"], timeout: 0.01))
                XCTAssertNil(HelperHTTP.getJSON(helper, timeout: 0.01))
                XCTAssertFalse(HelperHTTP.isHealthy(helper, timeout: 0.01))
                XCTAssertNil(Referee.picture(url: helper, state: "Window ID: 7\n0 canvas", remaining: 3, thin: true) {
                    XCTFail("A model-free request must not capture a model picture")
                    return Data([1, 2, 3])
                })
            }
        }
    }

    func testDisabledGSD1DoesNotScoreOrRecoverEvenWithAnExplicitURL() throws {
        let arguments: [String: Any] = [
            "role": "recover", "state": "Fixture", "question": [
                "type": "choice", "instructions": "Choose evidence to inspect",
                "criteria": ["read": "Read", "wait": "Wait"],
            ],
        ]
        try RequestConfiguration.withEnvironment(environment("off")) {
            for url in [scorer, nil] {
                let result = try LocalDecisionTool.run(arguments: arguments, baseURL: url, now: { 0 },
                    recoverHelper: { _ in XCTFail("Disabled helpers must not recover") },
                    score: { _, _, _ in XCTFail("Disabled helpers must not score"); return nil })
                XCTAssertEqual(result.deliveryState, .notSent)
                XCTAssertTrue(result.primaryText?.contains("helpers are disabled") == true)
            }
        }
    }

    func testModelFreeStillUsesBothLocalOCRPasses() {
        RequestConfiguration.withEnvironment(environment("off")) {
            var passes: [Bool] = []
            let expected = CGPoint(x: 0.4, y: 0.3)
            let result = VisionFallback.candidate(scan: { accurate in
                passes.append(accurate)
                return accurate ? .point(expected) : .missing
            }, locate: {
                XCTFail("OCR does not need a model")
                return nil
            })
            XCTAssertEqual(passes, [false, true])
            XCTAssertEqual(result?.fraction, expected)
            XCTAssertEqual(result?.evidence, .ocr)
            XCTAssertNil(VisionFallback.candidate(scan: { _ in .missing }, locate: {
                XCTFail("An OCR miss must not invoke a disabled model")
                return expected
            }))
        }
    }

    func testDisabledWarmupDoesNotSubmitOrConsumeCooldown() {
        let now = ProcessInfo.processInfo.systemUptime + 120
        RequestConfiguration.withEnvironment(environment("off")) {
            Referee.warmInBackground(now: now, send: { _, _ in XCTFail("Disabled warmup submitted HTTP") })
        }
        var submissions = 0
        RequestConfiguration.withEnvironment(environment("on")) {
            Referee.warmInBackground(now: now, send: { request, completion in
                submissions += 1
                XCTAssertEqual(request.url?.path, "/warm")
                XCTAssertEqual(request.url?.query, "models=d1")
                completion(true)
            })
        }
        XCTAssertEqual(submissions, 1)
    }

    func testDisabledAutostartDoesNotQueueHealthOrConsumeCooldown() {
        for restart in [false, true] {
            let starter = HelperAutoStarter(launcher: URL(fileURLWithPath: "/nonexistent/godspeed-test-helper"),
                                           log: URL(fileURLWithPath: "/nonexistent/godspeed-test-log"),
                                           restartLocalScorer: restart)
            RequestConfiguration.withEnvironment(environment("off")) {
                starter.helperUnreachable(helper, now: 10, schedule: { _ in
                    XCTFail("Disabled helpers must not queue health probes")
                })
            }
            var queued = 0
            RequestConfiguration.withEnvironment(environment("on")) {
                starter.helperUnreachable(helper, now: 10, schedule: { _ in queued += 1 })
            }
            XCTAssertEqual(queued, 1)
        }
    }

    func testManagedLaunchersDoNotStartForCustomEndpoints() {
        for port in [8765, 18765] {
            let starter = HelperAutoStarter(launcher: URL(fileURLWithPath: "/nonexistent/godspeed-test-helper"),
                                           log: URL(fileURLWithPath: "/nonexistent/godspeed-test-log"),
                                           managedPort: port)
            RequestConfiguration.withEnvironment(environment("on")) {
                for raw in ["http://localhost:9000", "https://localhost:\(port)", "http://localhost:\(port)/proxy",
                            "http://user:secret@localhost:\(port)", "http://localhost:\(port)?key=value",
                            "http://[::1]:\(port)"] {
                    let url = URL(string: raw)!
                    XCTAssertFalse(starter.manages(url), raw)
                    starter.helperUnreachable(url, now: 10, schedule: { _ in
                        XCTFail("The fixed-port launcher does not manage \(raw)")
                    })
                }
                var queued = 0
                let ownURL = URL(string: "http://127.0.0.1:\(port)")!
                XCTAssertTrue(starter.manages(ownURL))
                XCTAssertTrue(starter.manages(URL(string: "http://localhost:\(port)/")!))
                starter.helperUnreachable(ownURL, now: 10, schedule: { _ in queued += 1 })
                XCTAssertEqual(queued, 1, "Unsupported endpoints must not consume the managed endpoint's cooldown")
            }
        }
        XCTAssertFalse(HelperAutoStarter.shared.manages(scorer))
        XCTAssertTrue(HelperAutoStarter.shared.manages(helper))
    }

    func testRecoveryWorkerRestoresOriginalClientAndCancellation() {
        let starter = HelperAutoStarter(launcher: URL(fileURLWithPath: "/nonexistent/godspeed-test-helper"),
                                       log: URL(fileURLWithPath: "/nonexistent/godspeed-test-log"))
        let token = RequestCancellation()
        let checked = expectation(description: "Read the initiating client's configuration")
        var work: (@Sendable () -> Void)?
        RequestConfiguration.withEnvironment(environment("on")) {
            RequestCancellation.$current.withValue(token) {
                starter.helperUnreachable(helper, now: 10, schedule: { work = $0 }, healthCheck: { url in
                    XCTAssertTrue(ModelHelperPolicy.isEnabled)
                    XCTAssertTrue(RequestCancellation.current === token)
                    XCTAssertEqual(url.path, "/health")
                    checked.fulfill()
                    return true
                })
            }
        }
        // The initiating request has returned; a different client now owns this thread.
        RequestConfiguration.withEnvironment(environment("off")) {
            work?()
            XCTAssertFalse(ModelHelperPolicy.isEnabled)
            XCTAssertNil(RequestCancellation.current)
        }
        wait(for: [checked], timeout: 1)
    }

    func testCancellationAfterSchedulingSuppressesRecoveryProbe() {
        let starter = HelperAutoStarter(launcher: URL(fileURLWithPath: "/nonexistent/godspeed-test-helper"),
                                       log: URL(fileURLWithPath: "/nonexistent/godspeed-test-log"))
        let token = RequestCancellation()
        var work: (@Sendable () -> Void)?
        RequestConfiguration.withEnvironment(environment("on")) {
            RequestCancellation.$current.withValue(token) {
                starter.helperUnreachable(helper, now: 10, schedule: { work = $0 }, healthCheck: { _ in
                    XCTFail("A cancelled request must not probe or restart its helper")
                    return false
                })
            }
        }
        XCTAssertNotNil(work)
        token.cancel()
        work?()
    }
}
