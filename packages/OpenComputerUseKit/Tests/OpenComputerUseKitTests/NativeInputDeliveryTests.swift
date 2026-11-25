import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class NativeInputDeliveryTests: XCTestCase {
    func testExpiredRequestBudgetReportsNothingSent() {
        XCTAssertThrowsError(try BrowserCallBudget.withDeadline(0) {
            try NativeInputDelivery().check()
        }) { error in
            XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent)
            guard case ComputerUseError.timedOut = error else {
                return XCTFail("Expected a deadline error, got \(error)")
            }
        }
    }

    func testCancellationRetainsWhetherEarlierInputWasSent() {
        for alreadySent in [false, true] {
            let token = RequestCancellation()
            let delivery = NativeInputDelivery()
            if alreadySent { delivery.didPost() }
            token.cancel()
            XCTAssertThrowsError(try RequestCancellation.$current.withValue(token) {
                try delivery.check()
            }) { error in
                XCTAssertEqual((error as? RequestCancellation.Cancelled)?.deliveryState,
                               alreadySent ? .outcomeUnknown : .notSent)
            }
        }
    }

    func testExpiredKeyValidationDoesNotPressOrReleaseAnything() throws {
        let chord = try KeyPressParser.parse("shift+Down", layout: { _ in nil })
        var remaining: TimeInterval = 1
        let delivery = NativeInputDelivery(remaining: { remaining })
        XCTAssertThrowsError(try InputSimulation.deliverHeldKey(chord, hold: 0,
            validate: { remaining = 0 }, post: { _ in XCTFail("Expired key-down") },
            release: { _ in XCTFail("Release without a press") }, delivery: delivery)) { error in
            XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent)
        }
    }

    func testCancellationBetweenModifierAndKeyReleasesOnlyTheModifier() throws {
        let chord = try KeyPressParser.parse("shift+Down", layout: { _ in nil })
        let token = RequestCancellation()
        var events: [CGEvent] = []
        XCTAssertThrowsError(try RequestCancellation.$current.withValue(token) {
            try InputSimulation.deliverHeldKey(chord, hold: 0.2, validate: {},
                post: { events.append($0); token.cancel() }, release: { events.append($0) },
                pause: { _ in XCTFail("Cancelled input must not enter its hold") })
        }) { error in
            XCTAssertEqual((error as? RequestCancellation.Cancelled)?.deliveryState, .outcomeUnknown)
        }
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       Array(repeating: Int64(chord.modifiers[0].keyCode), count: 2))
        XCTAssertFalse(events.last?.flags.contains(.maskShift) ?? true)
    }

    func testDeadlineDuringSecondKeyValidationBalancesThePressedModifier() throws {
        let chord = try KeyPressParser.parse("shift+Down", layout: { _ in nil })
        var events: [CGEvent] = []
        var remaining: TimeInterval = 1
        let delivery = NativeInputDelivery(remaining: { remaining })
        XCTAssertThrowsError(try InputSimulation.deliverHeldKey(chord, hold: 0,
            validate: { if !events.isEmpty { remaining = 0 } },
            post: { events.append($0) }, release: { events.append($0) }, delivery: delivery)) { error in
            XCTAssertEqual(ToolCallResult.delivery(of: error), .outcomeUnknown)
        }
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(chord.modifiers[0].keyCode) })
    }

    func testDeadlineDuringHoldReleasesAllKeysInReverseOrder() throws {
        let chord = try KeyPressParser.parse("control+shift+Down", layout: { _ in nil })
        var events: [CGEvent] = []
        var remaining: TimeInterval = 1
        let delivery = NativeInputDelivery(remaining: { remaining })
        XCTAssertThrowsError(try InputSimulation.deliverHeldKey(chord, hold: 0.2, validate: {},
            post: { events.append($0) }, release: { events.append($0) }, delivery: delivery,
            pause: { _ in remaining = 0 })) { error in
            XCTAssertEqual(ToolCallResult.delivery(of: error), .outcomeUnknown)
        }
        let codes = chord.modifiers.map(\.keyCode) + [chord.keyCode]
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       (codes + Array(codes.reversed())).map(Int64.init))
        XCTAssertEqual(events.map(\.type), Array(repeating: CGEventType.flagsChanged, count: chord.modifiers.count)
            + [.keyDown, .keyUp] + Array(repeating: .flagsChanged, count: chord.modifiers.count))
        XCTAssertEqual(events.last?.flags, [])
    }

    func testFailedKeyPostDoesNotReleaseAnUnpressedMainKey() throws {
        let chord = try KeyPressParser.parse("shift+Down", layout: { _ in nil })
        var events: [CGEvent] = []
        XCTAssertThrowsError(try InputSimulation.deliverHeldKey(chord, hold: 0, validate: {}, post: { event in
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(chord.keyCode) {
                throw ComputerUseError.notSent("Main key was not posted.")
            }
            events.append(event)
        }, release: { events.append($0) })) { error in
            XCTAssertEqual(ToolCallResult.delivery(of: error), .outcomeUnknown)
        }
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(chord.modifiers[0].keyCode) })
    }

    func testCommandChordKeepsTheSameRouteThroughItsFinalModifierRelease() throws {
        for specification in ["command+shift+Down", "shift+command+Down", "shift+Down"] {
            let chord = try KeyPressParser.parse(specification, layout: { _ in nil })
            let authentication = keyChordUsesAuthentication(chord, authenticated: true)
            var events: [CGEvent] = []
            try InputSimulation.deliverHeldKey(chord, hold: 0, validate: {},
                post: { events.append($0) }, release: { events.append($0) })
            XCTAssertEqual(events.last?.flags, [])
            let expected = !specification.contains("command")
            XCTAssertTrue(events.allSatisfy {
                keyEventUsesAuthentication(flags: $0.flags, authenticated: authentication) == expected
            }, specification)
            XCTAssertFalse(keyChordUsesAuthentication(chord, authenticated: false))
        }
    }

    func testProductionReleaseGuardRejectsModifierDownAndUnknownFlagChanges() throws {
        let modifiers: [(Int, CGEventFlags)] = [
            (kVK_Command, .maskCommand), (kVK_RightCommand, .maskCommand),
            (kVK_Shift, .maskShift), (kVK_RightShift, .maskShift),
            (kVK_Option, .maskAlternate), (kVK_RightOption, .maskAlternate),
            (kVK_Control, .maskControl), (kVK_RightControl, .maskControl),
            (kVK_CapsLock, .maskAlphaShift),
        ]
        for (code, flag) in modifiers {
            let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
            let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false))
            let otherFlag: CGEventFlags = flag == .maskShift ? .maskControl : .maskShift
            down.flags = otherFlag.union(flag)
            up.flags = otherFlag
            XCTAssertEqual(down.type, .flagsChanged)
            XCTAssertEqual(up.type, .flagsChanged)
            XCTAssertFalse(keyEventIsRelease(down), "modifier-down \(code)")
            XCTAssertTrue(keyEventIsRelease(up), "modifier-up \(code)")
        }
        let ordinary = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: false))
        XCTAssertTrue(keyEventIsRelease(ordinary))
        ordinary.type = .flagsChanged
        ordinary.flags = []
        XCTAssertFalse(keyEventIsRelease(ordinary), "An arbitrary flagsChanged event is not cleanup")
        ordinary.type = .keyDown
        XCTAssertFalse(keyEventIsRelease(ordinary))
    }

    func testPreparedChordAndCapsLockReleasesPassTheProductionGuard() throws {
        for specification in ["control+option+shift+command+Down", "caps_lock"] {
            let chord = try KeyPressParser.parse(specification, layout: { _ in nil })
            var releases: [CGEvent] = []
            try InputSimulation.deliverHeldKey(chord, hold: 0, validate: {}, post: { _ in },
                release: { releases.append($0) })
            XCTAssertEqual(releases.count, chord.modifiers.count + 1)
            XCTAssertTrue(releases.allSatisfy(keyEventIsRelease), specification)
        }
    }

    func testDefiniteMenuRefusalDoesNotClaimFirstInputWasSent() {
        for result in [AXError.actionUnsupported, .invalidUIElement, .apiDisabled] {
            let delivery = NativeInputDelivery()
            XCTAssertThrowsError(try SkyKeyboardDispatcher.recordMenuPressResult(result, key: "command+s",
                delivery: delivery)) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .notSent)
            }
            XCTAssertEqual(delivery.state, .notSent)
        }
    }

    func testDefiniteMenuRefusalPreservesEarlierInputDelivery() {
        for result in [AXError.actionUnsupported, .invalidUIElement, .apiDisabled] {
            let delivery = NativeInputDelivery()
            delivery.didPost()
            XCTAssertThrowsError(try SkyKeyboardDispatcher.recordMenuPressResult(result, key: "command+s",
                delivery: delivery)) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .outcomeUnknown)
            }
            XCTAssertEqual(delivery.state, .outcomeUnknown)
        }
    }

    func testSuccessfulAndUnconfirmedMenuPressesCountAsDeliveredInput() throws {
        let success = NativeInputDelivery()
        try SkyKeyboardDispatcher.recordMenuPressResult(.success, key: "command+s", delivery: success)
        XCTAssertEqual(success.state, .outcomeUnknown)
        for result in [AXError.cannotComplete, .failure, .attributeUnsupported, .noValue] {
            let delivery = NativeInputDelivery()
            XCTAssertThrowsError(try SkyKeyboardDispatcher.recordMenuPressResult(result, key: "command+s",
                delivery: delivery)) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .outcomeUnknown)
            }
            XCTAssertEqual(delivery.state, .outcomeUnknown)
        }
    }

    func testPreparedClickReleasesAfterCancellationAndSendsNoFollowingClick() throws {
        let prepared = try preparedClick(count: 2)
        let token = RequestCancellation()
        var events: [CGEventType] = []
        XCTAssertThrowsError(try RequestCancellation.$current.withValue(token) {
            try SkyClickDispatcher.deliverPreparedEvents(prepared, validate: {}, post: { event in
                events.append(event.type)
                if event.type == .leftMouseDown { token.cancel() }
            }, release: { events.append($0.type) }, pause: { _ in })
        }) { error in
            XCTAssertEqual((error as? RequestCancellation.Cancelled)?.deliveryState, .outcomeUnknown)
        }
        XCTAssertEqual(events, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    func testPreparedClickStopsWhenValidationUsesTheLastOfItsBudget() throws {
        let prepared = try preparedClick(count: 2)
        var events: [CGEventType] = []
        var remaining: TimeInterval = 1
        let delivery = NativeInputDelivery(remaining: { remaining })
        XCTAssertThrowsError(try SkyClickDispatcher.deliverPreparedEvents(prepared, delivery: delivery,
            validate: { if events.count == 3 { remaining = 0 } },
            post: { events.append($0.type) }, release: { events.append($0.type) }, pause: { _ in })) { error in
            XCTAssertEqual(ToolCallResult.delivery(of: error), .outcomeUnknown)
        }
        XCTAssertEqual(events, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    func testPreparedClickReleaseSurvivesSessionRevocationDuringItsPress() throws {
        let prepared = try preparedClick(count: 1)
        var revoked = false
        var events: [CGEventType] = []
        XCTAssertThrowsError(try SkyClickDispatcher.deliverPreparedEvents(prepared, validate: {
            if revoked { throw ComputerUseError.stateUnavailable("Session ended") }
        }, post: { event in
            events.append(event.type)
            if event.type == .leftMouseDown { revoked = true }
        }, release: { events.append($0.type) }, pause: { _ in }))
        XCTAssertEqual(events, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    func testPreparedClickDoesNotReleaseWhenNoPressWasSent() throws {
        let prepared = try preparedClick(count: 1)
        XCTAssertThrowsError(try SkyClickDispatcher.deliverPreparedEvents(prepared,
            validate: { throw ComputerUseError.notSent("Window changed") },
            post: { _ in XCTFail("Unexpected post") }, release: { _ in XCTFail("Unowned release") },
            pause: { _ in XCTFail("Unexpected pause") }))
    }

    func testPreparedClickKeepsItsOriginalRecipeOnSuccess() throws {
        let prepared = try preparedClick(count: 2)
        var events: [CGEventType] = []
        try SkyClickDispatcher.deliverPreparedEvents(prepared, validate: {},
            post: { events.append($0.type) }, release: { events.append($0.type) }, pause: { _ in })
        XCTAssertEqual(events, prepared.map { $0.step.kind.cgEventType })
    }

    func testLaterClickValidationCannotDowngradeEarlierInputToNotSent() throws {
        let failures: [Error] = [
            RequestCancellation.Cancelled(deliveryState: .notSent),
            ComputerUseError.timedOut("Later validation expired", delivery: .notSent),
            ComputerUseError.notSent("Later validation refused"),
        ]
        for failure in failures {
            let prepared = try preparedClick(count: 1)
            var events: [CGEventType] = []
            XCTAssertThrowsError(try SkyClickDispatcher.deliverPreparedEvents(prepared, validate: {
                if events.count == 3 { throw failure }
            }, post: { events.append($0.type) }, release: { events.append($0.type) }, pause: { _ in })) { error in
                XCTAssertEqual(ToolCallResult.delivery(of: error), .outcomeUnknown)
            }
            XCTAssertEqual(events, [.mouseMoved, .leftMouseDown, .leftMouseUp])
        }
    }

    private func preparedClick(count: Int) throws -> [(step: SkyClickEventStep, event: CGEvent)] {
        try skyClickEventRecipe(clickCount: count).map { step in
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: step.kind.cgEventType,
                                               mouseCursorPosition: .zero, mouseButton: .left))
            return (step, event)
        }
    }
}
