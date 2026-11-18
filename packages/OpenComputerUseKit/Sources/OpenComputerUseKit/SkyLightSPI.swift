import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct SkyLightActivationCommand: Equatable {
    let psn: [UInt8]
    let windowID: CGWindowID
    let focused: Bool
}

struct SkyLightSyntheticFocusContext {
    let deactivateTarget: SkyLightActivationCommand
}

struct SkyLightSyntheticFocusPlan: Equatable {
    let activateTarget: SkyLightActivationCommand
    let deactivateTarget: SkyLightActivationCommand
}

func skyLightSyntheticTargetFocusPlan(
    targetPSN: [UInt8],
    targetWindowID: CGWindowID
) -> SkyLightSyntheticFocusPlan {
    SkyLightSyntheticFocusPlan(
        activateTarget: SkyLightActivationCommand(
            psn: targetPSN,
            windowID: targetWindowID,
            focused: true
        ),
        deactivateTarget: SkyLightActivationCommand(
            psn: targetPSN,
            windowID: targetWindowID,
            focused: false
        )
    )
}

func skyLightActivationRecord(windowID: CGWindowID, focused: Bool) -> [UInt8] {
    var record = [UInt8](repeating: 0, count: 0xF8)
    record[0x04] = 0xF8
    record[0x08] = 0x0D
    record[0x3C] = UInt8(truncatingIfNeeded: windowID)
    record[0x3D] = UInt8(truncatingIfNeeded: windowID >> 8)
    record[0x3E] = UInt8(truncatingIfNeeded: windowID >> 16)
    record[0x3F] = UInt8(truncatingIfNeeded: windowID >> 24)
    record[0x8A] = focused ? 0x01 : 0x02
    return record
}

/// yabai's `window_manager_make_key_window` record pair. Posted to the target
/// PSN after the app-activation record, it makes AppKit inside the target treat
/// `windowID` as its key window without a front-process switch or raise. This
/// is what Chromium's page focus keys off (`OnWindowIsKeyChanged`), so it is
/// the difference between key events being received and text being inserted.
func skyLightKeyWindowRecords(windowID: CGWindowID) -> [[UInt8]] {
    var record = [UInt8](repeating: 0, count: 0xF8)
    record[0x04] = 0xF8
    record[0x3A] = 0x10
    record[0x3C] = UInt8(truncatingIfNeeded: windowID)
    record[0x3D] = UInt8(truncatingIfNeeded: windowID >> 8)
    record[0x3E] = UInt8(truncatingIfNeeded: windowID >> 16)
    record[0x3F] = UInt8(truncatingIfNeeded: windowID >> 24)
    for index in 0x20..<0x30 {
        record[index] = 0xFF
    }
    return [UInt8(0x01), UInt8(0x02)].map { eventKind in
        var copy = record
        copy[0x08] = eventKind
        return copy
    }
}

/// Whether a keyboard event is posted with the SkyLight authentication envelope.
/// macOS 14+ WindowServer gates keyboard delivery to Chromium/Electron on it.
/// Command chords stay without it: Cua's no-auth variant takes the IOHID path
/// that lets NSMenu key equivalents fire.
func keyEventUsesAuthentication(flags: CGEventFlags, authenticated: Bool) -> Bool {
    authenticated && !flags.contains(.maskCommand)
}

/// Probes the CGEvent's embedded SLSEventRecord pointer at the offsets Cua uses
/// (24, 32, 16; `{CFRuntimeBase, uint32, SLSEventRecord *}`). `read` returns the
/// pointer at a byte offset. First non-nil wins.
func skyLightEventRecordPointer(read: (Int) -> UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    for offset in [24, 32, 16] {
        if let pointer = read(offset) { return pointer }
    }
    return nil
}

struct SkyLightSPICapability: Equatable, Sendable {
    let missingSymbols: [String]
    var feature: String = "click"

    var isAvailable: Bool {
        missingSymbols.isEmpty
    }

    var unavailableReason: String {
        if missingSymbols.isEmpty {
            return "available"
        }

        return "missing private \(feature) symbols: \(missingSymbols.joined(separator: ", "))"
    }
}

