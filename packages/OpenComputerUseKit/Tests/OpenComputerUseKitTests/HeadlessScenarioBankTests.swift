import AppKit
import Foundation
import XCTest
@testable import OpenComputerUseKit

final class HeadlessScenarioBankTests: XCTestCase {
    private struct Receipt: Encodable {
        let schemaVersion = 1
        let source = "synthetic_headless"
        let use = "regression_only"
        let id: String
        let family: String
        let seed: Int
        let fixture: [String: String]
        let expected: String
        let observed: String
        let durationNs: UInt64
    }

    private func run(
        _ family: String,
        cases: (Int) throws -> ([String: String], String, String)
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var receipts = Data()
        var failures: [String] = []
        let count = ProcessInfo.processInfo.environment["GODSPEED_SCENARIO_COUNT"].flatMap(Int.init) ?? 1_000
        for seed in 0..<count {
            let id = "\(family)/\(seed)"
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome: ([String: String], String, String)
            do {
                outcome = try cases(seed)
            } catch {
                outcome = ([:], "no error", String(describing: error))
            }
            let (fixture, expected, observed) = outcome
            let duration = DispatchTime.now().uptimeNanoseconds - started
            if expected != observed { failures.append(id) }
            receipts.append(try encoder.encode(Receipt(
                id: id, family: family, seed: seed, fixture: fixture,
                expected: expected, observed: observed, durationNs: duration
            )))
            receipts.append(0x0a)
        }
        if let directory = ProcessInfo.processInfo.environment["GODSPEED_SCENARIO_OUTPUT"] {
            try receipts.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("\(family).jsonl"),
                options: .atomic
            )
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(10))")
    }

    func testCalculatorVerification() throws {
        try run("calculator") { seed in
            let rhs = 2 + seed % 37
            let expected = seed * rhs
            let correct = seed % 3 != 0
            let actual = expected + (correct ? 0 : 1)
            let verified = DoneCheck.fieldEquals("1 text field Result = \(actual)", label: "Result", value: String(expected))
            return (["expression": "\(seed)*\(rhs)", "result": String(actual)], String(correct), String(verified))
        }
    }

    func testPinnedFirstClickKeepsObservedRoot() throws {
        // AXFocusedWindow supplied the observation. AXWindows can expose a different
        // accessibility object for the same native ID, ahead of that very same root.
        try run("pinned_first_click") { seed in
            struct Root {
                let windowID: UInt32
                let object: Int
            }
            let observed = Root(windowID: 18855 + UInt32(seed), object: 1)
            let otherObject = Root(windowID: observed.windowID, object: 2)
            let otherWindow = Root(windowID: observed.windowID + 1, object: 1)
            let matchingRootIsLive = seed.isMultiple(of: 2)
            let live = SnapshotBuilder.selectNativeWindow(
                listed: [otherWindow, otherObject], focused: { matchingRootIsLive ? observed : nil },
                matchesID: { $0.windowID == observed.windowID },
                matchesObservedRoot: { $0.object == observed.object }
            )
            return (
                ["window_id": String(observed.windowID), "original_root_present": String(matchingRootIsLive)],
                matchingRootIsLive ? "1" : "refused",
                live.map { String($0.object) } ?? "refused"
            )
        }
    }

    func testUnknownNativeRefReturnsTypedFailure() {
        let dispatcher = ComputerUseToolDispatcher()
        let args = ["app": "NoSuchNativeRefTestApp", "ref": UUID().uuidString]
        let result = dispatcher.callToolAsResult(name: "click", arguments: args)
        XCTAssertTrue(result.isError)
        XCTAssertEqual((result.asDictionary["_meta"] as? [String: Any])?["godspeed/error_code"] as? String, "STALE_REF")
        XCTAssertTrue(result.textContent.contains("get_app_state"))

        let batch = dispatcher.callToolAsResult(name: "batch", arguments: [
            "app": args["app"]!, "steps": [["tool": "click", "ref": args["ref"]!], ["tool": "list_apps"]],
        ])
        XCTAssertTrue(batch.isError)
        let step = batch.batchReceipt?.steps.first
        XCTAssertEqual(step?.failureCode?.rawValue, "STALE_REF")
        XCTAssertEqual(step?.observation, .notSent)
        XCTAssertEqual(batch.batchReceipt?.steps.count, 1)
    }

    func testNativeRefExpiresAcrossReadsAndClients() throws {
        let app = RunningAppDescriptor(name: "NativeRefFixture", bundleIdentifier: "test.native-ref",
                                       pid: 312, runningApplication: .current)
        let service = ComputerUseService()

        func snapshot(windowID: UInt32, identifier: String) -> AppSnapshot {
            let frame = FixtureRect(rect: CGRect(x: 0, y: 0, width: 20, height: 20))
            let state = FixtureAppState(windowTitle: "Same title", windowBounds: frame, focusedIdentifier: nil,
                                        elements: [.init(identifier: identifier, index: 3, role: "button",
                                                         title: "Send", value: nil, actions: [], frame: frame)])
            var snapshot = SnapshotBuilder.buildFixtureSnapshot(app: app, state: state, observation: .defaults)
            snapshot.nativeWindow = NativeWindowObservation(
                id: windowID,
                app: TargetedAppIdentity(pid: app.pid, bundleIdentifier: app.bundleIdentifier,
                                         launchedAt: Date(timeIntervalSince1970: 42))
            )
            snapshot.elementRefs = NativeSnapshotRefs(elementIndexes: [3])
            return snapshot
        }

        try ClientScope.with("native-ref-owner") {
            let first = snapshot(windowID: 17, identifier: "send-original")
            let old = try XCTUnwrap(first.elementRefs?.text.split(separator: " ").last.map(String.init))
            service.rememberSnapshot(first, for: "legacy-alias")
            XCTAssertEqual(try service.resolveElementRef(old, app: app.name).index, 3)
            XCTAssertThrowsError(try ClientScope.with("native-ref-other") {
                try service.resolveElementRef(old, app: app.name)
            }) { XCTAssertEqual(($0 as? ComputerUseError)?.errorDescription, ComputerUseError.staleRef.errorDescription) }

            let second = snapshot(windowID: 18, identifier: "send-replacement")
            let fresh = try XCTUnwrap(second.elementRefs?.text.split(separator: " ").last.map(String.init))
            service.rememberSnapshot(second, for: app.name)
            XCTAssertNotEqual(fresh, old)
            XCTAssertThrowsError(try service.resolveElementRef(old, app: app.name))
            XCTAssertThrowsError(try service.resolveElementRef(old, app: "legacy-alias"))
            XCTAssertEqual(try service.resolveElementRef(fresh, app: app.name).windowID, 18)

            let dispatcher = ComputerUseToolDispatcher(service: service)
            let wrongWindow = dispatcher.callToolAsResult(name: "click", arguments: [
                "app": app.name, "ref": fresh, "window_id": 17,
            ])
            XCTAssertTrue(wrongWindow.isError)
            XCTAssertEqual(wrongWindow.failureCode, .windowChanged)
            XCTAssertTrue(wrongWindow.textContent.contains("Nothing was sent"))
            let conflicting = dispatcher.callToolAsResult(name: "select_text", arguments: [
                "app": app.name, "ref": fresh, "label": "Send", "text": "Example",
            ])
            XCTAssertTrue(conflicting.isError)
            XCTAssertEqual(conflicting.failureCode, .invalidArguments)

            service.clearSnapshotRefs()
            XCTAssertThrowsError(try service.resolveElementRef(fresh, app: app.name))
        }
    }

    func testNativeWindowBindingRejectsReusedProcessAndWindowNumbers() {
        let bundle = "test.native-ref"
        let firstLaunch = Date(timeIntervalSince1970: 42)
        let original = TargetedAppIdentity(pid: 312, bundleIdentifier: bundle, launchedAt: firstLaunch)
        let binding = NativeWindowObservation(id: 17, app: original)
        XCTAssertTrue(binding.matches(windowID: 17, app: original))
        XCTAssertFalse(binding.matches(windowID: 18, app: original))
        XCTAssertFalse(binding.matches(windowID: 17, app: .init(
            pid: 312, bundleIdentifier: bundle, launchedAt: firstLaunch.addingTimeInterval(1)
        )))
        XCTAssertFalse(binding.matches(windowID: 17, app: .init(pid: 313, bundleIdentifier: bundle, launchedAt: firstLaunch)))
        XCTAssertFalse(binding.matches(windowID: 17, app: .init(pid: 312, bundleIdentifier: bundle, launchedAt: nil)))
    }

    func testMCPReportsNativeRefFailureCode() throws {
        let server = StdioMCPServer(trajectoryEnvironment: ["OPEN_COMPUTER_USE_TRAJECTORY_LOG": "0"])
        let line = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click","arguments":{"app":"NativeRefFixture","ref":"missing"}}}
        """
        let response = try XCTUnwrap(server.handle(line: line))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(body["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["_meta"] as? [String: Any])?["godspeed/error_code"] as? String, "STALE_REF")
    }

    func testNativeRefArgumentsDoNotFallBackToAnotherTarget() throws {
        let dispatcher = ComputerUseToolDispatcher()
        let app = "NoSuchNativeRefTestApp"
        let badSteps: [[String: Any]] = [
            ["tool": "click", "ref": "expired", "label": "Send"],
            ["tool": "click", "ref": "expired", "x": 10, "y": 15],
            ["tool": "fill_form", "ref": "expired", "fields": ["Message": "Example"]],
            ["tool": "type_text", "ref": "expired", "text": "Example"],
        ]
        for step in badSteps {
            let result = dispatcher.callToolAsResult(name: "batch", arguments: ["app": app, "steps": [step]])
            XCTAssertTrue(result.isError, result.textContent)
            XCTAssertEqual(result.failureCode, .invalidArguments)
            XCTAssertNil(result.batchReceipt, result.textContent)
        }
        let noAX = dispatcher.callToolAsResult(name: "get_app_state", arguments: [
            "app": app, "include_refs": true, "include_ax": false,
        ])
        XCTAssertEqual(noAX.failureCode, .invalidArguments)
    }

    func testFormExpansion() throws {
        try run("forms") { seed in
            let value = "Answer \(seed)"
            let submit = seed.isMultiple(of: 2)
            var form: [String: Any] = ["tool": "fill", "fields": [["label": "Answer", "value": value]]]
            if submit { form["submit"] = "Send" }
            let steps = try BatchTool.parseSteps([form], defaultApp: "Fixture")
            let observed = steps.map(\.tool).joined(separator: ",") + ":" + (steps.first?.arguments["value"] as? String ?? "")
            return (["value": value, "submit": String(submit)], (submit ? "set_value,click:" : "set_value:") + value, observed)
        }
    }

    func testUnicodeTyping() throws {
        try run("typing") { seed in
            let prefix = String(repeating: "a", count: seed % 31) + "🦊"
            let value = "\(prefix)OLD-\(seed)"
            let insert = "新\(seed)🟣"
            let selection = CFRange(location: prefix.utf16.count, length: 3)
            let result = typedTextReplacement(value: value, selection: selection, text: insert)
            let expected = "\(prefix)\(insert)-\(seed)@\((prefix + insert).utf16.count)"
            let observed = result.map { "\($0.value)@\($0.caret)" } ?? "nil"
            return (["before": value, "insert": insert], expected, observed)
        }
    }

    func testClipboardIsolation() throws {
        try run("clipboard") { seed in
            let first = PrivateClipboard()
            let second = PrivateClipboard()
            let value = "Copied \(seed) 🟣"
            try first.writeText(value)
            try second.writeText("Other \(seed)")
            let observed = try first.textForPaste()
            first.clear()
            let isolated = try second.textForPaste() == "Other \(seed)"
            return (["copy": value], "\(value):true:true", "\(observed):\(isolated):\((try? first.textForPaste()) == nil)")
        }
    }

    func testBatchResume() throws {
        try run("batch_resume") { seed in
            let total = 2 + seed % 47
            let completed = (seed / 47) % (total + 1)
            var receipt = TrajectoryLog.BatchReceipt(totalSteps: total)
            receipt.steps = Array(repeating: .init(), count: completed)
            receipt.stop = seed.isMultiple(of: 2) ? .timeBudget : .windowChanged
            let actual = receipt.recovery.map { "\($0["action"] ?? ""):\($0["step"] ?? "")" } ?? "complete"
            let expected = completed == total ? "complete" : "refresh_then_continue:\(completed + 1)"
            return (["total": String(total), "completed": String(completed)], expected, actual)
        }
    }

    func testFileSelectionVerification() throws {
        try run("files") { seed in
            let name = "clip-\(seed).mov"
            let size = 100 + seed
            let actualName = seed % 4 == 1 ? "wrong.mov" : name
            let actualSize = seed % 4 == 2 ? size + 1 : size
            let count = seed % 4 == 3 ? 2 : 1
            let rows: [[Any]] = Array(repeating: [actualName, actualSize], count: count)
            let match = BrowserPage.matchesUploadSelection(rows, expected: [.init(name: name, size: size)])
            return (["file": name, "selected": actualName, "size": String(size), "selected_size": String(actualSize), "count": String(count)], String(seed % 4 == 0), String(match))
        }
    }

    func testDragArguments() throws {
        try run("drag") { seed in
            let complete = seed.isMultiple(of: 2)
            var args: [String: Any] = ["app": "Fixture", "from_x": Double(seed), "from_y": 20.0, "to_x": 30.0]
            if complete { args["to_y"] = Double(seed + 60) }
            let accepted = ArgumentNormalizer.problem(tool: "drag", arguments: args) == nil
            return (["x": String(seed), "complete": String(complete)], String(complete), String(accepted))
        }
    }

    private func ax(_ role: String, _ label: String, _ index: Int, state: String) -> [String: Any] {
        ["role": ["value": role], "name": ["value": label], "backendDOMNodeId": index,
         "properties": [["name": state, "value": ["value": true]]]]
    }

    func testSearchObservation() throws {
        try run("search") { seed in
            let query = "Search inventory \(seed)"
            let results = BrowserPage.parseAX([
                ax("searchbox", query, seed + 1, state: "focused"),
                ax("button", "Clear", seed + 2, state: "disabled"),
            ])
            let control = results.controls.first { $0.name == query }
            let actual = control.map { "\($0.name):\($0.observedStates.contains("focused"))" } ?? "missing"
            return (["query": query], "\(query):true", actual)
        }
    }

    func testMediaObservation() throws {
        try run("media") { seed in
            let track = "Track \(seed)"
            let label = seed.isMultiple(of: 2) ? "Play \(track)" : "Pause \(track)"
            let controls = BrowserPage.parseAX([
                ax("button", label, seed + 1, state: "focused"),
                ax("button", "Next from \(track)", seed + 2, state: "disabled"),
            ]).controls
            let nextDisabled = controls.last?.observedStates.contains("disabled") == true
            return (["track": track, "control": label], "\(label):true", "\(controls.first?.name ?? "missing"):\(nextDisabled)")
        }
    }

    func testNavigationIdentity() throws {
        try run("navigation") { seed in
            func document(_ child: String) throws -> BrowserDocumentIdentity {
                try XCTUnwrap(BrowserDocumentIdentity(tree: [
                    "frame": ["id": "root", "loaderId": "root-\(seed)"],
                    "childFrames": [["frame": ["id": "child", "loaderId": child]]],
                ]))
            }
            let before = try document("before-\(seed)")
            let same = seed.isMultiple(of: 2)
            let after = try document(same ? "before-\(seed)" : "after-\(seed)")
            let memory = BrowserPageMemory()
            let bridge = BrowserBridge(sessionID: "scenario-\(seed)")
            memory.store([], bridge: bridge, tab: seed, document: before, generation: bridge.referenceGeneration)
            let available = memory.observation(bridge: bridge, tab: seed, document: after) != nil
            return (["tab": String(seed), "same_document": String(same)], String(same), String(available))
        }
    }

    func testCrossSurfaceCompletion() throws {
        try run("cross_surface") { seed in
            let destination = "/receipts/\(seed)/"
            let file = "/fixture/receipt-\(seed).pdf"
            let url = seed % 4 == 1 ? "/wrong/" : destination
            let visible = seed % 4 != 2
            let saved = seed % 4 != 3
            let result = DoneCheck.check([.urlContains(destination), .text("Export complete"), .fileExists(file)],
                evidence: .init(screenText: visible ? "Export complete" : nil,
                                pageURL: { url }, fileExists: { $0 == file && saved }))
            let actual: String
            switch result {
            case .verified: actual = "verified"
            case .weak: actual = "weak_evidence"
            case .missing(let unmet): actual = unmet.joined(separator: ",")
            }
            let expected = ["weak_evidence", "the page URL contains \(destination)", "\"Export complete\" is on screen", "file \(file) exists"][seed % 4]
            return (["url": url, "visible": String(visible), "saved": String(saved)], expected, actual)
        }
    }

    func testFileClipboardOwnership() throws {
        try run("file_clipboard") { seed in
            let clipboard = PrivateClipboard()
            let original = PrivateClipboard.Payload.files(paths: ["/fixture/\(seed)"], move: seed.isMultiple(of: 2))
            clipboard.write(original)
            let matches = seed % 3 == 0
            let replacement = PrivateClipboard.Payload.text("new \(seed)")
            if !matches { clipboard.write(replacement) }
            clipboard.clear(matching: original)
            let actual = clipboard.payload == (matches ? nil : replacement)
            return (["changed_since_copy": String(!matches)], "true", String(actual))
        }
    }

    func testRejectedUnicodeCaret() throws {
        try run("invalid_caret") { seed in
            let prefix = String(repeating: "x", count: seed % 77)
            let value = prefix + "🦊" + String(seed)
            let offset = seed.isMultiple(of: 2) ? prefix.utf16.count + 1 : value.utf16.count + 1
            let result = typedTextReplacement(value: value, selection: CFRange(location: offset, length: 0), text: "x")
            return (["value": value, "utf16_offset": String(offset)], "rejected", result == nil ? "rejected" : "accepted")
        }
    }

    func testKeyboardSymbols() throws {
        try run("keyboard") { seed in
            let key = String(UnicodeScalar(97 + seed % 26)!)
            let modifier = [("⌘", "super"), ("⇧", "shift"), ("⌥", "alt"), ("⌃", "ctrl")][seed % 4]
            let padding = String(repeating: " ", count: seed / 104)
            let input = padding + modifier.0 + key.uppercased() + padding
            return (["shortcut": input], modifier.1 + "+" + key, ArgumentNormalizer.normalizeKey(input))
        }
    }

    func testIncompleteObservation() throws {
        try run("incomplete_observation") { seed in
            let label = "Loading \(seed)"
            let full = seed.isMultiple(of: 2)
            let screen = seed % 3 == 0 ? "1 button \(label)" : "1 button Continue"
            let result = DoneCheck.check([.gone(label)], evidence: .init(
                screenText: screen, pageURL: { nil }, supportsAbsence: full
            ))
            let matched: Bool
            if case .weak = result { matched = true } else { matched = false }
            return (["complete": String(full), "screen": screen], String(full && seed % 3 != 0), String(matched))
        }
    }
}
