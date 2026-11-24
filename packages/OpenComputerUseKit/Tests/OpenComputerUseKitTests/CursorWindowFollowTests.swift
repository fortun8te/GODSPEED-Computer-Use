import AppKit
import XCTest
@testable import OpenComputerUseKit

final class CursorWindowFollowTests: XCTestCase {
    @MainActor
    func testFirstFrameAfterWindowChangeIsInsideDestinationWindow() throws {
        try withOverlay { _, _ in
            let screen = try XCTUnwrap(NSScreen.screens.first).visibleFrame
            let mapping = try XCTUnwrap(currentVisualCursorScreenMappings().first { $0.appKitFrame.contains(CGPoint(x: screen.midX, y: screen.midY)) })
            let sourceFrame = CGRect(x: screen.midX - 300, y: screen.midY, width: 120, height: 90)
            let destinationFrame = CGRect(x: screen.midX + 110, y: screen.midY, width: 120, height: 90)
            let source = NSPanel(contentRect: sourceFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let destination = NSPanel(contentRect: destinationFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            destination.level = .floating
            source.orderFrontRegardless()
            destination.orderFrontRegardless()
            defer {
                SoftwareCursorOverlay.frameObserverForTesting = nil
                source.orderOut(nil)
                destination.orderOut(nil)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let sourceWindow = CursorTargetWindow(windowID: CGWindowID(source.windowNumber), layer: source.level.rawValue)
            let destinationWindow = CursorTargetWindow(windowID: CGWindowID(destination.windowNumber), layer: destination.level.rawValue)
            let nativeBounds = CGRect(x: destinationFrame.minX - mapping.appKitFrame.minX + mapping.screenStateFrame.minX,
                                      y: mapping.appKitFrame.maxY - destinationFrame.maxY + mapping.screenStateFrame.minY,
                                      width: destinationFrame.width, height: destinationFrame.height)
            let anchor = CursorRestingAnchor(windowID: destinationWindow.windowID, layer: destinationWindow.layer,
                                            windowLocalPoint: CGPoint(x: nativeBounds.width / 2, y: nativeBounds.height / 2),
                                            windowBounds: nativeBounds)
            SoftwareCursorOverlay.settle(at: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY), in: sourceWindow)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            var points: [CGPoint] = []
            SoftwareCursorOverlay.frameObserverForTesting = { _, frame, _ in points.append(frame.tipPosition) }
            SoftwareCursorOverlay.moveCursor(to: CGPoint(x: destinationFrame.midX, y: destinationFrame.midY), in: destinationWindow, anchor: anchor)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            XCTAssertTrue(destinationFrame.contains(try XCTUnwrap(points.first)))
            XCTAssertTrue(points.allSatisfy { destinationFrame.contains($0) })
            XCTAssertEqual(SoftwareCursorOverlay.overlayPanelForTesting?.level, destination.level)
        }
    }

    @MainActor
    func testRestingCursorStaysStillBeforeAndAfterTyping() throws {
        try withOverlay { file, frame in
            let target = point(frame)
            func observation() throws -> VisualCursorObservationSnapshot {
                SoftwareCursorOverlay.flushObservationsForTesting()
                return try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            }
            SoftwareCursorOverlay.settle(at: target, in: nil)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            let before = try observation()
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            let resting = try observation()
            XCTAssertEqual(resting.timestamp, before.timestamp, "resting must not repaint")
            XCTAssertEqual(try XCTUnwrap(resting.rotation), 0, accuracy: 0.001)

            SoftwareCursorOverlay.beginFeedback(.typing)
            XCTAssertEqual(try observation().phase, "typing")
            SoftwareCursorOverlay.endFeedback(.typing)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let settled = try observation()
            XCTAssertEqual(settled.phase, "idle")
            XCTAssertEqual(try XCTUnwrap(settled.rotation), 0, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(settled.tipPosition).x, target.x, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(settled.tipPosition).y, target.y, accuracy: 0.5)

            SoftwareCursorOverlay.reset()
            XCTAssertEqual(try observation().phase, "hidden")
        }
    }

    @MainActor
    func testCursorGlidesToBottomLeftWithoutLeavingTheDisplay() throws {
        try withOverlay { file, _ in
            let frame = try XCTUnwrap(NSScreen.screens.first).frame
            let target = CGPoint(x: frame.minX + 2, y: frame.minY + 2)
            let start = CGPoint(x: target.x + 280, y: target.y + 22)
            SoftwareCursorOverlay.settle(at: start, in: nil)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            var samples: [CGPoint] = []
            let timer = Timer(timeInterval: 0.012, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if let data = try? Data(contentsOf: file),
                       let sample = try? JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: data),
                       let point = sample.tipPosition {
                        samples.append(CGPoint(x: point.x, y: point.y))
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            SoftwareCursorOverlay.moveCursor(to: target, in: nil)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            SoftwareCursorOverlay.flushObservationsForTesting()
            let final = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            let actual = try XCTUnwrap(final.tipPosition)
            XCTAssertEqual(actual.x, target.x, accuracy: 0.5)
            XCTAssertEqual(actual.y, target.y, accuracy: 0.5)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertGreaterThan(samples.count, 5)
                // Next to the display edge the move still arcs, but the planner keeps the whole arc on the display.
                XCTAssertTrue(samples.allSatisfy { frame.contains($0) && $0.y >= target.y - 0.5 })
                XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $1.x <= $0.x + 0.5 })
            }
        }
    }

