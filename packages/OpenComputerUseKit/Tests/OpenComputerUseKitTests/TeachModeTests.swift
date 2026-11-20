import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Teach mode session: start, stop, status. Inputs come from a fake source; recipes go to a temp file.
final class TeachModeTests: XCTestCase {
    private final class FakeSource: TeachInputSource {
        var refuse = false
        var deliver: ((TeachInput) -> Void)?
        var startedPID: pid_t?
        var stopped = false

        func start(pid: pid_t, deliver: @escaping (TeachInput) -> Void) -> Bool {
            if refuse { return false }
            startedPID = pid
            self.deliver = deliver
            return true
        }

        func stop() {
            stopped = true
            deliver = nil
        }

        func send(_ input: TeachInput) { deliver?(input) }
    }

    private let mailPID: pid_t = 4242
    private let otherPID: pid_t = 9999
    private let to = TeachTarget(role: "text field", label: "To")
    private let send = TeachTarget(role: "button", label: "Send")
    private let password = TeachTarget(role: "secure text field", label: "Password", secure: true)

    private var folder: URL!
    private var store: BatchRecipes!
    private var source: FakeSource!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var mode: TeachMode!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("teach-\(UUID().uuidString)")
        store = BatchRecipes(fileURL: folder.appendingPathComponent("recipes.json"))
        source = FakeSource()
        clock = Date(timeIntervalSince1970: 1_000_000)
        mode = makeMode()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func makeMode() -> TeachMode {
        TeachMode(
            store: store,
            makeSource: { [unowned self] in self.source },
            resolveApp: { name in
                name.caseInsensitiveCompare("Mail") == .orderedSame ? TeachMode.AppTarget(pid: self.mailPID, name: "Mail") : nil
            },
            readWindow: { _ in nil },
            now: { [unowned self] in self.clock },
            scheduleTimer: false
        )
    }

    private func recipesFileText() -> String {
        (try? String(contentsOf: folder.appendingPathComponent("recipes.json"), encoding: .utf8)) ?? ""
    }

    func testStopSavesAnUnverifiedRecipeThatCannotReplay() throws {
        let started = try mode.start(app: "Mail", goal: "Email Sam the report")
        XCTAssertTrue(started.contains("Recording is on"))
        XCTAssertEqual(source.startedPID, mailPID)

        source.send(TeachInput(pid: mailPID, event: .focus(to)))
        source.send(TeachInput(pid: mailPID, event: .typed("sam@x.com")))
        source.send(TeachInput(pid: mailPID, event: .press(send)))
        let reply = mode.stop()

        XCTAssertTrue(source.stopped)
        XCTAssertTrue(reply.contains("Saved an unverified recipe"), reply)
        XCTAssertTrue(reply.contains("Click \"Send\""), reply)
        XCTAssertTrue(reply.contains("{{to}}"), reply)
        XCTAssertFalse(mode.status().contains("Recording is on"))

        guard case .blocked(let why) = store.lookup(app: "Mail", goal: "Email Sam the report", values: ["to": "sam@x.com"], state: nil) else {
            return XCTFail("an unverified recipe must not replay")
        }
        XCTAssertTrue(why.contains("unverified"), why)
        XCTAssertTrue(recipesFileText().contains("\"verified\" : false"))
    }

    func testSecureFieldTextIsNeverWrittenAndTheRecipeAsksForTheValue() throws {
        _ = try mode.start(app: "Mail", goal: "Sign in to the portal")
        source.send(TeachInput(pid: mailPID, event: .focus(password)))
        source.send(TeachInput(pid: mailPID, event: .typed("hunter2")))
        source.send(TeachInput(pid: mailPID, event: .press(send)))
        let reply = mode.stop()

        XCTAssertFalse(recipesFileText().contains("hunter2"))
        XCTAssertFalse(reply.contains("hunter2"))
        XCTAssertTrue(reply.contains("needs the value"), reply)
        XCTAssertTrue(reply.contains("Password"), reply)
    }

    func testOtherAppInputDoesNotReachTheRecipe() throws {
        _ = try mode.start(app: "Mail", goal: "Email Sam the report")
        source.send(TeachInput(pid: otherPID, event: .focus(to)))
        source.send(TeachInput(pid: otherPID, event: .typed("private")))
        source.send(TeachInput(pid: otherPID, event: .press(send)))
        let reply = mode.stop()

        XCTAssertTrue(reply.contains("Nothing was recorded"), reply)
        XCTAssertFalse(recipesFileText().contains("private"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recipes.json").path))
    }

    func testSecondStartIsRefusedWhileRecording() throws {
        _ = try mode.start(app: "Mail", goal: "Email Sam the report")
        XCTAssertThrowsError(try mode.start(app: "Mail", goal: "Another"))
        XCTAssertTrue(mode.status().contains("Recording is on"))
    }

    func testRecordingStopsAndSavesAfterTenMinutes() throws {
        _ = try mode.start(app: "Mail", goal: "Email Sam the report")
        source.send(TeachInput(pid: mailPID, event: .focus(to)))
        source.send(TeachInput(pid: mailPID, event: .typed("ok")))
        clock.addTimeInterval(TeachRecorder.timeLimit + 1)
        mode.tick()

        XCTAssertTrue(source.stopped)
        XCTAssertFalse(mode.status().contains("Recording is on"))
        XCTAssertTrue(mode.status().contains("10-minute limit"), mode.status())
        XCTAssertTrue(recipesFileText().contains("Email Sam the report"))
    }

    func testTargetAppQuitStopsAndSaves() throws {
        _ = try mode.start(app: "Mail", goal: "Email Sam the report")
        source.send(TeachInput(pid: mailPID, event: .focus(to)))
        source.send(TeachInput(pid: mailPID, event: .typed("draft")))
        source.send(TeachInput(pid: mailPID, event: .appQuit))

        XCTAssertTrue(source.stopped)
        XCTAssertTrue(mode.status().contains("app quit"), mode.status())
        XCTAssertTrue(recipesFileText().contains("Email Sam the report"))
    }

    func testRefusedSourceReportsAFailureAndRecordsNothing() {
        source.refuse = true
        XCTAssertThrowsError(try mode.start(app: "Mail", goal: "Email Sam the report"))
        XCTAssertFalse(mode.status().contains("Recording is on"))
    }

    func testUnknownAppIsRefused() {
        XCTAssertThrowsError(try mode.start(app: "Nowhere", goal: "Anything"))
        XCTAssertNil(source.startedPID)
    }
}