protocol WindowOcclusionControlling: AnyObject {
    var occlusionCapability: SkyLightSPICapability { get }

    @discardableResult
    func setWindowOcclusionNotificationsEnabled(_ enabled: Bool, windowID: CGWindowID) throws -> Bool
}

/// Runtime-only bridge for the private SkyLight functions used by `sky_click`,
/// `sky_key`, and window-addressed background drag.
///
/// The declarations, event-field recipe and key-window records are derived
/// from the MIT-licensed Cua Driver and yabai implementations. Keep all
/// undocumented ABI in this file so a future macOS compatibility change has
/// one review boundary.
final class SkyLightSPI: WindowOcclusionControlling, @unchecked Sendable {
    static let shared = SkyLightSPI()

    private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let postToPidSymbol = "SLEventPostToPid"
    private static let setIntegerFieldSymbol = "SLEventSetIntegerValueField"
    private static let setWindowLocationSymbol = "CGEventSetWindowLocation"
    private static let postEventRecordSymbol = "SLPSPostEventRecordTo"
    private static let getProcessForPIDSymbol = "GetProcessForPID"
    private static let mainConnectionSymbol = "SLSMainConnectionID"
    private static let enableWindowOcclusionNotificationsSymbol = "SLSPackagesEnableWindowOcclusionNotifications"
    // Read-only observation symbols used to replace fixed sleeps with polls.
    private static let copySpacesForWindowsSymbol = "SLSCopySpacesForWindows"
    private static let copyManagedDisplaySpacesSymbol = "SLSCopyManagedDisplaySpaces"
    private static let axElementGetWindowSymbol = "_AXUIElementGetWindow"
    // WindowServer reads the window's backing store on the GPU: works for
    // covered windows and for windows on inactive (fullscreen) Spaces where
    // ScreenCaptureKit fails, in ~10-40ms. The wrapper is the 4-argument form
    // (cid, windowIDs, count, options); 0x800 ignores the global clip shape.
    private static let hardwareCaptureWindowListSymbol = "SLSHWCaptureWindowList"
    private static let hardwareCaptureOptions: UInt32 = 0x800
    // Keyboard authentication envelope (macOS 14+; the factory selector exists on macOS 15+).
    private static let setAuthenticationMessageSymbol = "SLEventSetAuthenticationMessage"
    private static let authenticationClassName = "SLSEventAuthenticationMessage"
    private static let authenticationSelectorName = "messageWithEventRecord:pid:version:"
    private static let applicationServicesPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"

