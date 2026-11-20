import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class BackgroundDragTests: XCTestCase {
    private let target = BackgroundDragTarget(
        start: CGPoint(x: -80, y: 140), end: CGPoint(x: 80, y: 220),
        windowBounds: CGRect(x: -100, y: 100, width: 300, height: 200), windowID: 42, pid: 123
    )

    private final class Probe {
        var events: [CGEvent] = []
        var locations: [CGPoint] = []
        var lifecycle: [String] = []
        var pauses: [TimeInterval] = []
        var foreground = false
        var validations = 0
        var failValidation: Int?
        var failStamp = false
        var failMakeKey = false
        var failEnd = false
        var posted: ((CGEvent) -> Void)?
        var windowLocationCapability = SkyLightSPICapability(missingSymbols: [], feature: "drag window location")
        var focusCapability = SkyLightSPICapability(missingSymbols: [], feature: "background drag synthetic focus")
        var io: BackgroundDragIO {
            BackgroundDragIO(
                windowLocationCapability: windowLocationCapability,
                focusCapability: focusCapability,
                validateWindow: { _ in
                    self.validations += 1
                    if self.validations == self.failValidation { throw ComputerUseError.stateUnavailable("window changed") }
                },
                needsFocus: { _ in !self.foreground },
                beginFocus: { target in
                    self.lifecycle.append("activate")
                    return SkyLightSyntheticFocusContext(deactivateTarget: SkyLightActivationCommand(psn: [], windowID: target.windowID, focused: false))
                },
                makeKey: { _ in
                    self.lifecycle.append("key")
                    if self.failMakeKey { throw ComputerUseError.message("key failed") }
                },
                endFocus: { _ in
                    self.lifecycle.append("deactivate")
                    if self.failEnd { throw ComputerUseError.message("cleanup failed") }
                },
                setWindowLocation: { _, point in
                    if self.failStamp { throw ComputerUseError.message("stamp failed") }
                    self.locations.append(point)
                },
                post: { event, _ in
                    self.events.append(event)
                    self.lifecycle.append("event:\(event.type.rawValue)")
                    self.posted?(event)
                },
                release: { event, _ in
                    self.events.append(event)
                    self.lifecycle.append("release")
                },
                pause: { self.pauses.append($0) }
            )
        }
    }

    func testPreciseClickPairsPreserveModifiersAndRecheckTarget() throws {
        let probe = Probe()
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        var checks = 0
        try BackgroundDragDispatcher.click(target: target, button: .left, count: 3, flags: flags,
                                            io: probe.io, validateSession: {}) { checks += 1 }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(probe.events.map(\.type), [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(probe.events.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2, 3, 3])
        XCTAssertTrue(probe.events.allSatisfy { $0.flags == flags })
        XCTAssertFalse(probe.lifecycle.contains("activate"))

        let stale = Probe()
        XCTAssertThrowsError(try BackgroundDragDispatcher.click(target: target, button: .left, count: 2,
            flags: [], io: stale.io, validateSession: {}) {
            if !stale.events.isEmpty { throw ComputerUseError.stateUnavailable("Control moved.") }
        }) { XCTAssertTrue($0.localizedDescription.contains("Sent 1 of 2")) }
        XCTAssertEqual(stale.events.map(\.type), [.leftMouseDown, .leftMouseUp])
    }

    func testHoverPostsOneMoveWithoutFocusOrButtonEvents() throws {
        let probe = Probe()
        try BackgroundDragDispatcher.hover(target: target, io: probe.io, validateSession: {})
        XCTAssertEqual(probe.events.map(\.type), [.mouseMoved])
        XCTAssertEqual(probe.events.first?.getIntegerValueField(CGEventField(rawValue: 51)!), 42)
        XCTAssertEqual(probe.locations, [CGPoint(x: 20, y: 40)])
        XCTAssertFalse(probe.lifecycle.contains("activate"))

        let stale = Probe()
        stale.failValidation = 2
        XCTAssertThrowsError(try BackgroundDragDispatcher.hover(target: target, io: stale.io, validateSession: {}))
        XCTAssertTrue(stale.events.isEmpty)
    }

    func testOneWindowAddressedGestureWithoutPrimerOrDuplicatePosts() throws {
        let probe = Probe()
        try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {})
        XCTAssertEqual(probe.events.map(\.type), [.mouseMoved, .leftMouseDown] + Array(repeating: .leftMouseDragged, count: 10) + [.leftMouseUp])
        XCTAssertEqual(Array(probe.lifecycle.prefix(2)), ["activate", "key"])
        XCTAssertEqual(Array(probe.lifecycle.suffix(2)), ["release", "deactivate"])
        XCTAssertTrue(probe.events.allSatisfy { $0.getIntegerValueField(CGEventField(rawValue: 51)!) == 42 })
        XCTAssertTrue(probe.events.allSatisfy { $0.flags.isEmpty })
        XCTAssertEqual(probe.events.first?.location, target.start)
        XCTAssertEqual(probe.events.last?.location, target.end)
        XCTAssertEqual(probe.events.filter { $0.type == .leftMouseUp }.count, 1)
        XCTAssertTrue(probe.locations.allSatisfy { CGRect(origin: .zero, size: target.windowBounds.size).contains($0) })
        XCTAssertEqual(probe.locations.first, CGPoint(x: 20, y: 40))
        XCTAssertEqual(probe.locations.last, CGPoint(x: 180, y: 120))
    }

    func testDragHonorsHoldStepsAndRefusesChangedEndpointsBeforeDown() throws {
        let probe = Probe()
        try BackgroundDragDispatcher.drag(target: target, steps: 4, hold: 0.4, io: probe.io, validateSession: {})
        XCTAssertEqual(probe.events.filter { $0.type == .leftMouseDragged }.count, 4)
        XCTAssertTrue(probe.pauses.contains(0.4))
        XCTAssertEqual(probe.events.last?.location, target.end)

        let stale = Probe()
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: stale.io, validateSession: {}) {
            throw ComputerUseError.stateUnavailable("Endpoint moved.")
        })
        XCTAssertEqual(stale.events.map(\.type), [.mouseMoved])
    }

    func testModifiedDragKeepsFlagsAndMotionTogetherUntilRelease() throws {
        let probe = Probe()
        let flags = try dragModifierFlags(["shift", "option"])
        try BackgroundDragDispatcher.drag(target: target, flags: flags, io: probe.io, validateSession: {})
        XCTAssertEqual(flags, [.maskShift, .maskAlternate])
        let motion = probe.events.filter { $0.type == .leftMouseDragged }
        XCTAssertTrue(probe.events.allSatisfy { $0.flags == flags })
        XCTAssertEqual(motion.map { $0.getIntegerValueField(.mouseEventDeltaX) }, Array(repeating: 16, count: 10))
        XCTAssertEqual(motion.map { $0.getIntegerValueField(.mouseEventDeltaY) }, Array(repeating: 8, count: 10))
        let gesture = Set(probe.events.dropFirst().map { $0.getIntegerValueField(.mouseEventNumber) })
        XCTAssertEqual(gesture.count, 1)
        XCTAssertEqual(probe.events.last?.type, .leftMouseUp)
        XCTAssertThrowsError(try dragModifierFlags(["unspecified"]))
    }

    func testForegroundTargetCanDragWithoutSyntheticFocusSymbols() throws {
        let probe = Probe()
        probe.foreground = true
        probe.focusCapability = SkyLightSPICapability(
            missingSymbols: ["SLPSPostEventRecordTo", "GetProcessForPID"],
            feature: "background drag synthetic focus"
        )
        try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {})
        XCTAssertFalse(probe.lifecycle.contains("activate"))
        XCTAssertFalse(probe.lifecycle.contains("key"))
        XCTAssertFalse(probe.lifecycle.contains("deactivate"))
        XCTAssertEqual(probe.events.map(\.type), [.mouseMoved, .leftMouseDown] + Array(repeating: .leftMouseDragged, count: 10) + [.leftMouseUp])
    }

    func testBackgroundTargetWithoutSyntheticFocusSymbolsIsRejectedBeforeInput() {
        let probe = Probe()
        probe.focusCapability = SkyLightSPICapability(
            missingSymbols: ["SLPSPostEventRecordTo"],
            feature: "background drag synthetic focus"
        )
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {})) { error in
            XCTAssertTrue(String(describing: error).contains("SLPSPostEventRecordTo"))
        }
        XCTAssertTrue(probe.lifecycle.isEmpty)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testTargetThatBecomesRealForegroundIsNotSyntheticallyDeactivated() throws {
        let probe = Probe()
        probe.posted = { if $0.type == .leftMouseDown { probe.foreground = true } }
        try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {})
        XCTAssertTrue(probe.lifecycle.contains("activate"))
        XCTAssertFalse(probe.lifecycle.contains("deactivate"))
        XCTAssertEqual(probe.events.last?.type, .leftMouseUp)
    }

    func testMissingCapabilityAndPreparationFailureHaveNoInputOrFocusSideEffects() {
        let missing = Probe()
        missing.foreground = true
        missing.windowLocationCapability = SkyLightSPICapability(
            missingSymbols: ["CGEventSetWindowLocation"],
            feature: "drag window location"
        )
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: missing.io, validateSession: {}))
        XCTAssertTrue(missing.lifecycle.isEmpty)
        let stamping = Probe(); stamping.failStamp = true
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: stamping.io, validateSession: {}))
        XCTAssertTrue(stamping.lifecycle.isEmpty)
    }

    func testFailedKeyWindowSetupStillReleasesSyntheticFocusWithoutMouseInput() {
        let probe = Probe(); probe.failMakeKey = true
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {}))
        XCTAssertEqual(probe.lifecycle, ["activate", "key", "deactivate"])
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testWindowFailureAtEverySendReleasesOnlyAfterOurPress() {
        // validateWindow is called once before setup and before each send.
        for failingValidation in 1...13 {
            let probe = Probe(); probe.failValidation = failingValidation
            XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {}))
            let pressed = probe.events.contains { $0.type == .leftMouseDown }
            XCTAssertEqual(probe.events.filter { $0.type == .leftMouseUp }.count, pressed ? 1 : 0)
            if failingValidation > 1 { XCTAssertEqual(probe.lifecycle.last, "deactivate") }
            if pressed {
                let lastPosition = probe.events.dropLast().last!.location
                XCTAssertEqual(probe.events.last!.location, lastPosition, "Cleanup releases at the last delivered position")
            }
        }
    }

    func testInitialSessionRefusalNeverSetsFocusOrPostsInput() {
        let probe = Probe()
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {
            throw ComputerUseError.stateUnavailable("session refused")
        }))
        XCTAssertTrue(probe.lifecycle.isEmpty)
    }

    func testRevocationAfterActivationStillReleasesFocusWithoutPressing() {
        let probe = Probe()
        var revoked = false
        var io = probe.io
        let begin = io.beginFocus
        io.beginFocus = { target in
            let focus = try begin(target)
            revoked = true
            return focus
        }
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: io, validateSession: {
            if revoked { throw ComputerUseError.stateUnavailable("lease ended") }
        }))
        XCTAssertEqual(probe.lifecycle, ["activate", "deactivate"])
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testRevokedSessionAfterPressStillReleasesBeforeFocusCleanup() {
        let probe = Probe()
        var revoked = false
        probe.posted = { if $0.type == .leftMouseDown { revoked = true } }
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {
            if revoked { throw ComputerUseError.stateUnavailable("lease ended") }
        }))
        XCTAssertEqual(probe.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(Array(probe.lifecycle.suffix(2)), ["release", "deactivate"])
    }

    func testCancellationAfterPressStillReleasesExactlyOnce() {
        let probe = Probe()
        let token = RequestCancellation()
        probe.posted = { if $0.type == .leftMouseDown { token.cancel() } }
        XCTAssertThrowsError(try RequestCancellation.$current.withValue(token) {
            try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {})
        })
        XCTAssertEqual(probe.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(Array(probe.lifecycle.suffix(2)), ["release", "deactivate"])
    }

    func testCleanupErrorIsReportedEvenWhenAnInputCheckAlsoFailed() {
        let probe = Probe(); probe.failValidation = 4; probe.failEnd = true
        XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: target, io: probe.io, validateSession: {})) { error in
            XCTAssertTrue(String(describing: error).contains("window changed"))
            XCTAssertTrue(String(describing: error).contains("cleanup failed"))
        }
        XCTAssertEqual(probe.events.last?.type, .leftMouseUp)
    }

    func testTargetGeometryRejectsNonFiniteOutsideAndEmptyBoundsBeforeFocus() {
        for invalid in [CGPoint(x: CGFloat.nan, y: 140), CGPoint(x: CGFloat.infinity, y: 140), CGPoint(x: -101, y: 140), CGPoint(x: 200, y: 140)] {
            let probe = Probe()
            let bad = BackgroundDragTarget(start: invalid, end: target.end, windowBounds: target.windowBounds, windowID: target.windowID, pid: target.pid)
            XCTAssertThrowsError(try BackgroundDragDispatcher.drag(target: bad, io: probe.io, validateSession: {}))
            XCTAssertTrue(probe.lifecycle.isEmpty)
        }
        XCTAssertThrowsError(try BackgroundDragTarget(start: .zero, end: .zero, windowBounds: .zero, windowID: 42, pid: 123).validateGeometry())
    }

    func testWindowIdentityAndGeometryCannotBeReplacedBySamePIDOrTitle() throws {
        func record(id: UInt32 = 42, pid: Int32 = 123, bounds: CGRect? = nil) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowBounds as String: (bounds ?? target.windowBounds).dictionaryRepresentation]
        }
        try validateBackgroundDragWindow(target, windowInfo: [record()])
        XCTAssertThrowsError(try validateBackgroundDragWindow(target, windowInfo: []))
        XCTAssertThrowsError(try validateBackgroundDragWindow(target, windowInfo: [record(id: 99)]))
        XCTAssertThrowsError(try validateBackgroundDragWindow(target, windowInfo: [record(pid: 456)]))
        XCTAssertThrowsError(try validateBackgroundDragWindow(target, windowInfo: [record(bounds: target.windowBounds.offsetBy(dx: 1, dy: 0))]))
    }

    func testServiceRejectsNonFiniteCoordinatesBeforeLookingUpAnyApp() {
        for coordinate in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try ComputerUseService().drag(app: "missing-test-app", fromX: coordinate, fromY: 1, toX: 2, toY: 3)) { error in
                XCTAssertTrue(String(describing: error).contains("finite coordinates"))
            }
        }
    }

    func testBackgroundDragSnapshotRecoveryCannotActivateTarget() {
        XCTAssertEqual(dragActionSnapshotRecoveryPolicy(for: .appPost), .readOnly)
        XCTAssertEqual(dragActionSnapshotRecoveryPolicy(for: .global), .allowActivation)
    }
}