    @MainActor
    func testReschedulingHideKeepsTheCursorStillUntilTheDeadline() throws {
        try withOverlay { file, frame in
            SoftwareCursorOverlay.settle(at: point(frame), in: nil)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            SoftwareCursorOverlay.scheduleHide(after: 1.2)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            SoftwareCursorOverlay.flushObservationsForTesting()
            let resting = try Data(contentsOf: file)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            SoftwareCursorOverlay.flushObservationsForTesting()
            XCTAssertEqual(try Data(contentsOf: file), resting)
            XCTAssertTrue(SoftwareCursorOverlay.overlayPanelForTesting?.isVisible ?? false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            SoftwareCursorOverlay.flushObservationsForTesting()
            let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            XCTAssertEqual(state.phase, "hidden")
        }
    }

    @MainActor
    func testResetAbortsInFlightHideFade() throws {
        try withOverlay { file, frame in
            SoftwareCursorOverlay.settle(at: point(frame), in: nil)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            SoftwareCursorOverlay.scheduleHide(after: 0.02)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            SoftwareCursorOverlay.reset()
            SoftwareCursorOverlay.flushObservationsForTesting()
            let resetState = try Data(contentsOf: file)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            SoftwareCursorOverlay.flushObservationsForTesting()
            XCTAssertEqual(try Data(contentsOf: file), resetState, "The old fade must not finish after reset")
            SoftwareCursorOverlay.settle(at: point(frame), in: nil)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            SoftwareCursorOverlay.flushObservationsForTesting()
            let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            XCTAssertEqual(state.phase, "idle")
            XCTAssertNotNil(state.tipPosition)
        }
    }
    @MainActor
    private final class Counter: NSObject {
        var count = 0
        @objc func increment() { count += 1 }
    }
    private final class Frame: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGRect
        init(_ value: CGRect) { stored = value }
        var value: CGRect {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
    @MainActor
    private func withOverlay(_ body: (URL, CGRect) throws -> Void) throws {
        guard let screen = currentVisualCursorScreenMappings().first?.screenStateFrame else {
            throw XCTSkip("A WindowServer display is required for overlay rendering")
        }
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-cursor-follow-\(UUID().uuidString).json")
        let previous = ProcessInfo.processInfo.environment
        setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR", "1", 1)
        setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", file.path, 1)
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0", 1)
        // These tests move a window while the cursor travels, so the travel has to last about a
        // second as it did upstream (OCU Fast's default is 80 to 180 ms).
        setenv("OPEN_COMPUTER_USE_CURSOR_SPEED", "0.4", 1)
        SoftwareCursorOverlay.moveCursor(to: defaultVisualCursorInitialTipPosition(), in: nil)
        SoftwareCursorOverlay.waitUntilIdleForTesting()
        SoftwareCursorOverlay.reset()
        defer {
            SoftwareCursorOverlay.reset()
            CursorWindowFrameTracker.installFrameOverrideForTesting(nil)
            CursorWindowFrameTracker.forgetAll()
            for key in ["OPEN_COMPUTER_USE_VISUAL_CURSOR", "OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", "OPEN_COMPUTER_USE_ACTION_READ_BACK", "OPEN_COMPUTER_USE_CURSOR_SPEED"] {
                if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
            SoftwareCursorOverlay.flushObservationsForTesting()
            try? FileManager.default.removeItem(at: file)
        }
        try body(file, CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 200, height: 160))
    }

    private func anchor(_ frame: CGRect) -> CursorRestingAnchor {
        .init(windowID: 4242, layer: 0, windowLocalPoint: CGPoint(x: 40, y: 50), windowBounds: frame)
    }

    @MainActor
    private func point(_ frame: CGRect) -> CGPoint {
        screenStatePointToAppKitGlobalPoint(fromScreenStatePoint: CGPoint(x: frame.minX + 40, y: frame.minY + 50))
    }

    @MainActor
    private func assertPosition(_ file: URL, frame: CGRect, file testFile: StaticString = #filePath, line: UInt = #line) throws {
        SoftwareCursorOverlay.flushObservationsForTesting()
        let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
        let expected = point(frame)
        XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).x, expected.x, accuracy: 1, file: testFile, line: line)
        XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).y, expected.y, accuracy: 1, file: testFile, line: line)
        XCTAssertEqual(try XCTUnwrap(state.tipPosition).x, expected.x, accuracy: 1, file: testFile, line: line)
        XCTAssertEqual(try XCTUnwrap(state.tipPosition).y, expected.y, accuracy: 1, file: testFile, line: line)
    }

    @MainActor
    func testIdleFollowsRepeatedMovesAndReturnToOriginalFrame() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            for frame in [original.offsetBy(dx: 240, dy: 80), original.offsetBy(dx: 80, dy: 160), original] {
                live.value = frame
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                try assertPosition(file, frame: frame)
            }
        }
    }

    @MainActor
    func testClickPulseTracksMovesDuringBothClicks() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            let first = Timer(timeInterval: 0.04, repeats: false) { _ in live.value = original.offsetBy(dx: 180, dy: 40) }
            let second = Timer(timeInterval: 0.24, repeats: false) { _ in live.value = original.offsetBy(dx: 260, dy: 100) }
            RunLoop.main.add(first, forMode: .common)
            RunLoop.main.add(second, forMode: .common)
            defer { first.invalidate(); second.invalidate() }
            SoftwareCursorOverlay.pulseClick(at: point(original), clickCount: 2, mouseButton: .left, in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            try assertPosition(file, frame: live.value)
        }
    }

    @MainActor
    func testTravelAbortActuallyPlacesVisibleTipAtMovedWindow() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            let timer = Timer(timeInterval: 0.04, repeats: false) { _ in live.value = original.offsetBy(dx: 240, dy: 100) }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            SoftwareCursorOverlay.moveCursor(to: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            try assertPosition(file, frame: live.value)
            // The next pipeline stage must not restore the snapshot's old point.
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            try assertPosition(file, frame: live.value)
        }
    }

    @MainActor
    func testUnanchoredTargetDoesNotKeepPreviousWindowTracking() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            SoftwareCursorOverlay.settle(at: point(original), in: nil)
            live.value = original.offsetBy(dx: 240, dy: 100)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            try assertPosition(file, frame: original)
        }
    }

    @MainActor
    func testResetAfterPulseDoesNotLeaveAnIdleTimerRepainting() throws {
        try withOverlay { file, original in
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in original }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            SoftwareCursorOverlay.pulseClick(at: point(original), clickCount: 1, mouseButton: .left, in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            SoftwareCursorOverlay.reset()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            SoftwareCursorOverlay.flushObservationsForTesting()
            let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            XCTAssertEqual(state.phase, "hidden")
            XCTAssertNil(state.tipPosition)
            XCTAssertNil(state.restingTipPosition)
        }
    }

    @MainActor
    func testWindowAlreadyMovedBeforeTravelDoesNotAbortAgainstOriginalSnapshot() throws {
        try withOverlay { _, original in
            let moved = original.offsetBy(dx: 240, dy: 100)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in moved }
            let start = ProcessInfo.processInfo.systemUptime
            SoftwareCursorOverlay.moveCursor(to: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        }
    }

    @MainActor
    func testServiceClickRegistersLiveWindowAndFeedbackMatchesMovedButton() throws {
        do { try requireUsableComputerUseSession() }
        catch { throw XCTSkip("Service integration requires an unlocked session and a trusted test host: \(error)") }
        try withOverlay { file, original in
            let counter = Counter()
            let window = NSWindow(contentRect: original, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "OCU service click fixture"
            window.isReleasedWhenClosed = false
            let button = NSButton(title: "OCU follow click", target: counter, action: #selector(Counter.increment))
            button.frame = CGRect(x: 20, y: 20, width: 140, height: 32)
            window.contentView?.addSubview(button)
            NSApplication.shared.finishLaunching()
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            guard AXIsProcessTrusted(), let app = AppDiscovery.runningApps().first(where: { $0.pid == getpid() }) else {
                throw XCTSkip("Live AX test application is unavailable")
            }
            let service = ComputerUseService()
            let result = try service.query(app: app.bundleIdentifier ?? app.name, text: button.title, role: "button",
                                           exact: true, windowID: CGWindowID(window.windowNumber))
            let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
            XCTAssertEqual(matches.count, 1)
            let index = try XCTUnwrap(matches.first?["index"] as? Int)
            let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
                MainActor.assumeIsolated {
                    window.setFrameOrigin(CGPoint(x: original.minX + 240, y: original.minY + 80))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            _ = try service.click(app: app.bundleIdentifier ?? app.name, elementIndex: String(index),
                                  x: nil, y: nil, clickCount: 1, mouseButton: "left", clickMethod: .accessibility)
            XCTAssertEqual(counter.count, 1, "The real AX button action must still execute exactly once")
            // The service queues cursor drawing on the main queue (async animation): drain it
            // the way a long-lived MCP server would, then read the settled frame.
            let drainDeadline = Date().addingTimeInterval(3.0)
            while VisualCursorSupport.queuedAnimations > 0 && Date() < drainDeadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            SoftwareCursorOverlay.waitUntilIdleForTesting(timeout: 6)
            XCTAssertEqual(window.frame.minX, original.minX + 240, accuracy: 1, "The fixture must move the live window")
            SoftwareCursorOverlay.flushObservationsForTesting()
            let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            let expected = window.convertPoint(toScreen: CGPoint(x: button.frame.midX, y: button.frame.midY))
            XCTAssertEqual(try XCTUnwrap(state.tipPosition).x, expected.x, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(state.tipPosition).y, expected.y, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).x, expected.x, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).y, expected.y, accuracy: 1)
        }
    }

    @MainActor
    func testRealAccessibilityWindowFollowsTravelPulseAndIdleAcrossDisplays() throws {
        try withOverlay { file, original in
            let window = NSWindow(contentRect: original, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "OCU cursor follow fixture \(UUID().uuidString)"
            window.isReleasedWhenClosed = false
            NSApplication.shared.finishLaunching()
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let application = AXUIElementCreateApplication(getpid())
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
            guard status == .success,
                  let windows = raw as? [AXUIElement],
                  let element = windows.first(where: { element in
                      var title: CFTypeRef?
                      return AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success &&
                          title as? String == window.title
                  })
            else { throw XCTSkip("Live self-AX window access unavailable (AX status \(status.rawValue), trusted \(AXIsProcessTrusted()))") }
            let id = CGWindowID(window.windowNumber)
            CursorWindowFrameTracker.register(windowID: id, element: element)
            func awaitFrame(_ predicate: (CGRect) -> Bool) throws -> CGRect {
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline {
                    if let frame = CursorWindowFrameTracker.liveFrame(for: id), predicate(frame) { return frame }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                XCTFail("Real AX frame was not observed before deadline")
                throw NSError(domain: "CursorFollowTests", code: 1)
            }
            let initial = try awaitFrame { _ in true }
            let targetAnchor = CursorRestingAnchor(windowID: id, layer: 0, windowLocalPoint: CGPoint(x: 40, y: 50), windowBounds: initial)
            let move = Timer(timeInterval: 0.08, repeats: false) { _ in
                MainActor.assumeIsolated {
                    window.setFrameOrigin(CGPoint(x: original.minX + 200, y: original.minY + 40))
                }
            }
            RunLoop.main.add(move, forMode: .common)
            defer { move.invalidate() }
            SoftwareCursorOverlay.moveCursor(to: point(initial), in: nil, anchor: targetAnchor)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            let afterTravel = try awaitFrame { abs($0.minX - (initial.minX + 200)) < 1 }
            try assertPosition(file, frame: afterTravel)
            SoftwareCursorOverlay.settle(at: point(initial), in: nil, anchor: targetAnchor)
            try assertPosition(file, frame: afterTravel)
            let duringPulse = Timer(timeInterval: 0.06, repeats: false) { _ in
                MainActor.assumeIsolated {
                    window.setFrameOrigin(CGPoint(x: original.minX + 260, y: original.minY + 100))
                }
            }
            RunLoop.main.add(duringPulse, forMode: .common)
            defer { duringPulse.invalidate() }
            SoftwareCursorOverlay.pulseClick(at: point(initial), clickCount: 2, mouseButton: .left, in: nil, anchor: targetAnchor)
            SoftwareCursorOverlay.waitUntilIdleForTesting()
            let afterPulse = try awaitFrame { abs($0.minX - (initial.minX + 260)) < 1 }
            try assertPosition(file, frame: afterPulse)
            for offset in [CGPoint(x: 220, y: 60), CGPoint(x: 100, y: 140), .zero] {
                window.setFrameOrigin(CGPoint(x: original.minX + offset.x, y: original.minY + offset.y))
                let moved = try awaitFrame { abs($0.minX - (initial.minX + offset.x)) < 1 }
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                SoftwareCursorOverlay.waitUntilIdleForTesting()
                try assertPosition(file, frame: moved)
            }
            for mapping in currentVisualCursorScreenMappings() {
                window.setFrameOrigin(CGPoint(x: mapping.appKitFrame.minX + 120, y: mapping.appKitFrame.minY + 120))
                let moved = try awaitFrame { abs($0.minX - (mapping.screenStateFrame.minX + 120)) < 1 }
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                SoftwareCursorOverlay.waitUntilIdleForTesting()
                try assertPosition(file, frame: moved)
            }
            print("Live AX cursor following verified on \(currentVisualCursorScreenMappings().count) display(s).")
        }
    }
}