    private typealias PostToPidFunction = @convention(c) (pid_t, UnsafeMutableRawPointer?) -> Void
    private typealias SetIntegerFieldFunction = @convention(c) (UnsafeMutableRawPointer?, UInt32, Int64) -> Void
    // Cua's current Rust bridge models this private ABI as
    // (CGEventRef, double x, double y). Keeping the scalar form here avoids
    // relying on Swift's aggregate CGPoint calling convention.
    private typealias SetWindowLocationFunction = @convention(c) (UnsafeMutableRawPointer?, Double, Double) -> Void
    private typealias PostEventRecordFunction = @convention(c) (UnsafeRawPointer?, UnsafePointer<UInt8>?) -> Int32
    private typealias GetProcessForPIDFunction = @convention(c) (pid_t, UnsafeMutableRawPointer?) -> Int32
    private typealias MainConnectionFunction = @convention(c) () -> UInt32
    // (cid, wid, enable, previousStateOut) — the out pointer is optional; the
    // ABI was read from the function prologue on macOS 27 (strb w21 / cbz x19).
    private typealias EnableWindowOcclusionNotificationsFunction = @convention(c) (UInt32, CGWindowID, UInt8, UnsafeMutablePointer<UInt8>?) -> Int32
    private typealias CopySpacesForWindowsFunction = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFunction = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias AXElementGetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias HardwareCaptureWindowListFunction = @convention(c) (UInt32, UnsafePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?

    private typealias SetAuthenticationMessageFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias ObjCGetClassFunction = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias ObjCRegisterSelectorFunction = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias ObjCClassRespondsFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool
    private typealias AuthenticationFactoryFunction = @convention(c) (
        UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer, Int32, UInt32
    ) -> UnsafeMutableRawPointer?

    private struct AuthenticationFactory {
        let cls: UnsafeMutableRawPointer
        let selector: UnsafeMutableRawPointer
        let send: AuthenticationFactoryFunction
        let setMessage: SetAuthenticationMessageFunction
    }

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let applicationServicesHandle: UnsafeMutableRawPointer?
    private let postToPidFunction: PostToPidFunction?
    private let setIntegerFieldFunction: SetIntegerFieldFunction?
    private let setWindowLocationFunction: SetWindowLocationFunction?
    private let postEventRecordFunction: PostEventRecordFunction?
    private let getProcessForPIDFunction: GetProcessForPIDFunction?
    private let mainConnectionFunction: MainConnectionFunction?
    private let enableWindowOcclusionNotificationsFunction: EnableWindowOcclusionNotificationsFunction?
    private let copySpacesForWindowsFunction: CopySpacesForWindowsFunction?
    private let copyManagedDisplaySpacesFunction: CopyManagedDisplaySpacesFunction?
    private let axElementGetWindowFunction: AXElementGetWindowFunction?
    private let hardwareCaptureWindowListFunction: HardwareCaptureWindowListFunction?

    private let authenticationFactory: AuthenticationFactory?
    /// True when keyboard events can carry the authentication envelope. False on
    /// macOS 14 (selector missing) or if any symbol is absent; keys then post plain.
    var keyAuthenticationAvailable: Bool { authenticationFactory != nil }

    let capability: SkyLightSPICapability
    /// Window addressing is required for every app_post drag. Synthetic focus
    /// is only needed when the target app is in the background.
    let dragWindowLocationCapability: SkyLightSPICapability
    let dragFocusCapability: SkyLightSPICapability
    /// Occlusion keep-alive (`WindowOcclusionKeepAlive`) is a separate optional
    /// capability so a missing symbol never disables `sky_click` / `sky_key`.
    let occlusionCapability: SkyLightSPICapability

    private init() {
        let handle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_GLOBAL)
        let appServicesHandle = dlopen(Self.applicationServicesPath, RTLD_LAZY | RTLD_GLOBAL)
        frameworkHandle = handle
        applicationServicesHandle = appServicesHandle
        postToPidFunction = Self.resolve(handle: handle, symbol: Self.postToPidSymbol)
        setIntegerFieldFunction = Self.resolve(handle: handle, symbol: Self.setIntegerFieldSymbol)
        setWindowLocationFunction = Self.resolve(handle: handle, symbol: Self.setWindowLocationSymbol)
        postEventRecordFunction = Self.resolve(handle: handle, symbol: Self.postEventRecordSymbol)
        getProcessForPIDFunction = Self.resolve(handle: appServicesHandle, symbol: Self.getProcessForPIDSymbol)
        mainConnectionFunction = Self.resolve(handle: handle, symbol: Self.mainConnectionSymbol)
        enableWindowOcclusionNotificationsFunction = Self.resolve(handle: handle, symbol: Self.enableWindowOcclusionNotificationsSymbol)
        copySpacesForWindowsFunction = Self.resolve(handle: handle, symbol: Self.copySpacesForWindowsSymbol)
        copyManagedDisplaySpacesFunction = Self.resolve(handle: handle, symbol: Self.copyManagedDisplaySpacesSymbol)
        axElementGetWindowFunction = Self.resolve(handle: appServicesHandle, symbol: Self.axElementGetWindowSymbol)
        hardwareCaptureWindowListFunction = Self.resolve(handle: handle, symbol: Self.hardwareCaptureWindowListSymbol)

        authenticationFactory = Self.resolveAuthenticationFactory(skyLight: handle)

        var missingSymbols: [String] = []
        if postToPidFunction == nil {
            missingSymbols.append(Self.postToPidSymbol)
        }
        if setIntegerFieldFunction == nil {
            missingSymbols.append(Self.setIntegerFieldSymbol)
        }
        if setWindowLocationFunction == nil {
            missingSymbols.append(Self.setWindowLocationSymbol)
        }
        if postEventRecordFunction == nil {
            missingSymbols.append(Self.postEventRecordSymbol)
        }
        if getProcessForPIDFunction == nil {
            missingSymbols.append(Self.getProcessForPIDSymbol)
        }
        capability = SkyLightSPICapability(missingSymbols: missingSymbols)
        dragWindowLocationCapability = SkyLightSPICapability(
            missingSymbols: missingSymbols.filter { $0 == Self.setWindowLocationSymbol },
            feature: "drag window location"
        )
        dragFocusCapability = SkyLightSPICapability(
            missingSymbols: missingSymbols.filter {
                $0 == Self.postEventRecordSymbol || $0 == Self.getProcessForPIDSymbol
            },
            feature: "background drag synthetic focus"
        )

        var missingOcclusionSymbols: [String] = []
        if mainConnectionFunction == nil {
            missingOcclusionSymbols.append(Self.mainConnectionSymbol)
        }
        if enableWindowOcclusionNotificationsFunction == nil {
            missingOcclusionSymbols.append(Self.enableWindowOcclusionNotificationsSymbol)
        }
        occlusionCapability = SkyLightSPICapability(missingSymbols: missingOcclusionSymbols, feature: "occlusion")
    }

    // MARK: - Observation (read-only; nil when the symbol is absent)

    /// Space ids the window currently belongs to.
    func spaces(forWindow windowID: CGWindowID) -> [UInt64]? {
        guard let mainConnectionFunction, let copySpacesForWindowsFunction else { return nil }
        let result = copySpacesForWindowsFunction(mainConnectionFunction(), 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue()
        return (result as? [NSNumber])?.map(\.uint64Value)
    }

    /// User (type 0) Space ids per display, keyed by display identifier.
    func managedDisplaySpaces() -> [String: [UInt64]]? {
        guard let mainConnectionFunction, let copyManagedDisplaySpacesFunction else { return nil }
        guard let displays = copyManagedDisplaySpacesFunction(mainConnectionFunction())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var result: [String: [UInt64]] = [:]
        for display in displays {
            let identifier = display["Display Identifier"] as? String ?? UUID().uuidString
            result[identifier] = ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap { space in
                guard (space["type"] as? NSNumber)?.intValue == 0 else { return nil }
                return (space["id64"] as? NSNumber)?.uint64Value
            }
        }
        return result
    }

    /// Capture one window's backing store (retina scale). nil when the symbol is
    /// absent or WindowServer returned nothing; callers fall back to SCK.
    func hardwareCaptureWindow(_ windowID: CGWindowID) -> CGImage? {
        guard let mainConnectionFunction, let hardwareCaptureWindowListFunction else { return nil }
        var id = windowID
        guard let array = hardwareCaptureWindowListFunction(mainConnectionFunction(), &id, 1, Self.hardwareCaptureOptions)?.takeRetainedValue(),
              CFArrayGetCount(array) > 0
        else { return nil }
        let image = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CGImage.self)
        return image.width > 0 && image.height > 0 ? image : nil
    }

    /// CGWindowID behind an AX window element.
    func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let axElementGetWindowFunction else { return nil }
        var windowID: CGWindowID = 0
        guard axElementGetWindowFunction(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    /// Enable or disable WindowServer occlusion notifications for one window of
    /// another process. Returns the previous state. Disabling pins the target's
    /// AppKit `occlusionState` at its current value.
    @discardableResult
    func setWindowOcclusionNotificationsEnabled(_ enabled: Bool, windowID: CGWindowID) throws -> Bool {
        guard let mainConnectionFunction, let enableWindowOcclusionNotificationsFunction else {
            throw ComputerUseError.message("occlusion keep-alive is unavailable: \(occlusionCapability.unavailableReason)")
        }

        var previous: UInt8 = 0
        let status = enableWindowOcclusionNotificationsFunction(mainConnectionFunction(), windowID, enabled ? 1 : 0, &previous)
        guard status == 0 else {
            throw ComputerUseError.message("SLSPackagesEnableWindowOcclusionNotifications failed (CGError \(status))")
        }
        return previous != 0
    }

    func postToPid(_ event: CGEvent, pid: pid_t) throws {
        try requireUsableComputerUseSession()
        guard let postToPidFunction else {
            throw unavailableError()
        }

        postToPidFunction(pid, opaquePointer(for: event))
    }

    /// Posts a keyboard event with `SLEventPostToPid`. With `authenticated`, attaches an
    /// SLSEventAuthenticationMessage first when the platform supports it (dlsym- and
    /// respondsToSelector-guarded; never crashes when absent). Falls back to the public
    /// `postToPid` when the SkyLight post symbol is missing. Returns true when an
    /// authentication message was attached. Needs a live check on Chromium/Electron.
    @discardableResult
    func postKeyToPid(_ event: CGEvent, pid: pid_t, authenticated: Bool) throws -> Bool {
        try requireUsableComputerUseSession()
        guard let postToPidFunction else {
            event.postToPid(pid)
            return false
        }
        var attached = false
        let eventPointer = opaquePointer(for: event)
        // The factory returns an autoreleased message. Whether SLEventSetAuthenticationMessage retains it is
        // not documented, so the pool stays open until the event is posted: the message can never be freed
        // between attaching it and WindowServer reading it.
        withExtendedLifetime(event) {
            autoreleasepool {
                if authenticated, let factory = authenticationFactory {
                    let record = skyLightEventRecordPointer { offset in
                        (eventPointer + offset).loadUnaligned(as: UnsafeMutableRawPointer?.self)
                    }
                    if let record, let message = factory.send(factory.cls, factory.selector, record, pid, 0) {
                        factory.setMessage(eventPointer, message)
                        attached = true
                    }
                }
                postToPidFunction(pid, eventPointer)
            }
        }
        return attached
    }

    /// Gives key focus back to the user's own window after a synthetic focus on
    /// another app: the same paired make-key records Cua's `return_key_to` posts, to
    /// the user's process. Best effort; no front-process change, never raises.
    /// Needs a live check.
    @discardableResult
    func returnKeyFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPIDFunction, let postEventRecordFunction else { return false }
        var psn = [UInt8](repeating: 0, count: 8)
        let status = psn.withUnsafeMutableBytes { getProcessForPIDFunction(pid, $0.baseAddress) }
        guard status == 0 else { return false }
        for record in skyLightKeyWindowRecords(windowID: windowID) {
            let result = psn.withUnsafeBytes { psnBytes in
                record.withUnsafeBufferPointer { postEventRecordFunction(psnBytes.baseAddress, $0.baseAddress) }
            }
            if result != 0 { return false }
        }
        return true
    }

    private static func resolveAuthenticationFactory(skyLight: UnsafeMutableRawPointer?) -> AuthenticationFactory? {
        guard let setMessage: SetAuthenticationMessageFunction = resolve(handle: skyLight, symbol: setAuthenticationMessageSymbol),
              let getClass: ObjCGetClassFunction = resolve(handle: UnsafeMutableRawPointer(bitPattern: -2), symbol: "objc_getClass"),
              let registerSelector: ObjCRegisterSelectorFunction = resolve(handle: UnsafeMutableRawPointer(bitPattern: -2), symbol: "sel_registerName"),
              let responds: ObjCClassRespondsFunction = resolve(handle: UnsafeMutableRawPointer(bitPattern: -2), symbol: "class_respondsToSelector"),
              let send: AuthenticationFactoryFunction = resolve(handle: UnsafeMutableRawPointer(bitPattern: -2), symbol: "objc_msgSend"),
              let cls = getClass(authenticationClassName),
              let selector = registerSelector(authenticationSelectorName)
        else { return nil }
        // The factory is a class method, so the metaclass is what must respond (macOS 15+; absent on 14).
        guard let getMetaClass: ObjCGetClassFunction = resolve(handle: UnsafeMutableRawPointer(bitPattern: -2), symbol: "objc_getMetaClass"),
              let meta = getMetaClass(authenticationClassName),
              responds(meta, selector)
        else { return nil }
        return AuthenticationFactory(cls: cls, selector: selector, send: send, setMessage: setMessage)
    }

    func setIntegerField(_ event: CGEvent, field: UInt32, value: Int64) throws {
        guard let setIntegerFieldFunction else {
            throw unavailableError()
        }

        setIntegerFieldFunction(opaquePointer(for: event), field, value)
    }

    func setWindowLocation(_ event: CGEvent, point: CGPoint) throws {
        guard let setWindowLocationFunction else {
            throw unavailableError()
        }

        setWindowLocationFunction(opaquePointer(for: event), point.x, point.y)
    }

    func beginSyntheticTargetFocus(
        targetPID: pid_t,
        targetWindowID: CGWindowID
    ) throws -> SkyLightSyntheticFocusContext {
        guard let getProcessForPIDFunction else {
            throw unavailableError()
        }

        var targetPSN = [UInt8](repeating: 0, count: 8)
        let targetStatus = targetPSN.withUnsafeMutableBytes { bytes in
            getProcessForPIDFunction(targetPID, bytes.baseAddress)
        }
        guard targetStatus == 0 else {
            throw ComputerUseError.message(
                "click_method 'sky_click' could not resolve target PID \(targetPID) to a PSN (OSStatus \(targetStatus))"
            )
        }

        let plan = skyLightSyntheticTargetFocusPlan(
            targetPSN: targetPSN,
            targetWindowID: targetWindowID
        )
        try postActivationCommand(plan.activateTarget)
        if InputTiming.focusRecordSettle > 0 {
            Thread.sleep(forTimeInterval: InputTiming.focusRecordSettle)
        }

        return SkyLightSyntheticFocusContext(
            deactivateTarget: plan.deactivateTarget
        )
    }

    /// Make the target window key inside the target app while it is in the
    /// synthetic-active state. Must follow `beginSyntheticTargetFocus`; posted
    /// the other way round the records are ignored. `endSyntheticTargetFocus`
    /// releases the key state again (the target sees resignKey/blur).
    func makeSyntheticTargetWindowKey(_ context: SkyLightSyntheticFocusContext) throws {
        guard let postEventRecordFunction else {
            throw unavailableError()
        }

        let command = context.deactivateTarget
        for record in skyLightKeyWindowRecords(windowID: command.windowID) {
            let status = command.psn.withUnsafeBytes { psnBytes in
                record.withUnsafeBufferPointer { recordBytes in
                    postEventRecordFunction(psnBytes.baseAddress, recordBytes.baseAddress)
                }
            }
            guard status == 0 else {
                throw ComputerUseError.message(
                    "key_method 'sky_key' synthetic key-window event failed (OSStatus \(status))"
                )
            }
        }
    }

    func endSyntheticTargetFocus(_ context: SkyLightSyntheticFocusContext) throws {
        try postActivationCommand(context.deactivateTarget)
        if InputTiming.focusRecordSettle > 0 {
            Thread.sleep(forTimeInterval: InputTiming.focusRecordSettle)
        }
    }

    private func unavailableError() -> ComputerUseError {
        ComputerUseError.message(
            "click_method 'sky_click' is unavailable: \(capability.unavailableReason)"
        )
    }

    private func opaquePointer(for event: CGEvent) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(event).toOpaque()
    }

    private func postActivationCommand(_ command: SkyLightActivationCommand) throws {
        guard let postEventRecordFunction else {
            throw unavailableError()
        }

        let record = skyLightActivationRecord(
            windowID: command.windowID,
            focused: command.focused
        )
        let status = command.psn.withUnsafeBytes { psnBytes in
            record.withUnsafeBufferPointer { recordBytes in
                postEventRecordFunction(psnBytes.baseAddress, recordBytes.baseAddress)
            }
        }
        guard status == 0 else {
            throw ComputerUseError.message(
                "click_method 'sky_click' synthetic target-focus event failed (OSStatus \(status))"
            )
        }
    }

    private static func resolve<T>(handle: UnsafeMutableRawPointer?, symbol: String) -> T? {
        guard let handle, let pointer = dlsym(handle, symbol) else {
            return nil
        }

        return unsafeBitCast(pointer, to: T.self)
    }
}
