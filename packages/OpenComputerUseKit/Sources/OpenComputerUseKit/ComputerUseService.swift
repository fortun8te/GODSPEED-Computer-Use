import AppKit
import ApplicationServices
import Foundation
import ImageIO

struct VisualCursorTarget: Equatable {
    let point: CGPoint
    let window: CursorTargetWindow?
    /// The same point expressed relative to the window frame the snapshot
    /// reported. The overlay keeps it so a window that moves before or during
    /// the action can be re-derived instead of drawing on the display the
    /// window just left.
    var anchor: CursorRestingAnchor? = nil
}

public enum ClickMethod: String, CaseIterable, Sendable {
    case auto
    case accessibility
    case appPost = "app_post"
    case skyClick = "sky_click"
    case global
}

func clickActionSnapshotRecoveryPolicy(for method: ClickMethod) -> SnapshotRecoveryPolicy {
    method == .skyClick ? .readOnly : .allowActivation
}

func parseClickMethod(_ rawValue: String?) throws -> ClickMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ClickMethod.auto.rawValue

    guard let method = ClickMethod(rawValue: normalized) else {
        let expected = ClickMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid click_method '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return method
}

func validateClickMethod(
    _ method: ClickMethod,
    hasElementIndex: Bool,
    environment: [String: String]
) throws {
    if method == .accessibility, !hasElementIndex {
        throw ComputerUseError.message("click_method 'accessibility' requires element_index")
    }

    if method == .global, !globalPointerFallbacksEnabled(environment: environment) {
        throw ComputerUseError.message(
            "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
        )
    }
}

public enum KeyMethod: String, CaseIterable, Sendable {
    case auto
    case skyKey = "sky_key"
}

func keyActionSnapshotRecoveryPolicy(for method: KeyMethod) -> SnapshotRecoveryPolicy {
    method == .skyKey ? .readOnly : .allowActivation
}

func parseKeyMethod(_ rawValue: String?) throws -> KeyMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? KeyMethod.auto.rawValue

    guard let method = KeyMethod(rawValue: normalized) else {
        let expected = KeyMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid key_method '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return method
}

func validateSkyClickArguments(
    method: ClickMethod,
    mouseButton: String,
    clickCount: Int
) throws {
    guard method == .skyClick else {
        return
    }

    guard mouseButton.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == MouseButtonKind.left.rawValue else {
        throw ComputerUseError.message(
            "click_method 'sky_click' only supports mouse_button 'left'"
        )
    }

    guard (1...2).contains(clickCount) else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports click_count 1 or 2"
        )
    }
}

struct VisualCursorScreenMapping: Equatable {
    let screenStateFrame: CGRect
    let appKitFrame: CGRect
}

func currentVisualCursorScreenMappings() -> [VisualCursorScreenMapping] {
    NSScreen.screens.compactMap { screen in
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return VisualCursorScreenMapping(
            screenStateFrame: CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value)),
            appKitFrame: screen.frame
        )
    }
}

func screenStatePointToAppKitGlobalPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    guard point.x.isFinite, point.y.isFinite else { return point }
    func distance(to mapping: VisualCursorScreenMapping) -> CGFloat {
        let frame = mapping.screenStateFrame
        let dx = point.x - point.x.clamped(to: frame.minX...frame.maxX)
        let dy = point.y - point.y.clamped(to: frame.minY...frame.maxY)
        return hypot(dx, dy)
    }
    guard let mapping = screenMappings.first(where: { $0.screenStateFrame.contains(point) })
        ?? screenMappings.min(by: { distance(to: $0) < distance(to: $1) }) else {
        return point
    }

    let localX = (point.x - mapping.screenStateFrame.minX).clamped(to: 0...mapping.screenStateFrame.width)
    let localY = (point.y - mapping.screenStateFrame.minY).clamped(to: 0...mapping.screenStateFrame.height)

    return CGPoint(
        x: mapping.appKitFrame.minX + localX,
        y: mapping.appKitFrame.maxY - localY
    )
}

func visualCursorAppKitPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    screenStatePointToAppKitGlobalPoint(
        fromScreenStatePoint: point,
        screenMappings: screenMappings
    )
}

func inputEventPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    point
}

/// Anchor for a cursor target built from a window-local point.
///
/// The click paths derive their point from the snapshot, so they carry the
/// window frame that point belongs to; the overlay needs both to follow the
/// window if it moves before or during the action.
func makeCursorWindowAnchor(snapshot: AppSnapshot, windowLocalPoint: CGPoint) -> CursorRestingAnchor? {
    guard let windowID = snapshot.targetWindowID, let windowBounds = snapshot.windowBounds else {
        return nil
    }

    // The anchor carries the window's accessibility element; the overlay registers it as the
    // live-frame source when the queued animation runs (the window list can lag a move by
    // about a second, so the element is what makes the re-derivation immediate).
    return CursorRestingAnchor(
        windowID: windowID,
        layer: snapshot.targetWindowLayer ?? 0,
        windowLocalPoint: windowLocalPoint,
        windowBounds: windowBounds,
        frameSource: snapshot.windowElement.map(CursorFrameSource.init)
    )
}

func makeVisualCursorTarget(
    at point: CGPoint,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings(),
    anchor: CursorRestingAnchor? = nil
) -> VisualCursorTarget {
    VisualCursorTarget(
        point: screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: point,
            screenMappings: screenMappings
        ),
        window: targetWindowID.map { CursorTargetWindow(windowID: $0, layer: targetWindowLayer ?? 0) },
        anchor: anchor
    )
}

func makeVisualCursorTarget(
    localFrame: CGRect?,
    windowBounds: CGRect?,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings(),
    windowElement: AXUIElement? = nil
) -> VisualCursorTarget? {
    guard let localFrame, let windowBounds else {
        return nil
    }

    let point = CGPoint(
        x: windowBounds.minX + localFrame.midX,
        y: windowBounds.minY + localFrame.midY
    )
    return makeVisualCursorTarget(
        at: point,
        targetWindowID: targetWindowID,
        targetWindowLayer: targetWindowLayer,
        screenMappings: screenMappings,
        anchor: targetWindowID.map { windowID in
            CursorRestingAnchor(
                windowID: windowID,
                layer: targetWindowLayer ?? 0,
                windowLocalPoint: CGPoint(x: localFrame.midX, y: localFrame.midY),
                windowBounds: windowBounds,
                frameSource: windowElement.map(CursorFrameSource.init)
            )
        }
    )
}

func inputFallbackDebugEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

func globalPointerFallbacksEnabled(environment: [String: String]) -> Bool {
    // The physical pointer path activates the target app and moves the real mouse.
    guard !backgroundOnlyMode(environment: environment), !StrictBackground.enabled() else { return false }
    guard let rawValue = environment["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

/// Raises the app for a global pointer step. The hands-off check runs first: a step the user's activity
/// refuses must not bring the app forward.
func raiseForGlobalPointerInput(_ app: RunningAppDescriptor, prepare: (RunningAppDescriptor) -> Void = InputSimulation.prepareAppForGlobalPointerInput) throws {
    try requireUserHandsOff()
    prepare(app)
}

/// Whether an action's result reads the window back (settle, then a full snapshot).
/// A program driving the tools (the `js` REPL adapter) reads state explicitly and
/// sets `OPEN_COMPUTER_USE_ACTION_READ_BACK=0`, so its actions return a short status.
func actionReadBackEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_ACTION_READ_BACK"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return true
    }

    return !["0", "false", "no", "off"].contains(rawValue)
}

/// How a `drag` is delivered. `drag` has no method argument; the path is decided
/// by the same process-level gate that authorizes `click_method=global`.
enum DragDeliveryPath: String, CaseIterable {
    /// Window-addressed `CGEvent.postToPid` with target-only synthetic focus.
    /// Never moves the real pointer; window-server-managed drag/drop is not guaranteed.
    case appPost = "app_post"
    /// `.cghidEventTap`: drives window-server drag sessions and may move the
    /// real pointer or change foreground focus.
    case global
}

/// Modifier flags travel with the mouse events, so they never press a global key.
func dragModifierFlags(_ modifiers: [String]) throws -> CGEventFlags {
    var flags: CGEventFlags = []
    for modifier in modifiers {
        switch modifier.lowercased() {
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "command", "cmd": flags.insert(.maskCommand)
        case "control", "ctrl": flags.insert(.maskControl)
        default: throw ComputerUseError.invalidArguments("drag modifiers must be shift, option, command, or control")
        }
    }
    return flags
}

func dragDeliveryPath(environment: [String: String]) -> DragDeliveryPath {
    globalPointerFallbacksEnabled(environment: environment) ? .global : .appPost
}

func dragActionSnapshotRecoveryPolicy(for path: DragDeliveryPath) -> SnapshotRecoveryPolicy {
    path == .appPost ? .readOnly : .allowActivation
}

func dragDeliveryNote(for path: DragDeliveryPath) -> String {
    switch path {
    case .appPost:
        return "Drag delivered via app_post: window-addressed mouse events were posted once to the target process with target-only synthetic focus when needed; the system pointer was not moved. Delivery is not verification of the target UI result. Window-server-managed gestures such as window moves or Finder drag-and-drop are not guaranteed. Global input is never a fallback; it requires explicit OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 and may move the real pointer or change foreground focus."
    case .global:
        return "Drag delivered via global pointer path: OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS is enabled, so the real pointer may have moved and foreground focus may have changed."
    }
}

/// Inserts the delivery note after the snapshot text and before any screenshot,
/// so `primaryText` remains the snapshot for existing consumers.
func appendingDragDeliveryNote(to result: ToolCallResult, path: DragDeliveryPath) -> ToolCallResult {
    var content = result.content
    let insertIndex = content.firstIndex { $0.dictionary["type"] as? String == "image" } ?? content.endIndex
    content.insert(.text(dragDeliveryNote(for: path)), at: insertIndex)
    return ToolCallResult(content: content, isError: result.isError)
}

func selectTextErrorMessage(_ error: TextSelectionResolverError, elementIndex: String) -> String {
    switch error {
    case .emptyText:
        return "select_text requires non-empty text"
    case .notFound:
        return "select_text could not find the requested text in element \(elementIndex); pass text exactly as it appears in the accessibility tree"
    case .ambiguous(let occurrenceCount):
        return "select_text found \(occurrenceCount) matches in element \(elementIndex); provide prefix or suffix to disambiguate the target"
    }
}

func selectTextUnreadableValueErrorMessage(elementIndex: String) -> String {
    return "element \(elementIndex) has no readable accessibility text value, so select_text cannot locate the requested text"
}

/// The keyboard fallback of `type_text` sent keys, but the field's text is the same as before.
/// A secure field and an unreadable value prove nothing, so they never count as unchanged.
func typedTextWasNotApplied(before: String?, after: String?, text: String, isSecureField: Bool) -> Bool {
    guard !isSecureField, !text.isEmpty, let before, let after else {
        return false
    }
    return before == after
}

let typedTextNotAppliedMessage = "type_text sent the keys, but the field's text did not change, so nothing was typed. The window may not have taken keyboard input. Read the app state before typing again: a repeat could type twice if the first keys arrive late."

/// `scroll` asked the app for `requested` pages through AXScrollByPage and it accepted only `done`.
func scrollPagesRefusedMessage(done: Int, requested: Int, error: AXError) -> String {
    "scroll moved \(done) of \(requested) pages, then the app refused the next page (AXError \(error.rawValue)). Read the app state before scrolling again."
}

/// Appended to set_value's refusal: what to do instead for a field that cannot take a value.
let setValueFallbackHint = ". Click the field and use type_text to enter the text, or press_menu for a command the app offers"

/// The focused element could not be read. Save, open and print panels can run in their own process,
/// whose focus is out of reach from here.
let focusedElementUnreadableMessage = "type_text could not read the app's current focused element. Focus a text entry area and try again. If a save, open or print panel is showing, its focus may be out of reach: use the app's menu path (press_menu) or the app's own command line or URL instead."

/// The reply with a note placed after the state text and before any screenshot, as the other notes are.
func insertingNote(_ note: String, into result: ToolCallResult) -> ToolCallResult {
    var content = result.content
    content.insert(.text(note), at: content.firstIndex { $0.dictionary["type"] as? String == "image" } ?? content.endIndex)
    return ToolCallResult(content: content, isError: result.isError)
}

/// Inserts a verification note after the snapshot text and before any screenshot, matching
/// `appendingDragDeliveryNote` so `primaryText` stays the snapshot for existing consumers.
func screenshotPixelScale(
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGSize {
    guard
        let screenshotPixelSize,
        let windowBounds,
        windowBounds.width > 0,
        windowBounds.height > 0,
        screenshotPixelSize.width > 0,
        screenshotPixelSize.height > 0
    else {
        return CGSize(width: 1, height: 1)
    }

    return CGSize(
        width: screenshotPixelSize.width / windowBounds.width,
        height: screenshotPixelSize.height / windowBounds.height
    )
}

func screenshotPixelToWindowPoint(
    _ point: CGPoint,
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGPoint {
    let scale = screenshotPixelScale(
        screenshotPixelSize: screenshotPixelSize,
        windowBounds: windowBounds
    )
    return CGPoint(
        x: point.x / scale.width,
        y: point.y / scale.height
    )
}

/// Renaming a file selects its name without the extension. True when `text` is the full new name, ending in that same
/// extension, typed over such a selection: the whole old name must be replaced, or the result is "name.txt.txt".
func typedNameReplacesWholeValue(value: String, selection: CFRange, text: String) -> Bool {
    let value = value as NSString
    guard selection.location == 0, selection.length > 0, selection.length < value.length else { return false }
    let rest = value.substring(from: selection.length)
    guard rest.hasPrefix("."), rest.count <= 8, !rest.dropFirst().contains("."), !rest.contains(" ") else { return false }
    return text.count > rest.count && text.lowercased().hasSuffix(rest.lowercased())
}

/// The whole-name rule runs only in Finder's own rename editor: a text field in Finder, outside any sheet or dialog.
/// Elsewhere the same selection and typed text is ordinary editing (a word selected at the start of a document, then
/// "Quarterly.pdf" typed over it), and ⌘A would replace the whole document.
func isFinderRenameEditor(bundleIdentifier: String?, role: String?, insideSheetOrDialog: Bool) -> Bool {
    bundleIdentifier == "com.apple.finder" && role == "AXTextField" && !insideSheetOrDialog
}

/// AX ranges use UTF-16. Reject unavailable, out-of-bounds or split-surrogate ranges.
func typedTextReplacement(value: String, selection: CFRange, text: String) -> (value: String, caret: Int)? {
    let units = Array(value.utf16)
    guard selection.location >= 0, selection.location <= units.count,
          selection.length >= 0, selection.length <= units.count - selection.location
    else { return nil }
    let end = selection.location + selection.length
    func splitsSurrogate(_ offset: Int) -> Bool {
        offset > 0 && offset < units.count
            && (0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset])
    }
    guard !splitsSurrogate(selection.location), !splitsSurrogate(end) else { return nil }
    let range = NSRange(location: selection.location, length: selection.length)
    return ((value as NSString).replacingCharacters(in: range, with: text), selection.location + text.utf16.count)
}

let nonSettableSetValueErrorMessage = "Cannot set a value for an element that is not settable"

func setValueAttributeIsSettable(result: AXError, settable: Bool, attribute: String) throws -> Bool {
    guard result == .success else {
        throw ComputerUseError.message("AXUIElementIsAttributeSettable(\(attribute)) failed with \(result.rawValue)")
    }

    return settable
}

func invalidSecondaryActionErrorMessage(action: String, elementIndex: Int) -> String {
    "\(action) is not a valid secondary action for \(elementIndex)"
}

func localClickActionPoints(frame: CGRect, isSyntheticText: Bool) -> [CGPoint] {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let leading = CGPoint(
        x: frame.minX + min(max(frame.width * 0.3, 20), max(frame.width - 4, 20)),
        y: frame.midY
    )

    if isSyntheticText {
        return [leading]
    }

    if abs(leading.x - center.x) < 1 {
        return [center]
    }

    return [center, leading]
}

func isLikelySyntheticSideActionCandidate(
    parentFrame: CGRect?,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool,
    labels: [String]
) -> Bool {
    let hasSideActionLabel = labels.contains { label in
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        if normalized == "完成" || normalized == "done" || normalized == "complete" || normalized == "archive" {
            return true
        }

        if normalized.count <= 24 {
            if normalized.contains("完成") {
                return true
            }

            if normalized.contains("mark") && (normalized.contains("done") || normalized.contains("complete")) {
                return true
            }
        }

        return false
    }

    guard let parentFrame, let candidateFrame else {
        return false
    }

    let trailingBandWidth = min(max(parentFrame.width * 0.22, 56), 140)
    let isTrailing = candidateFrame.midX >= parentFrame.maxX - trailingBandWidth
    let compactWidth = candidateFrame.width <= max(88, parentFrame.width * 0.18)
    let compactHeight = candidateFrame.height <= max(44, parentFrame.height * 1.2)
    let isCompact = compactWidth && compactHeight

    if hasSideActionLabel && hasPrimaryAction && isCompact {
        return true
    }

    return isTrailing && isCompact && (hasPrimaryAction || hasSideActionLabel)
}

func shouldScanDescendantsOfHitRecord(originalFrame: CGRect?, hitFrame: CGRect?) -> Bool {
    guard let originalFrame, let hitFrame else {
        return true
    }

    let originalArea = max(originalFrame.width * originalFrame.height, 1)
    let hitArea = hitFrame.width * hitFrame.height
    if hitArea > max(originalArea * 12, 20_000) {
        return false
    }

    if hitFrame.height > max(originalFrame.height * 4, 96),
       hitFrame.width > max(originalFrame.width * 2, 240)
    {
        return false
    }

    return true
}

/// A descendant found by scanning below a click target may be pressed only where the click was aimed:
/// for a coordinate click its frame must contain the click point, for an element click it must overlap
/// the element's click frame. Without this, a coordinate click on a blank spot, whose best record is
/// the window, pressed the window's smallest button wherever it was, such as its close button.
func isDescendantClickCandidateAtTarget(candidateFrame: CGRect?, clickPoint: CGPoint?, targetFrame: CGRect?) -> Bool {
    guard let candidateFrame, !candidateFrame.isEmpty, !candidateFrame.isInfinite,
          candidateFrame.minX.isFinite, candidateFrame.minY.isFinite,
          candidateFrame.width.isFinite, candidateFrame.height.isFinite else {
        return false
    }

    if let clickPoint {
        return candidateFrame.contains(clickPoint)
    }

    return targetFrame.map(candidateFrame.intersects) ?? false
}

func isLikelyContainingRowActionFrame(
    targetFrame: CGRect,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool
) -> Bool {
    let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    guard
        hasPrimaryAction,
        let candidateFrame,
        candidateFrame.insetBy(dx: -2, dy: -2).contains(targetCenter),
        candidateFrame.width >= targetFrame.width,
        candidateFrame.height >= targetFrame.height,
        candidateFrame.height <= max(targetFrame.height + 32, targetFrame.height * 2)
    else {
        return false
    }

    return true
}

/// Whether a click-chain AX action ran: true when it did, false when the answer proves the app ran nothing, so the
/// chain may try its next way. Any other answer can come after the app acted: an app busy past the AX timeout answers
/// cannotComplete while the action runs, and AppKit answers AXConfirm on a table cell with attributeUnsupported after
/// it started editing. Those throw, so one click never lands a second time through another way.
func clickActionRan(_ result: AXError, action: String) throws -> Bool {
    switch result {
    case .success:
        return true
    case .attributeUnsupported where action.caseInsensitiveCompare("AXOpen") == .orderedSame:
        return true
    case .actionUnsupported, .illegalArgument, .notImplemented, .invalidUIElement:
        return false
    case .failure, .cannotComplete, .attributeUnsupported, .noValue:
        let message = clickMayHaveActedMessage(what: action, result: result)
        if result == .cannotComplete { throw ComputerUseError.timedOut(message, delivery: .outcomeUnknown) }
        throw ComputerUseError.message(message)
    default:
        throw ComputerUseError.message("AXUIElementPerformAction(\(action)) failed with \(result.rawValue)")
    }
}

/// The same for an attribute the click chain writes: a write the attribute refused never applied.
func clickAttributeWasSet(_ result: AXError, attribute: String) throws -> Bool {
    switch result {
    case .success:
        return true
    case .attributeUnsupported, .actionUnsupported, .illegalArgument, .noValue, .notImplemented, .invalidUIElement:
        return false
    case .failure, .cannotComplete:
        let message = clickMayHaveActedMessage(what: "setting \(attribute)", result: result)
        if result == .cannotComplete { throw ComputerUseError.timedOut(message, delivery: .outcomeUnknown) }
        throw ComputerUseError.message(message)
    default:
        throw ComputerUseError.message("AXUIElementSetAttributeValue(\(attribute)) failed with \(result.rawValue)")
    }
}

func clickMayHaveActedMessage(what: String, result: AXError) -> String {
    let answer = result == .cannotComplete ? "the app did not answer in time" : "the app answered AXError \(result.rawValue)"
    return "click: \(what) went out and \(answer); it may have acted, so no other click method was tried. Read the app state before retrying; a repeat could act twice."
}

// Shared by production dispatch and sequence tests: a partially delivered multi-click
// must never return "unhandled" and restart through another delivery method.
func performClickActionSequence(action: String, repeatCount: Int,
                                send: () throws -> AXError,
                                pause: () -> Void = {}) throws -> Bool {
    let attempts = max(repeatCount, 1)
    for index in 0..<attempts {
        let result = try send()
        guard try clickActionRan(result, action: action) else {
            guard index == 0 else {
                throw ComputerUseError.message("click: \(action) \(index + 1) of \(attempts) was refused after \(index) went out; no other click method was tried. Read the app state before retrying.")
            }
            return false
        }
        // AXOpen answered attributeUnsupported and opened: never open it again.
        if result != .success { return true }
        if index < attempts - 1 {
            pause()
        }
    }

    return true
}

/// The refusal for an element-index press on a control that says it is disabled, or nil to go ahead. AppKit answers
/// AXPress on a disabled NSButton with success and runs nothing, so without this the click reads as delivered. A
/// menu item is let through: a closed menu reports its items as they were when it last opened, and the app decides.
func disabledControlRefusal(enabled: Bool?, role: String?, elementIndex: String) -> String? {
    guard enabled == false, role != kAXMenuItemRole as String, role != kAXMenuBarItemRole as String else {
        return nil
    }
    return "element \(elementIndex) is disabled, so nothing was sent. Wait for it to be enabled, or act on another element."
}

func canUseActivationOnlyClickFallback(role: String?) -> Bool {
    guard let role else {
        return false
    }

    return isSnapshotRootRole(role)
}

func canUseKeyboardTextFallback(role: String?, roleDescription: String?, isValueSettable: Bool) -> Bool {
    if isValueSettable {
        return true
    }

    guard let role else {
        return false
    }

    if role == kAXTextFieldRole as String || role == "AXTextArea" || role == "AXTextView" {
        return true
    }

    guard let roleDescription = roleDescription?.lowercased() else {
        return false
    }

    return roleDescription.contains("text field")
        || roleDescription.contains("text area")
        || roleDescription.contains("text entry")
}

func isElectronScopedWebRowClickOptimizationTarget(appName: String, bundleIdentifier: String?) -> Bool {
    let normalizedBundleIdentifier = bundleIdentifier?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let normalizedName = appName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if let normalizedBundleIdentifier,
       normalizedBundleIdentifier.hasPrefix("com.electron.")
            || normalizedBundleIdentifier.contains(".electron.")
            || normalizedBundleIdentifier.contains("lark")
            || normalizedBundleIdentifier.contains("feishu")
    {
        return true
    }

    return normalizedName == "lark" || normalizedName == "feishu" || normalizedName == "飞书"
}

func shouldPreferContainingWebRowAXClickCandidate(
    role: String?,
    isSyntheticText: Bool,
    hasWebAreaAncestor: Bool,
    appName: String,
    bundleIdentifier: String?
) -> Bool {
    guard hasWebAreaAncestor,
          isElectronScopedWebRowClickOptimizationTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier
          )
    else {
        return false
    }

    guard let role else {
        return isSyntheticText
    }

    return role == kAXStaticTextRole as String || role == kAXGroupRole as String || isSyntheticText
}

public final class ComputerUseService {
    @TaskLocal static var requiredWindowID: CGWindowID?
    @TaskLocal static var requiredRefGeneration: UUID?
    @TaskLocal static var awaitsModalTextFocus = false
    @TaskLocal static var actionObservation: NativeActionObservation?
    @TaskLocal static var defersVerifiedSetValueObservation = false

    private var snapshotsByApp: [String: AppSnapshot] = [:]
    /// Counts stored reads; the label-miss cache treats each count as one snapshot generation.
    private var snapshotStoreCount = 0
    private let negativeLookups = NegativeLookupCache()
    private var invalidatedSnapshotAliases: Set<String> = []
    // Read per call: the app agent applies the caller's OPEN_COMPUTER_USE_* variables
    // for the duration of each request.
    private var actionReadBack: Bool { actionReadBackEnabled(environment: RequestConfiguration.environment) }

    // Targeted-lookup registry. `query` stores each match here keyed by a high,
    // monotonic element index; the existing element actions resolve that index to
    // the queried control and act without any snapshot. Indexes sit above the
    // snapshot tree range and are never reissued, so a later snapshot cannot
    // reassign one to a different control.
    private struct TargetedElement {
        let record: ElementRecord
        let context: TargetedAX.WindowContext
        let criteria: TargetedAX.Criteria
    }
    private let targetedElements = TargetedElementRegistry<TargetedElement>()

    public func clearQueryIndexes() { targetedElements.clear() }

    func clearSnapshotRefs() {
        for key in Array(snapshotsByApp.keys) {
            snapshotsByApp[key]?.elementRefs = nil
        }
    }

    func resolveElementRef(_ ref: String, app query: String) throws -> (index: Int, windowID: CGWindowID, generation: UUID) {
        guard let snapshot = snapshotsByApp[query.lowercased()], let refs = snapshot.elementRefs,
              let binding = snapshot.nativeWindow, binding.app.launchedAt != nil,
              snapshotsByApp[String(binding.app.pid)]?.elementRefs?.generation == refs.generation else {
            throw ComputerUseError.staleRef
        }
        return (try refs.index(for: ref), binding.id, refs.generation)
    }

    public init() {}

    /// An action's result reads the window back, so the app gets a beat to redraw
    /// first. Without read-back nothing is read, so there is no wait.
    /// With a target window, returns as soon as the window stops changing (WindowSettle),
    /// capped at `interval`; without one, sleeps the fixed interval as before.
    private func pauseBeforeReadBack(_ interval: TimeInterval, windowID: CGWindowID? = nil, window: AXUIElement? = nil) {
        guard Self.requiredWindowID == nil, actionReadBack else {
            return
        }

        guard WindowSettle.enabled, let windowID, !LockedUseActionScope.requiresScreenCaptureKit else {
            Thread.sleep(forTimeInterval: interval)
            return
        }
        // The learned settle budget for this app caps the wait, never above the call site's interval.
        let pid = window.flatMap { element -> pid_t? in
            var value: pid_t = 0
            return AXUIElementGetPid(element, &value) == .success ? value : nil
        }
        let cap = pid.map { AppTiming.settleCap(pid: $0, fixed: interval) } ?? interval
        let waited = WindowSettle.waitUntilStill(cap: cap, axBusy: { WindowSettle.rootShowsBusy(window) }) {
            SkyLightSPI.shared.hardwareCaptureWindow(windowID).flatMap(WindowSettle.fingerprint(of:))
        }
        if let pid { AppTiming.shared.recordSettle(app: AppTiming.key(pid: pid), ms: waited * 1000) }
    }

    /// The result an action returns: the after-action snapshot, or a short status
    /// when read-back is off.
    func actionResult(
        for query: String, recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
        refresh: ((SnapshotObservationOptions) throws -> AppSnapshot)? = nil
    ) throws -> ToolCallResult {
        guard Self.requiredWindowID == nil, actionReadBack else {
            return .text("ok")
        }

        do {
            let options = SnapshotObservationOptions(includeAX: true, includeScreenshot: false)
            let snapshot = try TimingLog.measure("action.native_readback") {
                try refresh?(options)
                    ?? refreshSnapshot(for: query, recoveryPolicy: recoveryPolicy, observation: options)
            }
            Self.actionObservation?.record(snapshot)
            let result = snapshotResult(for: snapshot, style: .actionResult)
            return LeanOutput.usesCompactReads ? LeanOutput.condensed(result, mode: .compact) : result
        } catch {
            throw ComputerUseError.acknowledged("Input was sent. Read the app to check its effect. \(SmartSteps.messageText(error))")
        }
    }

    public func listApps() -> ToolCallResult {
        ToolCallResult.text(
            AppDiscovery.listCatalog()
                .map(\.renderedLine)
                .joined(separator: "\n")
        )
    }

    public func getAppState(
        app query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        windowPlacement: WindowPlacement = .keep,
        observation: SnapshotObservationOptions = .defaults,
        settleMs: Int? = nil,
        compact: Bool = false,
        windowID: CGWindowID? = nil
    ) throws -> ToolCallResult {
        if windowPlacement == .agentDisplay { try VirtualDisplayConfig.current.requireEnabled() }
        try observation.validate()
        func render(_ snapshot: AppSnapshot) -> ToolCallResult {
            let result = snapshotResult(for: snapshot, style: .fullState)
            guard compact else { return result }
            let kept = snapshot.elements.values.compactMap { record -> String? in
                let isFocused = record.element.map { element in
                    snapshot.focusedElement.map { CFEqual(element, $0) } == true
                } ?? false
                return !record.rawActions.isEmpty || isFocused ? String(record.index) : nil
            }
            return LeanOutput.condensed(result, mode: .compact, preserving: Set(kept))
        }
        if let windowID {
            guard windowPlacement == .keep else {
                throw ComputerUseError.invalidArguments("A window-bound read cannot move the window.")
            }
            let app = try AppDiscovery.resolveRunning(query)
            let snapshot = try SnapshotBuilder.build(
                for: app, textLimit: textLimit, treeLimits: treeLimits,
                recoveryPolicy: .readOnly, observation: observation, windowID: windowID
            )
            guard snapshot.observedWindowID == windowID else { throw windowBindingError(windowID) }
            rememberSnapshot(snapshot, for: query)
            return render(snapshot)
        }
        if let settleMs {
            let note = try waitForWindowToSettle(app: query, timeoutMs: settleMs, runningOnly: observation.includeRefs)
            let result = try getAppState(app: query, textLimit: textLimit, treeLimits: treeLimits,
                                         windowPlacement: windowPlacement, observation: observation, compact: compact)
            // After the state text and before the screenshot, so primaryText stays the state.
            var content = result.content
            content.insert(.text(note), at: content.firstIndex { $0.dictionary["type"] as? String == "image" } ?? content.endIndex)
            return ToolCallResult(content: content, isError: result.isError)
        }
        guard windowPlacement != .keep else {
            return render(try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, observation: observation))
        }

        // Explicit placements never activate or raise; they only move the frame.
        let snapshot = try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .readOnly, observation: observation)
        guard snapshot.mode != .fixture else {
            throw ComputerUseError.message("window_placement '\(windowPlacement.rawValue)' is not supported for fixture apps")
        }
        switch windowPlacement {
        case .agentDisplay:
            guard var windowID = snapshot.targetWindowID, var windowElement = snapshot.windowElement else {
                throw ComputerUseError.stateUnavailable("window_placement 'agent_display' requires a current target window. Run get_app_state again.")
            }
            // A sheet cannot move on its own; park its window and the sheet goes along.
            if stringValue(of: windowElement, attribute: kAXRoleAttribute) == kAXSheetRole as String {
                guard let parent = copyParent(of: windowElement),
                      stringValue(of: parent, attribute: kAXRoleAttribute) == kAXWindowRole as String,
                      let parentID = SkyLightSPI.shared.windowID(for: parent), parentID != windowID
                else {
                    throw ComputerUseError.stateUnavailable("window_placement 'agent_display' requires the sheet's parent window. Run get_app_state again.")
                }
                windowElement = parent
                windowID = parentID
            }
            try AgentDisplay.shared.park(windowID: windowID, pid: snapshot.app.pid, window: windowElement)
        case .restore:
            try AgentDisplay.shared.restoreAll(pid: snapshot.app.pid)
        case .keep:
            break
        }

        return render(try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .readOnly, observation: observation))
    }

    /// Waits while the app's window shows a busy sign, for at most `timeoutMs` (capped at 5 s).
    /// Read-only: no activation, no capture.
    private func waitForWindowToSettle(app query: String, timeoutMs: Int, runningOnly: Bool = false) throws -> String {
        try requireUsableComputerUseSession()
        let start = ProcessInfo.processInfo.systemUptime
        guard let app = try? (runningOnly ? AppDiscovery.resolveRunning(query) : AppDiscovery.resolve(query)),
              let context = try? SnapshotBuilder.resolveTargetWindow(for: app) else {
            return "Settle skipped: no window to watch yet."
        }
        let settled = WindowSettle.wait(timeout: TimeInterval(min(timeoutMs, 5000)) / 1000, pid: app.pid) {
            TimingLog.measure("get_app_state.settle_scan") { WindowSettle.busy(from: context.windowElement, requireComplete: true, read: WindowSettle.readAll) }
        }
        let waited = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        return settled
            ? "Settled: the window stayed free of busy signs (waited \(waited) ms)."
            : "Not settled: no quiet period confirmed after \(waited) ms. Showing the current state."
    }

    /// Local decision hints can see a window only when it still matches the native observation.
    func localDecisionImage(app query: String, state: String) -> Data? {
        guard (try? requireUsableComputerUseSession()) != nil,
              let id = HandoffTool.observedWindowID(in: state),
              let snapshot = snapshotsByApp[query.lowercased()], snapshot.observedWindowID == id,
              let window = snapshot.windowElement,
              let app = try? AppDiscovery.resolveRunning(query), snapshot.app.pid == app.pid,
              snapshot.app.runningApplication.launchDate == app.runningApplication.launchDate,
              let context = try? SnapshotBuilder.resolveTargetWindow(for: app, windowID: id),
              CFEqual(window, context.windowElement), snapshot.windowBounds == context.windowBounds,
              let image = SnapshotBuilder.localWindowImage(context),
              let crop = LocalWindowImage.downscaled(image) else { return nil }
        return LocalWindowImage.jpeg(crop)
    }

    /// Ground a label in the same observed window, then verify it immediately before delivery.
    func visionClick(app query: String, label: String, method: ClickMethod) throws -> ToolCallResult? {
        guard method == .auto || method == .skyClick, !VisionFallback.risky(label),
              label.contains(where: { $0.isLetter || $0.isNumber }),
              (try? requireUsableComputerUseSession()) != nil,
              let snapshot = snapshotsByApp[query.lowercased()], let id = snapshot.observedWindowID,
              let window = snapshot.windowElement, let bounds = snapshot.windowBounds else { return nil }

        func liveWindow() -> TargetedAX.WindowContext? {
            guard (BrowserCallBudget.activeRemaining ?? .infinity) > 0,
                  let app = try? AppDiscovery.resolveRunning(query), app.pid == snapshot.app.pid,
                  app.runningApplication.launchDate == snapshot.app.runningApplication.launchDate,
                  let context = try? SnapshotBuilder.resolveTargetWindow(for: app, windowID: id),
                  CFEqual(window, context.windowElement), bounds == context.windowBounds else { return nil }
            return context
        }

        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + min(VisionFallback.timeout, BrowserCallBudget.activeRemaining ?? .infinity)
        guard let context = liveWindow(), let original = SnapshotBuilder.localWindowImage(context),
              let crop = LocalWindowImage.downscaled(original) else { return nil }
        // Learning row for this attempt, written on every exit below (see VisionFallback.recordLocate).
        var located: VisionFallback.Candidate?
        var verified = false
        // Password and secure fields keep their row but never their crop image.
        var secure = LearningScrubber.marksSecureField([label, snapshot.renderedText])
        defer {
            VisionFallback.recordLocate(query: label, crop: crop, candidate: located, verified: verified,
                                        secure: secure, log: LearningLog.shared)
        }
        let candidate = VisionFallback.candidate(scan: { accurate in
            guard clock.systemUptime < deadline else { return .missing }
            return LocalOCR.scan(crop, label: label, level: accurate ? .accurate : .fast)
        }, locate: {
            guard clock.systemUptime < deadline,
                  let overview = LocalWindowImage.downscaled(crop, maxSide: VisionFallback.overviewMaxSide),
                  let jpeg = LocalWindowImage.jpeg(overview) else { return nil }
            return VisionFallback.locate(imageBase64: jpeg.base64EncodedString(), query: label,
                                         remaining: deadline - clock.systemUptime)
        })
        located = candidate
        guard let candidate, let firstPoint = VisionFallback.windowPoint(candidate.fraction, bounds: bounds),
              clock.systemUptime < deadline, let live = liveWindow(),
              let fresh = SnapshotBuilder.localWindowImage(live), VisionFallback.sameCapture(original, fresh) else { return nil }

        // A point is confirmed only when the control under it carries the label and no risky name.
        func confirms(_ point: CGPoint, _ candidate: VisionFallback.Candidate) -> Bool {
            guard let hit = try? hitTestElement(at: point, in: snapshot)?.element else { return false }
            if isSecureTextField(subrole: stringValue(of: hit, attribute: kAXSubroleAttribute)) { secure = true }
            guard SnapshotBuilder.belongsToWindow(hit, window: live.windowElement),
                  let names = visualHitNames(hit, window: live.windowElement) else { return false }
            return VisionFallback.allowsHit(candidate: candidate, label: label, hitNames: names)
        }
        // Cascade step 5 (GroundingCascade): when the first model point misses its label, one locate on a
        // zoomed crop around it. That point is accepted only when it confirms the label too.
        let chosen: (candidate: VisionFallback.Candidate, point: CGPoint)
        if confirms(firstPoint, candidate) {
            chosen = (candidate, firstPoint)
        } else if candidate.evidence == .model, clock.systemUptime < deadline,
                  let zoomed = GroundingCascade.secondLook(at: candidate.fraction, locate: { rect in
                      let width = CGFloat(crop.width), height = CGFloat(crop.height)
                      let pixels = CGRect(x: rect.minX * width, y: rect.minY * height,
                                          width: rect.width * width, height: rect.height * height).integral
                      guard clock.systemUptime < deadline, let sub = crop.cropping(to: pixels),
                            let jpeg = LocalWindowImage.jpeg(sub) else { return nil }
                      return VisionFallback.locate(imageBase64: jpeg.base64EncodedString(), query: label,
                                                   remaining: deadline - clock.systemUptime)
                  }, verify: { fraction in
                      guard let zoomPoint = VisionFallback.windowPoint(fraction, bounds: bounds) else { return false }
                      return confirms(zoomPoint, VisionFallback.Candidate(fraction: fraction, evidence: .zoom))
                  }),
                  let zoomPoint = VisionFallback.windowPoint(zoomed, bounds: bounds) {
            chosen = (VisionFallback.Candidate(fraction: zoomed, evidence: .zoom), zoomPoint)
            located = chosen.candidate
        } else {
            return nil
        }
        let point = chosen.point
        guard clock.systemUptime < deadline, liveWindow() != nil else { return nil }
        verified = true

        let screenPoint = CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y)
        try RequestCancellation.check()  // L6: a cancelled request sends nothing
        try InputSimulation.clickWithSkyLight(at: screenPoint, windowPoint: point, windowBounds: bounds,
                                               windowID: id, clickCount: 1, pid: live.app.pid)
        // Read back the same window. Delivery has already happened if this read fails.
        let state = try? getAppState(app: query,
            observation: SnapshotObservationOptions(includeAX: true, includeScreenshot: false), windowID: id)
        // The provenance (ocr, model or zoom) is part of the reply, as the cascade names every step.
        let source = VisionFallback.evidenceName(chosen.candidate.evidence)
        return ToolCallResult(content: [.text(state == nil
            ? "Clicked the verified on-screen target (found by \(source)). Read the window to check the result."
            : "Clicked the verified on-screen target (found by \(source)).")] + (state?.content ?? []),
            deliveryState: .acknowledged)  // the target was verified; its effect was not
    }

    private func visualHitNames(_ leaf: AXUIElement, window: AXUIElement) -> [String]? {
        var element = leaf
        var names: [String] = []
        var sawAction = false
        for _ in 0..<32 {
            if CFEqual(element, window) { return names }
            var enabled: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
               (enabled as? Bool) == false { return nil }
            let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
            var current = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .compactMap { stringValue(of: element, attribute: $0) }
            if role == kAXStaticTextRole as String, let value = stringValue(of: element, attribute: kAXValueAttribute) {
                current.append(value)
            }
            if current.contains(where: VisionFallback.risky) { return nil }
            let actions = copyActions(for: element) ?? []
            if !sawAction, CFEqual(element, leaf) || actions.contains(kAXPressAction as String) {
                names.append(contentsOf: current.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
            sawAction = sawAction || actions.contains(kAXPressAction as String)
            guard let parent = copyParent(of: element) else { return nil }
            element = parent
        }
        return nil
    }

    public func click(
        app query: String,
        elementIndex: String?,
        x: Double?,
        y: Double?,
        clickCount: Int,
        mouseButton: String,
        clickMethod requestedMethod: ClickMethod = .auto
    ) throws -> ToolCallResult {
        let strict = StrictBackground.enabled()
        let clickMethod: ClickMethod
        if strict {
            guard elementIndex != nil, requestedMethod == .auto || requestedMethod == .accessibility else {
                throw ComputerUseError.backgroundUnsupported("Strict background clicks need an accessibility element.")
            }
            clickMethod = .accessibility
        } else if Self.requiredWindowID != nil {
            switch requestedMethod {
            case .auto:
                clickMethod = elementIndex == nil ? .skyClick : .accessibility
            case .accessibility:
                clickMethod = requestedMethod
            case .skyClick:
                guard Self.requiredRefGeneration == nil else {
                    throw ComputerUseError.invalidArguments("A ref click requires accessibility delivery.")
                }
                clickMethod = requestedMethod
            case .global, .appPost:
                throw ComputerUseError.invalidArguments("A bound click requires accessibility or sky_click delivery.")
            }
        } else {
            clickMethod = requestedMethod
        }
        try validateClickMethod(
            clickMethod,
            hasElementIndex: elementIndex != nil,
            environment: RequestConfiguration.environment
        )
        try validateSkyClickArguments(
            method: clickMethod,
            mouseButton: mouseButton,
            clickCount: clickCount
        )

        if Self.requiredWindowID != nil, clickMethod == .accessibility,
           let elementIndex, x == nil, y == nil {
            let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex, requireStableBounds: false)
            let record = try lookupElement(snapshot: snapshot, index: elementIndex)
            try refuseDisabledControl(record, elementIndex: elementIndex)
            let button = MouseButtonKind(rawValue: mouseButton.lowercased()) ?? .left
            guard try performAXClickSequence(on: record, snapshot: snapshot, button: button, clickCount: clickCount,
                                             includeNearbyHitTesting: false, allowActivationFallback: false) else {
                throw ComputerUseError.notSent("The observed control could not be clicked through accessibility.")
            }
            return try actionResult(for: query, recoveryPolicy: .readOnly)
        }

        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let button = MouseButtonKind(rawValue: mouseButton.lowercased()) ?? .left
        if elementIndex == nil, !snapshot.observation.includeScreenshot {
            throw ComputerUseError.stateUnavailable(SnapshotObservationOptions.screenshotOmittedNote + "; request a screenshot before screenshot-coordinate actions")
        }
        if snapshot.mode == .fixture {
            guard clickMethod == .auto || (strict && requestedMethod == .auto) else {
                throw ComputerUseError.message(
                    "click_method '\(clickMethod.rawValue)' is not supported for fixture apps"
                )
            }

            let cursorTarget: VisualCursorTarget?
            if let elementIndex {
                let record = try lookupElement(snapshot: snapshot, index: elementIndex)
                guard let identifier = record.identifier else {
                    throw ComputerUseError.invalidArguments("fixture click requires an identifier-backed element")
                }
                cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier))
            } else if let x, let y {
                let identifier = try fixtureIdentifier(at: CGPoint(x: x, y: y), snapshot: snapshot)
                cursorTarget = fixtureVisualCursorTarget(identifier: identifier, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier, x: x, y: y))
            } else {
                throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
            }

            Thread.sleep(forTimeInterval: 0.15)
            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
            return try actionResult(for: query)
        }

        if let elementIndex {
            let record = try lookupElement(snapshot: snapshot, index: elementIndex)
            try refuseDisabledControl(record, elementIndex: elementIndex)
            guard let windowPoint = clickPoint(for: record, snapshot: snapshot) else {
                throw ComputerUseError.stateUnavailable("element \(elementIndex) has no clickable frame")
            }
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: windowPoint)
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer,
                anchor: makeCursorWindowAnchor(snapshot: snapshot, windowLocalPoint: windowPoint)
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto:
                    if !(try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: Self.requiredWindowID == nil,
                        allowActivationFallback: Self.requiredWindowID == nil
                    )) {
                        try performNonAXClickFallback(
                            at: targetPoint,
                            button: button,
                            clickCount: clickCount,
                            targetDescription: "element_index=\(elementIndex)",
                            snapshot: snapshot
                        )
                    }
                case .accessibility:
                    guard try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: !strict && Self.requiredWindowID == nil,
                        allowActivationFallback: !strict && Self.requiredWindowID == nil
                    ) else {
                        if strict {
                            throw ComputerUseError.backgroundUnsupported("The element cannot be clicked through accessibility.")
                        }
                        throw ComputerUseError.message(
                            "click_method 'accessibility' could not click element_index=\(elementIndex)"
                        )
                    }
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        at: targetPoint,
                        windowPoint: windowPoint,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: "element_index=\(elementIndex)",
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
        } else if let x, let y {
            let screenshotPoint = CGPoint(x: x, y: y)
            let point = try screenshotPixelToWindowPointInSnapshot(snapshot: snapshot, point: screenshotPoint)
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: point)
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer,
                anchor: makeCursorWindowAnchor(snapshot: snapshot, windowLocalPoint: point)
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto:
                    let candidates = try clickCandidates(at: point, in: snapshot)
                    var handled = false
                    for record in candidates {
                        if try performAXClickSequence(
                            on: record,
                            snapshot: snapshot,
                            button: button,
                            clickCount: clickCount,
                            includeNearbyHitTesting: false,
                            allowActivationFallback: false,
                            clickPoint: point
                        ) {
                            handled = true
                            break
                        }
                    }

                    if !handled {
                        try performNonAXClickFallback(
                            at: targetPoint,
                            button: button,
                            clickCount: clickCount,
                            targetDescription: "x=\(Int(screenshotPoint.x)) y=\(Int(screenshotPoint.y))",
                            snapshot: snapshot
                        )
                    }
                case .accessibility:
                    throw ComputerUseError.message("click_method 'accessibility' requires element_index")
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        at: targetPoint,
                        windowPoint: point,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: "x=\(Int(screenshotPoint.x)) y=\(Int(screenshotPoint.y))",
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
        } else {
            throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
        }

        return try actionResult(for: query, recoveryPolicy: clickActionSnapshotRecoveryPolicy(for: clickMethod))
    }

    func preciseClick(app query: String, elementIndex: String?, x: Double?, y: Double?, placement: ClickPlacement,
                      hasPlacement: Bool, count: Int, buttonName: String, modifiers: [String]) throws -> ToolCallResult {
        guard let button = MouseButtonKind(rawValue: buttonName.lowercased()), button == .left || count == 1 else {
            throw ComputerUseError.invalidArguments("Use left, right or middle. Multiple clicks need the left button.")
        }
        guard elementIndex != nil ? x == nil && y == nil : !hasPlacement && count == 1 && x != nil && y != nil else {
            throw ComputerUseError.invalidArguments("Use a control for anchors, offsets or multiple clicks. A single click can use both screenshot coordinates.")
        }
        let flags = try dragModifierFlags(modifiers)
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex, recoveryPolicy: .readOnly)
        guard let windowID = snapshot.targetWindowID, let bounds = snapshot.windowBounds, snapshot.mode != .fixture else {
            throw ComputerUseError.backgroundUnsupported("Precise clicks need a native target window.")
        }
        let record = try elementIndex.map { try lookupElement(snapshot: snapshot, index: $0) }
        let point: CGPoint
        if let record, let elementIndex {
            try refuseDisabledControl(record, elementIndex: elementIndex)
            guard let frame = record.localFrame else {
                throw ComputerUseError.stateUnavailable("The control has no readable frame.")
            }
            point = try placement.point(in: frame)
        } else if let x, let y, snapshot.observation.includeScreenshot {
            point = try screenshotPixelToWindowPointInSnapshot(snapshot: snapshot, point: CGPoint(x: x, y: y))
        } else {
            throw ComputerUseError.stateUnavailable("Read the target window with a screenshot before clicking by pixels.")
        }
        let screen = try windowPointToGlobalPoint(snapshot: snapshot, point: point)
        let location = inputEventPoint(fromScreenStatePoint: screen)
        let target = BackgroundDragTarget(start: location, end: location, windowBounds: bounds,
                                          windowID: windowID, pid: snapshot.app.pid)
        let visual = makeVisualCursorTarget(at: screen, targetWindowID: windowID, targetWindowLayer: snapshot.targetWindowLayer)
        moveVisualCursor(to: visual)
        defer { settleVisualCursor(at: visual) }
        try BackgroundDragDispatcher.click(target: target, button: button, count: count, flags: flags) {
            if let record, let elementIndex {
                try self.validatePointerTarget(record, index: elementIndex, point: point, snapshot: snapshot)
            }
        }
        pulseVisualCursor(at: visual, clickCount: count, mouseButton: button)
        let state = try actionResult(for: query, recoveryPolicy: .readOnly)
        return ToolCallResult(content: [.text("Delivered \(count) click event pair(s).")] + state.content, isError: state.isError)
    }

    private func validatePointerTarget(_ record: ElementRecord, index: String, point: CGPoint, snapshot: AppSnapshot) throws {
        _ = try keptRecord(record, index: index, snapshot: snapshot)
        try refuseDisabledControl(record, elementIndex: index)
        guard let element = record.element, let window = snapshot.windowElement,
              SnapshotBuilder.belongsToWindow(element, window: window),
              localFrame(of: element, windowBounds: snapshot.windowBounds) == record.localFrame,
              var hit = try hitTestElement(at: point, in: snapshot)?.element else {
            throw ComputerUseError.stateUnavailable("The control moved or its hit point could not be verified. Read the window again.")
        }
        for _ in 0..<24 {
            if CFEqual(hit, element) { return }
            guard let parent = copyParent(of: hit) else { break }
            hit = parent
        }
        throw ComputerUseError.stateUnavailable("Another control covers the target point.")
    }

    public func performSecondaryAction(app query: String, elementIndex: String, action: String) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard action.caseInsensitiveCompare("Raise") == .orderedSame else {
                throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
            }

            return try actionResult(for: query)
        }

        guard let rawAction = matchingAction(requested: action, record: record) else {
            throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }
        try refuseDisabledControl(record, elementIndex: elementIndex)

        if rawAction.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame {
            guard Self.requiredWindowID == nil else {
                throw ComputerUseError.invalidArguments("Raise is unavailable in a bound action.")
            }
            if backgroundOnlyMode() {
                throw ComputerUseError.message(backgroundOnlyRaiseRefusedMessage)
            }
            // Raise brings the window in front of the user's work; only a borrowed app (foreground: true) may raise.
            guard FocusBorrow.isBorrowed(pid: snapshot.app.pid) else {
                throw ComputerUseError.message("Raise is refused in the background: it would bring the window in front of the user's work. Send it in a batch with \"foreground\": true to raise it.")
            }
        }

        try requireUsableComputerUseSession()
        let result = AXUIElementPerformAction(element, rawAction as CFString)
        guard result == .success else {
            throw ComputerUseError.message("AXUIElementPerformAction failed with \(result.rawValue)")
        }

        pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
        return try actionResult(for: query)
    }

    public func hover(app query: String, elementIndex: String) throws -> ToolCallResult {
        try hover(app: query, elementIndex: elementIndex, dwell: nil)
    }

    func hover(app query: String, elementIndex: String, dwell: TimeInterval?) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex,
                                             recoveryPolicy: dwell == nil ? .allowActivation : .readOnly)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)
        if Self.requiredRefGeneration != nil {
            guard let element = record.element, let frame = record.localFrame,
                  localFrame(of: element, windowBounds: snapshot.windowBounds) == frame else {
                throw ComputerUseError.staleRef
            }
        }
        guard snapshot.mode != .fixture, let windowID = snapshot.targetWindowID,
              let bounds = snapshot.windowBounds,
              let point = try globalPoint(for: record, snapshot: snapshot) else {
            throw ComputerUseError.stateUnavailable("Hover requires an element with a frame inside the observed Mac window.")
        }
        if let dwell, let local = localCenter(for: record) {
            try validatePointerTarget(record, index: elementIndex, point: local, snapshot: snapshot)
            try ActionOptions.requireTime(for: dwell + 0.1)
        }
        let location = inputEventPoint(fromScreenStatePoint: point)
        try BackgroundDragDispatcher.hover(target: BackgroundDragTarget(
            start: location, end: location, windowBounds: bounds, windowID: windowID, pid: snapshot.app.pid
        ))
        let visualTarget = visualCursorTarget(for: record, snapshot: snapshot)
        moveVisualCursor(to: visualTarget)
        settleVisualCursor(at: visualTarget)
        if let dwell, dwell > 0 {
            Thread.sleep(forTimeInterval: dwell)
        } else {
            pauseBeforeReadBack(0.1, windowID: windowID)
        }
        let state = try actionResult(for: query, recoveryPolicy: dwell == nil ? .allowActivation : .readOnly)
        let note = dwell.map { "Hovered for \(Int(($0 * 1000).rounded())) ms. Check the resulting state." }
            ?? "Hover event delivered. Check the app state for the expected effect."
        return ToolCallResult(content: [.text(note)] + state.content,
                              isError: state.isError)
    }

    static func validateScrollPages(_ pages: Double) throws {
        guard pages.isFinite, pages > 0, pages <= 100 else {
            throw ComputerUseError.invalidArguments("pages must be greater than 0 and at most 100")
        }
    }

    public func scroll(app query: String, direction: String, elementIndex: String, pages: Double) throws -> ToolCallResult {
        let normalized = direction.lowercased()
        guard ["up", "down", "left", "right"].contains(normalized) else {
            throw ComputerUseError.message("Invalid scroll direction: \(direction)")
        }
        try Self.validateScrollPages(pages)

        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture scroll requires an identifier-backed element")
            }
            try FixtureBridge.post(FixtureCommand(kind: "scroll", identifier: identifier, direction: normalized, pages: pages))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        let direction: CGVector = switch normalized {
        case "up": CGVector(dx: 0, dy: -1)
        case "down": CGVector(dx: 0, dy: 1)
        case "left": CGVector(dx: -1, dy: 0)
        default: CGVector(dx: 1, dy: 0)
        }
        let target = visualCursorTarget(for: record, snapshot: snapshot)
        try withVisualFeedback(.scroll(direction), at: target) {
            var scrolledByAccessibility = false
            if let repeatCount = integralScrollPageCount(pages),
               let rawAction = record.rawActions.first(where: { $0.caseInsensitiveCompare("AXScroll\(normalized.capitalized)ByPage") == .orderedSame }),
               let element = record.element {
                let outcome = try scrollPagesByAccessibility(element, action: rawAction, count: repeatCount)
                if let refusal = outcome.refusal {
                    // Some pages moved: stop and say so, rather than repeating the scroll by another route.
                    if outcome.done > 0 {
                        throw ComputerUseError.stateUnavailable(scrollPagesRefusedMessage(done: outcome.done, requested: repeatCount, error: refusal))
                    }
                } else {
                    scrolledByAccessibility = true
                }
            }

            if !scrolledByAccessibility {
                if StrictBackground.enabled() {
                    throw ComputerUseError.backgroundUnsupported("This element cannot scroll by whole pages through accessibility.")
                }
                guard Self.requiredWindowID == nil else {
                    throw ComputerUseError.stateUnavailable("This element cannot scroll by whole pages through accessibility in the bound window.")
                }
                // Refused before the first page, or not a page-scrolling element: a scroll-wheel event over its frame.
                guard let point = try globalPoint(for: record, snapshot: snapshot) else {
                    throw ComputerUseError.stateUnavailable("element \(elementIndex) has no scrollable frame")
                }
                try performScrollEvent(
                    at: point,
                    direction: normalized,
                    pages: pages,
                    targetDescription: "element_index=\(elementIndex)",
                    snapshot: snapshot
                )
            }
        }

        pauseBeforeReadBack(0.1, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
        return try actionResult(for: query)
    }

    func scroll(app query: String, direction: String, elementIndex: String, chunks: ScrollChunks) throws -> ToolCallResult {
        let direction = direction.lowercased()
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw ComputerUseError.invalidArguments("scroll direction must be up, down, left or right")
        }
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex, recoveryPolicy: .readOnly)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)
        guard let bounds = snapshot.windowBounds, let window = snapshot.windowElement,
              let id = snapshot.targetWindowID, let element = record.element,
              let area = scrollAncestor(of: element, in: window, includingSelf: true) else {
            throw ComputerUseError.backgroundUnsupported("Choose an accessibility scroll area in the observed window.")
        }
        let horizontal = direction == "left" || direction == "right"
        let barAttribute = horizontal ? kAXHorizontalScrollBarAttribute : kAXVerticalScrollBarAttribute
        func position() throws -> Double {
            guard let bar = Self.elementAttribute(area, barAttribute), let value = nativeObservedValue(bar),
                  let number = Double(value), number.isFinite else {
                throw ComputerUseError.backgroundUnsupported("This scroll area has no readable scroll position.")
            }
            return number
        }
        func validate() throws -> TargetedAX.WindowContext {
            try requireUsableComputerUseSession()
            let context = try SnapshotBuilder.resolveTargetWindow(for: snapshot.app, windowID: id)
            guard CFEqual(context.windowElement, window), context.windowBounds == bounds,
                  SnapshotBuilder.belongsToWindow(area, window: window) else {
                throw ComputerUseError.stateUnavailable("The scroll window changed. Read it before continuing.")
            }
            return context
        }
        let outcome = try chunks.run(visible: {
            let context = try validate()
            guard let label = chunks.untilVisible else { return false }
            let matches = try SnapshotBuilder.targetedSearch(
                .init(text: label, exact: true, role: nil, limit: 20, maxNodes: 500), in: context
            )
            let visible = matches.records.filter { candidate in
                guard let el = candidate.element,
                      let ancestor = scrollAncestor(of: el, in: window),
                      CFEqual(ancestor, area) else { return false }
                return nativeFrameIsInView(el, snapshot: snapshot)
            }
            return visible.count == 1 && matches.stopReason == nil
        }, advance: {
            _ = try validate()
            let before = try position()
            if chunks.unit == .pages {
                let requested = "AXScroll\(direction.capitalized)ByPage"
                guard let action = copyActions(for: area)?.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) else {
                    throw ComputerUseError.backgroundUnsupported("This area exposes no AX page scroll. Try unit points or lines.")
                }
                let status = AXUIElementPerformAction(area, action as CFString)
                guard status == .success else {
                    throw ComputerUseError.stateUnavailable("AX scroll returned \(status.rawValue). Check the position before trying another step.")
                }
            } else {
                guard let frame = localFrame(of: area, windowBounds: bounds) else {
                    throw ComputerUseError.stateUnavailable("The scroll area has no current frame.")
                }
                let viewport = frame.intersection(CGRect(origin: .zero, size: bounds.size))
                guard !viewport.isEmpty else {
                    throw ComputerUseError.stateUnavailable("The scroll area is outside the window.")
                }
                let point = try windowPointToGlobalPoint(snapshot: snapshot, point: CGPoint(x: viewport.midX, y: viewport.midY))
                let location = inputEventPoint(fromScreenStatePoint: point)
                try BackgroundDragDispatcher.scroll(target: .init(start: location, end: location, windowBounds: bounds, windowID: id, pid: snapshot.app.pid),
                                                    direction: direction, unit: chunks.unit, size: chunks.size)
            }
            // Allow a short asynchronous AX update before treating this chunk as stalled.
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.05)
                _ = try validate()
                if try position() != before { return true }
            }
            return false
        })
        return .text(try outcome.reply(label: chunks.untilVisible))
    }

    func zoomControl(app query: String, elementIndex: String, increase: Bool) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex, recoveryPolicy: .readOnly)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)
        try refuseDisabledControl(record, elementIndex: elementIndex)
        let action = increase ? kAXIncrementAction : kAXDecrementAction
        guard let element = record.element, let id = snapshot.targetWindowID, let window = snapshot.windowElement,
              let before = nativeObservedValue(element), let value = Double(before), value.isFinite,
              let raw = matchingAction(requested: action, record: record) else {
            throw ComputerUseError.backgroundUnsupported("This zoom control has no readable value or matching accessibility action.")
        }
        let live = try SnapshotBuilder.resolveTargetWindow(for: snapshot.app, windowID: id)
        guard CFEqual(live.windowElement, window), SnapshotBuilder.belongsToWindow(element, window: window) else {
            throw windowBindingError(id)
        }
        try requireUsableComputerUseSession()
        let outcome = AXUIElementPerformAction(element, raw as CFString)
        guard outcome == .success else {
            throw ComputerUseError.stateUnavailable("The zoom control returned \(outcome.rawValue). Inspect its value before repeating.")
        }
        let deadline = BrowserCallBudget.deadline(after: min(0.4, BrowserCallBudget.remaining()))
        repeat {
            if let after = nativeObservedValue(element), let next = Double(after), next.isFinite,
               increase ? next > value : next < value {
                return .text("Zoom control changed to \(after).")
            }
            Thread.sleep(forTimeInterval: min(0.04, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw ComputerUseError.stateUnavailable("Zoom action delivered. The control did not report the expected change.")
    }

    func waitForControl(app query: String, wait: ControlWait) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query, needScreenshot: false, recoveryPolicy: .readOnly)
        return .text(try waitForControl(in: snapshot, wait: wait))
    }

    private func waitForControl(in snapshot: AppSnapshot, wait: ControlWait) throws -> String {
        guard let id = snapshot.targetWindowID, let window = snapshot.windowElement else {
            throw ComputerUseError.backgroundUnsupported("This wait requires an observed native window.")
        }
        let reply = try wait.run { () -> ControlWait.Sample<AXWaitIdentity> in
            try requireUsableComputerUseSession()
            let context = try SnapshotBuilder.resolveTargetWindow(for: snapshot.app, windowID: id)
            guard CFEqual(context.windowElement, window) else {
                throw ComputerUseError.stateUnavailable("The observed window changed during the wait.")
            }
            let search = try SnapshotBuilder.targetedSearch(
                .init(text: wait.label, exact: true, role: nil, limit: 10, maxNodes: 1000), in: context
            )
            if search.records.isEmpty {
                return search.truncated ? .unreadable : .absent
            }
            guard wait.condition == .valueChanged else { return .present }
            guard !search.truncated, search.records.count == 1, let record = search.records.first,
                  let element = record.element, let value = nativeObservedValue(element) else {
                return .unreadable
            }
            return .value(AXWaitIdentity(element: element), value)
        }
        return reply
    }

    private struct AXWaitIdentity: Equatable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    }

    func scrollIntoView(app query: String, elementIndex: String) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex, recoveryPolicy: .readOnly)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)
        guard let element = record.element, let window = snapshot.windowElement, let id = snapshot.targetWindowID else {
            throw ComputerUseError.backgroundUnsupported("This control has no verifiable Mac window.")
        }
        func validateWindow() throws {
            try requireUsableComputerUseSession()
            let live = try SnapshotBuilder.resolveTargetWindow(for: snapshot.app, windowID: id)
            guard CFEqual(live.windowElement, window), live.windowBounds == snapshot.windowBounds,
                  SnapshotBuilder.belongsToWindow(element, window: window) else {
                throw ComputerUseError.stateUnavailable("The control or its window changed. Read it again.")
            }
        }
        try validateWindow()
        if nativeFrameIsInView(element, snapshot: snapshot) { return .text("Control already in view.") }
        guard let action = matchingAction(requested: "AXScrollToVisible", record: record) else {
            throw ComputerUseError.backgroundUnsupported("This control exposes no AXScrollToVisible action. Try scroll with until_visible.")
        }
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw ComputerUseError.stateUnavailable("AXScrollToVisible returned \(result.rawValue). Check the window before retrying.")
        }
        Thread.sleep(forTimeInterval: 0.15)
        try validateWindow()
        guard nativeFrameIsInView(element, snapshot: snapshot) else {
            throw ComputerUseError.stateUnavailable("The app accepted the scroll. The control could not be confirmed in view.")
        }
        return .text("Control scrolled into view.")
    }

    private func scrollAncestor(of element: AXUIElement, in window: AXUIElement, includingSelf: Bool = false) -> AXUIElement? {
        var current: AXUIElement? = includingSelf ? element : copyParent(of: element)
        for _ in 0..<24 {
            guard let node = current, !CFEqual(node, window) else { break }
            if stringValue(of: node, attribute: kAXRoleAttribute) == kAXScrollAreaRole as String { return node }
            current = copyParent(of: node)
        }
        return nil
    }

    private func nativeFrameIsInView(_ element: AXUIElement, snapshot: AppSnapshot) -> Bool {
        guard let bounds = snapshot.windowBounds, let window = snapshot.windowElement,
              let frame = localFrame(of: element, windowBounds: bounds), !frame.isEmpty else { return false }
        var visible = frame.intersection(CGRect(origin: .zero, size: bounds.size))
        var current = element
        for _ in 0..<16 {
            guard !visible.isEmpty else { return false }
            guard let area = scrollAncestor(of: current, in: window) else { return true }
            guard let clip = localFrame(of: area, windowBounds: bounds) else { return false }
            visible = visible.intersection(clip)
            current = area
        }
        return false
    }

    private func nativeObservedValue(_ element: AXUIElement) -> String? {
        guard !isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success else { return nil }
        return (raw as? String) ?? (raw as? NSNumber)?.stringValue
    }

    public func drag(app query: String, fromX: Double, fromY: Double, toX: Double, toY: Double, modifiers: [String] = []) throws -> ToolCallResult {
        guard [fromX, fromY, toX, toY].allSatisfy(\.isFinite) else {
            throw ComputerUseError.invalidArguments("drag requires finite coordinates")
        }
        guard fromX != toX || fromY != toY else {
            throw ComputerUseError.invalidArguments("drag needs distinct start and end points")
        }
        let flags = try dragModifierFlags(modifiers)
        let deliveryPath: DragDeliveryPath = Self.requiredWindowID == nil
            ? dragDeliveryPath(environment: RequestConfiguration.environment)
            : .appPost
        let recoveryPolicy = dragActionSnapshotRecoveryPolicy(for: deliveryPath)
        let snapshot = try currentSnapshot(for: query, recoveryPolicy: recoveryPolicy)
        guard snapshot.observation.includeScreenshot else {
            throw ComputerUseError.stateUnavailable(SnapshotObservationOptions.screenshotOmittedNote + "; request a screenshot before screenshot-coordinate actions")
        }
        if snapshot.mode == .fixture {
            guard modifiers.isEmpty else {
                throw ComputerUseError.invalidArguments("drag modifiers require a native target window")
            }
            try FixtureBridge.post(FixtureCommand(kind: "drag", identifier: "fixture-drag-pad", x: fromX, y: fromY, toX: toX, toY: toY))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        if deliveryPath == .appPost {
            guard let size = screenshotPixelSize(snapshot: snapshot) else {
                throw ComputerUseError.stateUnavailable("Background drag requires a delivered screenshot of the target window.")
            }
            let width = Double(size.width)
            let height = Double(size.height)
            guard [fromX, toX].allSatisfy({ $0 >= 0 && $0 < width }),
                  [fromY, toY].allSatisfy({ $0 >= 0 && $0 < height }) else {
                throw ComputerUseError.invalidArguments("Background drag requires both points inside the target window screenshot.")
            }
        }

        let start = try screenshotToGlobalPoint(snapshot: snapshot, x: fromX, y: fromY)
        let end = try screenshotToGlobalPoint(snapshot: snapshot, x: toX, y: toY)
        let startTarget = makeVisualCursorTarget(at: start, targetWindowID: snapshot.targetWindowID, targetWindowLayer: snapshot.targetWindowLayer)
        let endTarget = makeVisualCursorTarget(at: end, targetWindowID: snapshot.targetWindowID, targetWindowLayer: snapshot.targetWindowLayer)
        moveVisualCursor(to: startTarget)
        let path = try withVisualFeedback(.drag, at: startTarget, completingAt: endTarget) {
            try performDragEvent(
                from: start,
                to: end,
                targetDescription: "from=(\(fromX), \(fromY)) to=(\(toX), \(toY))",
                snapshot: snapshot,
                path: deliveryPath,
                flags: flags
            )
        }
        return appendingDragDeliveryNote(
            to: try actionResult(for: query, recoveryPolicy: recoveryPolicy),
            path: path
        )
    }

    func dragBetween(app query: String, sourceIndex: String?, destinationIndex: String?,
                     fromX: Double?, fromY: Double?, toX: Double?, toY: Double?,
                     modifiers: [String], options: DragOptions) throws -> ToolCallResult {
        try DragOptions.validateEndpoint(index: sourceIndex, x: fromX, y: fromY, name: "source")
        try DragOptions.validateEndpoint(index: destinationIndex, x: toX, y: toY, name: "destination")
        let flags = try dragModifierFlags(modifiers)
        let snapshot = try snapshotForAction(app: query,
            elementIndex: sourceIndex == nil || destinationIndex == nil ? nil : sourceIndex, recoveryPolicy: .readOnly)
        if snapshot.mode == .fixture {
            throw ComputerUseError.backgroundUnsupported(
                "The fixture drag supports four screenshot coordinates only. Omit drag_steps, hold_ms, verify, modifiers and element targets."
            )
        }
        guard let id = snapshot.targetWindowID, let bounds = snapshot.windowBounds,
              let window = snapshot.windowElement else {
            throw ComputerUseError.backgroundUnsupported("An element drag needs a readable native window.")
        }
        func endpoint(_ index: String?, _ x: Double?, _ y: Double?) throws -> (CGPoint, () throws -> Void) {
            if let index {
                let endpointSnapshot = try snapshotForAction(app: query, elementIndex: index, recoveryPolicy: .readOnly)
                guard endpointSnapshot.targetWindowID == id, endpointSnapshot.windowBounds == bounds,
                      let endpointWindow = endpointSnapshot.windowElement, CFEqual(endpointWindow, window) else {
                    throw ComputerUseError.invalidArguments("Drag endpoints must be in the same observed window.")
                }
                let record = try lookupElement(snapshot: endpointSnapshot, index: index)
                guard let local = localCenter(for: record) else {
                    throw ComputerUseError.stateUnavailable("Drag control has no readable frame.")
                }
                return (try windowPointToGlobalPoint(snapshot: snapshot, point: local), {
                    try self.validatePointerTarget(record, index: index, point: local, snapshot: endpointSnapshot)
                })
            }
            guard let x, let y, snapshot.observation.includeScreenshot,
                  let size = screenshotPixelSize(snapshot: snapshot),
                  CGRect(origin: .zero, size: size).contains(CGPoint(x: x, y: y)) else {
                throw ComputerUseError.stateUnavailable("Drag coordinates need an observed point inside the window screenshot.")
            }
            return (try screenshotToGlobalPoint(snapshot: snapshot, x: x, y: y), {})
        }
        let (start, checkStart) = try endpoint(sourceIndex, fromX, fromY)
        let (end, checkEnd) = try endpoint(destinationIndex, toX, toY)
        guard start != end else { throw ComputerUseError.invalidArguments("Drag endpoints must be distinct.") }
        let target = BackgroundDragTarget(start: inputEventPoint(fromScreenStatePoint: start),
            end: inputEventPoint(fromScreenStatePoint: end), windowBounds: bounds, windowID: id, pid: snapshot.app.pid)
        let visual = makeVisualCursorTarget(at: start, targetWindowID: id, targetWindowLayer: snapshot.targetWindowLayer)
        let finish = makeVisualCursorTarget(at: end, targetWindowID: id, targetWindowLayer: snapshot.targetWindowLayer)
        try withVisualFeedback(.drag, at: visual, completingAt: finish) {
            try BackgroundDragDispatcher.drag(target: target, flags: flags, steps: options.steps ?? 10, hold: options.hold,
                validateEndpoints: {
                    try checkStart()
                    try checkEnd()
                })
        }
        if let verified = try options.verifiedDrop({ try waitForControl(in: snapshot, wait: $0) }) {
            return .text(verified)
        }
        let state = try actionResult(for: query, recoveryPolicy: .readOnly)
        return ToolCallResult(content: [.text("Drag delivered. Use the resulting state to verify the drop.")] + state.content,
                              isError: state.isError)
    }

    public func typeText(app query: String, text: String, keyMethod: KeyMethod = .auto) throws -> ToolCallResult {
        let recovery: SnapshotRecoveryPolicy = backgroundOnlyMode() ? .readOnly : keyActionSnapshotRecoveryPolicy(for: keyMethod)
        let snapshot = try currentSnapshot(for: query, needScreenshot: false, recoveryPolicy: recovery)
        if snapshot.mode == .fixture {
            try requireAutoKeyMethodForFixture(keyMethod)
            try FixtureBridge.post(FixtureCommand(kind: "type_text", identifier: "fixture-input", value: text))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        if text.isEmpty { return try actionResult(for: query) }
        let target = snapshot.focusedElement.flatMap { focused in
            snapshot.elements.values.first { record in record.element.map { CFEqual($0, focused) } == true }
        }.flatMap { visualCursorTarget(for: $0, snapshot: snapshot) }
        return try withVisualFeedback(.typing, at: target) {
            try deliverText(app: query, text: text, keyMethod: keyMethod, snapshot: snapshot)
        }
    }

    private func deliverText(app query: String, text: String, keyMethod: KeyMethod, snapshot: AppSnapshot, autoFocused: Bool = false) throws -> ToolCallResult {
        if StrictBackground.enabled() {
            let focused: AXUIElement?
            if Self.requiredWindowID != nil {
                focused = try requireBoundInputFocus(in: snapshot)
            } else {
                focused = Self.currentInputFocus(pid: snapshot.app.pid)
            }
            guard keyMethod == .auto, let focused,
                  try typeTextUsingAccessibility(text, on: focused, pid: snapshot.app.pid) else {
                throw ComputerUseError.backgroundUnsupported("This field needs keyboard events or a focus change. Try set_value on an accessible field.")
            }
            if Self.requiredWindowID != nil { return .text("ok") }
            return try actionResult(for: query, recoveryPolicy: .readOnly)
        }
        if let windowID = Self.requiredWindowID {
            let focused = try requireBoundInputFocus(in: snapshot)
            if keyMethod == .auto, try typeTextUsingAccessibility(text, on: focused, pid: snapshot.app.pid) {
                return .text("ok")
            }
            guard canTypeTextUsingKeyboardFallback(on: focused) else {
                throw ComputerUseError.stateUnavailable("Focus an editable field in the observed window before typing.")
            }
            try requireCurrentTextFocus(focused, pid: snapshot.app.pid)
            try InputSimulation.typeTextWithSkyLight(text, windowID: windowID, pid: snapshot.app.pid)
            return .text("ok")
        }

        if keyMethod == .skyKey, !Self.awaitsModalTextFocus {
            let target = try skyKeyTarget(for: snapshot)
            // Keys go to whatever has focus: refuse unless it is the field the snapshot showed.
            let focused = Self.focusedElement(pid: target.pid)
            try requireKeyboardFocusMatchesRead(focused, snapshot: snapshot)
            if let focused {
                try selectWholeNameForKeys(text: text, focused: focused, pid: target.pid, windowID: target.windowID)
            }
            try InputSimulation.typeTextWithSkyLight(text, windowID: target.windowID, pid: target.pid)
            return try actionResult(for: query, recoveryPolicy: keyActionSnapshotRecoveryPolicy(for: keyMethod))
        }

        // A dialog shortcut can return before the sheet exposes its editor.
        let focused: AXUIElement?
        if Self.awaitsModalTextFocus {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            var editor: AXUIElement?
            repeat {
                if let candidate = Self.currentInputFocus(pid: snapshot.app.pid, requireModal: true),
                   canTypeTextUsingKeyboardFallback(on: candidate) {
                    editor = candidate
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard let editor else {
                throw FocusBorrow.focusRequiredError(
                    "The Go to Folder dialog did not expose a focused text field. Read the dialog before retrying.",
                    pid: snapshot.app.pid, unsent: false)
            }
            // Keys go to this editor, so it must belong to the window that was read. (An unnamed sheet is expected here:
            // this path exists to type into the one dialog the batch opened.)
            if let refusal = Self.modalEditorRefusal(
                readWindowID: snapshot.targetWindowID.map { Int($0) },
                observedWindowID: Self.observedWindowID(of: editor, expectedWindow: snapshot.windowElement, expectedID: snapshot.targetWindowID)) {
                throw refusal
            }
            focused = editor
        } else {
            focused = Self.currentInputFocus(pid: snapshot.app.pid)
        }
        guard let focused else {
            // Nothing has focus, but the window has exactly one place to type: focus it and type there.
            if !autoFocused, focusSoleEditableTextElement(in: snapshot) {
                return try withAutoFocusNote(deliverText(app: query, text: text, keyMethod: keyMethod, snapshot: snapshot, autoFocused: true))
            }
            // A background calculator has no focused element at all; its keypad still takes keys.
            if try typeOnKeypad(text, snapshot: snapshot, focused: nil) {
                pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
                return try actionResult(for: query)
            }
            throw FocusBorrow.focusRequiredError(focusedElementUnreadableMessage, pid: snapshot.app.pid)
        }
        if keyMethod == .auto, try typeTextUsingAccessibility(text, on: focused, pid: snapshot.app.pid) {
            pauseBeforeReadBack(0.1, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
            return try actionResult(for: query)
        }

        guard canTypeTextUsingKeyboardFallback(on: focused) else {
            // Nothing editable has focus (Calculator's keypad, a canvas, a game): send the text as key presses to the
            // app's window, as a person typing would. The SkyLight route reaches a background window too.
            // Only where loose keys are safe: plain characters (no Return or Tab, which press default buttons),
            // not inside a web page (letters are shortcuts there), into the window that holds the focus now.
            // First: a window with exactly one place to type gets the text there (the most common miss in real
            // sessions was typing with a button or list focused while the window had a single text area).
            if !autoFocused, focusSoleEditableTextElement(in: snapshot) {
                return try withAutoFocusNote(deliverText(app: query, text: text, keyMethod: keyMethod, snapshot: snapshot, autoFocused: true))
            }
            guard try typeOnKeypad(text, snapshot: snapshot, focused: focused) else {
                throw FocusBorrow.focusRequiredError(
                    "type_text requires a focused editable text element. Click a text entry area first, or use set_value on a settable text element.",
                    pid: snapshot.app.pid)
            }
            pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
            let result = try actionResult(for: query)
            return ToolCallResult(
                content: [.text("No text field had focus, so the text went to the window as key presses.")] + result.content,
                isError: result.isError
            )
        }

        try requireCurrentTextFocus(focused, pid: snapshot.app.pid)
        // A modal editor (Go to Folder) is picked above from its own focus, so only the plain path is checked here.
        if !Self.awaitsModalTextFocus { try requireKeyboardFocusMatchesRead(focused, snapshot: snapshot) }
        let isSecure = isSecureTextField(subrole: stringValue(of: focused, attribute: kAXSubroleAttribute))
        let before = isSecure ? nil : stringValue(of: focused, attribute: kAXValueAttribute)
        if keyMethod == .skyKey || useSkyLightKeyRoute(snapshot: snapshot, focused: focused, opensDialogFromMenu: false, hasLiveTextFocus: true) {
            // Keys posted to a background process reach only a window that is key; the key-window route makes it key.
            // This is the default whenever the app is not in front (not only in background-only mode); a borrowed
            // app, a save/open sheet and Finder's rename editor take the normal route below, which is also what a
            // retry with focus borrowed uses when these keys had no effect.
            let windowID = try backgroundKeyboardWindow(for: snapshot, action: "type_text", focused: focused)
            try selectWholeNameForKeys(text: text, focused: focused, pid: snapshot.app.pid, windowID: windowID)
            try InputSimulation.typeTextWithSkyLight(text, windowID: windowID, pid: snapshot.app.pid)
        } else {
            try selectWholeNameForKeys(text: text, focused: focused, pid: snapshot.app.pid, windowID: nil)
            try InputSimulation.typeText(text, pid: snapshot.app.pid)
        }
        pauseBeforeReadBack(0.1, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
        let after = isSecure ? nil : stringValue(of: focused, attribute: kAXValueAttribute)
        // Keys that never reached the field leave its text as it was: say so instead of reporting a success.
        // Without read-back nothing settles before this read, so the comparison would be unreliable.
        if actionReadBack, typedTextWasNotApplied(before: before, after: after, text: text, isSecureField: isSecure) {
            throw FocusBorrow.focusRequiredError(typedTextNotAppliedMessage, pid: snapshot.app.pid, unsent: false)
        }
        return try actionResult(for: query)
    }

    /// Keys for a rename's full new name go over the whole old name: ⌘A first, when the typed text is a name with the
    /// same extension typed over a selection that leaves the extension out. Otherwise the keys would make "name.txt.txt".
    /// `windowID` is set on the background route, where keys reach only the key window.
    private func selectWholeNameForKeys(text: String, focused: AXUIElement, pid: pid_t, windowID: CGWindowID?) throws {
        guard replacesWholeName(of: focused, pid: pid, text: text) else { return }
        if let windowID {
            try InputSimulation.pressKeyWithSkyLight("cmd+a", windowID: windowID, pid: pid)
        } else {
            try InputSimulation.pressKey("cmd+a", pid: pid)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Whether keys for `snapshot`'s app go through the SkyLight key route instead of the frontmost/borrowed one.
    private func useSkyLightKeyRoute(
        snapshot: AppSnapshot, focused: AXUIElement?, opensDialogFromMenu: Bool, hasLiveTextFocus: Bool = false
    ) -> Bool {
        let pid = snapshot.app.pid
        return shouldRouteKeysThroughSkyLight(KeyRouteContext(
            backgroundOnly: backgroundOnlyMode(),
            targetIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            borrowed: FocusBorrow.isBorrowed(pid: pid),
            skyLightAvailable: SkyLightSPI.shared.capability.isAvailable,
            hasTargetWindow: snapshot.targetWindowID != nil || hasLiveTextFocus,
            bundleIdentifier: snapshot.app.bundleIdentifier,
            focusInSheetOrDialog: focused.map(Self.isInsideSheetOrDialog) ?? false,
            opensDialogFromMenu: opensDialogFromMenu
        ))
    }

    /// The window a background-only keyboard route delivers to. Fails with the working route when
    /// the window is unknown or the private key-window support is missing.
    private func backgroundKeyboardWindow(for snapshot: AppSnapshot, action: String, focused: AXUIElement? = nil) throws -> CGWindowID {
        let windowID: CGWindowID?
        if let focused {
            // The last snapshot may describe the window under a newly opened panel.
            windowID = SkyLightSPI.shared.windowID(for: focused)
                ?? Self.elementAttribute(focused, kAXWindowAttribute).flatMap { SkyLightSPI.shared.windowID(for: $0) }
        } else {
            windowID = snapshot.targetWindowID
        }
        guard let windowID else {
            throw ComputerUseError.stateUnavailable("\(action) needs an on-screen target window in background-only mode. Run get_app_state again.")
        }
        let capability = SkyLightSPI.shared.capability
        guard capability.isAvailable else {
            throw ComputerUseError.stateUnavailable(backgroundKeyUnavailableMessage(action: action, reason: capability.unavailableReason))
        }
        return windowID
    }

    /// Types `text` as single key presses into a keypad app (a calculator): only there, and only the characters
    /// a keypad takes. Anywhere else loose keys do other things: in a Finder list they select a file by name,
    /// and a following Return renames it. False when this is not such a case or the keys could not be sent.
    private func typeOnKeypad(_ text: String, snapshot: AppSnapshot, focused: AXUIElement?) throws -> Bool {
        guard !text.isEmpty, text.allSatisfy({ "0123456789+-*/=.,%()^ ".contains($0) }) else { return false }
        let buttonNames = snapshot.elements.values.flatMap { record -> [String] in
            guard SmartSteps.roleKey(record.role) == "button" else { return [] }
            return [record.title, record.identifier, record.identity?.name].compactMap { $0?.lowercased().filter { !$0.isWhitespace } }
        }
        guard LabelSpellings.isKeypad(buttonNames: buttonNames) else { return false }
        if let focused, Self.isInsideWebArea(focused) { return false }
        guard let windowID = focused.flatMap({ SkyLightSPI.shared.windowID(for: $0) }) ?? snapshot.targetWindowID,
              SkyLightSPI.shared.capability.isAvailable else { return false }
        let keys = text.filter { $0 != " " }
        guard !keys.isEmpty else { return false }
        try SkyKeyboardDispatcher.typeKeypad(
            target: SkyKeyboardTarget(windowID: windowID, pid: snapshot.app.pid), keys: keys
        )
        return true
    }

    /// Whether the element sits in web content (a browser page, an Electron app's view).
    private static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return false }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == "AXWebArea" { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    /// Pure gate for keyboard text: nil when the observed focus is the field the snapshot showed (FocusTransition
    /// `.ok`), otherwise the notSent refusal. Unknown focus on either side is refused too: unknown means do not type.
    static func keyboardFocusRefusal(read: ObservedFocus, observed: ObservedFocus) -> ComputerUseError? {
        guard let role = read.elementRole, let label = read.label, let readWindow = read.windowID else {
            return .notSent("Typing would go to an unknown control; read the app and target the field.")
        }
        // The read's sheet or dialog (nil when the read showed none) is what the observed focus must sit in.
        let target = FocusTarget(windowID: readWindow, elementRole: role, label: label, dialogTitle: read.dialogTitle)
        switch FocusTransition.check(target: target, observed: observed) {
        case .ok:
            return nil
        case .unexpectedDialog:
            return .notSent("Typing would go to a sheet or dialog that the read did not show; read the app and target the field.")
        case .wrongWindow, .wrongElement, .unknown:
            let seen = observed.label ?? observed.elementRole ?? "an unknown control"
            return .notSent("Typing would go to \(seen); read the app and target the field.")
        }
    }

    /// Pure gate for the modal editor path (Go to Folder), which types by keys without a read of its own: the editor
    /// must sit in the window that was read or pinned. Unknown on either side is refused.
    static func modalEditorRefusal(readWindowID: Int?, observedWindowID: Int?) -> ComputerUseError? {
        guard let readWindowID, let observedWindowID, readWindowID == observedWindowID else {
            return .notSent("The dialog's text field is not in the window that was read; read the app and target the field.")
        }
        return nil
    }

    /// The window the focused element sits in, as the read's window id. The walk up the accessibility tree reaches the
    /// read window (sheets hang off it), so a sheet over the read window still counts. Nil when the window cannot be named.
    static func observedWindowID(of focused: AXUIElement, expectedWindow: AXUIElement?, expectedID: CGWindowID?) -> Int? {
        var node: AXUIElement? = focused
        for _ in 0..<40 {
            guard let current = node else { break }
            if let expectedWindow, CFEqual(current, expectedWindow) { return expectedID.map { Int($0) } }
            node = elementAttribute(current, kAXParentAttribute)
        }
        return elementAttribute(focused, kAXWindowAttribute).flatMap { SkyLightSPI.shared.windowID(for: $0) }.map { Int($0) }
    }

    /// The title of the sheet or dialog that `focused` sits in, or the first sheet of `window`; "" when that sheet has
    /// no title. Nil when no sheet or dialog is in front. The window itself is never a dialog here.
    static func frontDialogTitle(focused: AXUIElement?, window: AXUIElement?) -> String? {
        var node = focused
        for _ in 0..<40 {
            guard let current = node else { break }
            if let window, CFEqual(current, window) { break }
            let role = copyStringAttribute(current, kAXRoleAttribute)
            let subrole = copyStringAttribute(current, kAXSubroleAttribute)
            if role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                return (copyStringAttribute(current, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            node = elementAttribute(current, kAXParentAttribute)
        }
        if let window {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &value) == .success,
               let sheets = value as? [AXUIElement], let sheet = sheets.first {
                return (copyStringAttribute(sheet, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Checks the focus that is about to get keys (sky_key and the keyboard fallback) against the snapshot's focus.
    private func requireKeyboardFocusMatchesRead(_ focused: AXUIElement?, snapshot: AppSnapshot) throws {
        func describe(_ element: AXUIElement) -> (role: String?, label: String?) {
            (stringValue(of: element, attribute: kAXRoleAttribute), accessibilityLabels(for: element).first)
        }
        let read = snapshot.focusedElement.map(describe)
        // The read's own window and dialog: the window read or pinned, and any sheet the read listed (by its role).
        let readDialog = snapshot.elements.values
            .first { SmartSteps.dialogRoles.contains(SmartSteps.roleKey($0.role)) }
            .map { ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let now = focused.map(describe)
        // The focus now: the window it sits in (not the read's window by assumption), and any sheet or dialog in front
        // of that window, named or not.
        let observedWindow = focused.flatMap {
            Self.observedWindowID(of: $0, expectedWindow: snapshot.windowElement, expectedID: snapshot.targetWindowID)
        }
        let observedDialog = Self.frontDialogTitle(focused: focused, window: snapshot.windowElement)
        if let refusal = Self.keyboardFocusRefusal(
            read: ObservedFocus(windowID: snapshot.targetWindowID.map { Int($0) }, elementRole: read?.role, label: read?.label,
                                dialogTitle: readDialog),
            observed: ObservedFocus(windowID: observedWindow, elementRole: now?.role, label: now?.label,
                                    dialogTitle: observedDialog)) {
            throw refusal
        }
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        var focused: CFTypeRef?
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AppTiming.messagingTimeout(pid: pid, fixed: 0.2))
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func currentInputFocus(pid: pid_t, requireModal: Bool = false) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AppTiming.messagingTimeout(pid: pid, fixed: 0.2))
        let appFocus = elementAttribute(app, kAXFocusedUIElementAttribute)
        guard let window = elementAttribute(app, kAXFocusedWindowAttribute) else { return requireModal ? nil : appFocus }

        // A sheet can own the editor while the app reports focus beneath it. Only use
        // focus exposed by the AX hierarchy, and require membership in the active sheet.
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, "AXSheets"]
        var rawAttributes: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, attributes as CFArray, [], &rawAttributes) == .success,
              let values = rawAttributes as? [Any], values.count == attributes.count else { return nil }
        let role = values[0] as? String
        let subrole = values[1] as? String
        let sheets = values[2] as? [AXUIElement] ?? []
        let modal: AXUIElement?
        if role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
            modal = window
        } else {
            guard sheets.count <= 1 else { return nil }
            modal = sheets.first
        }
        if let modal {
            let modalFocus = elementAttribute(modal, kAXFocusedUIElementAttribute)
            return [modalFocus, appFocus].compactMap { $0 }.first { candidate in
                guard !CFEqual(candidate, modal) else { return false }
                var owner: pid_t = 0
                guard AXUIElementGetPid(candidate, &owner) == .success, owner == pid else { return false }
                var ancestor = elementAttribute(candidate, kAXParentAttribute)
                for _ in 0..<40 {
                    guard let node = ancestor else { return false }
                    if CFEqual(node, modal) { return true }
                    ancestor = elementAttribute(node, kAXParentAttribute)
                }
                return false
            }
        }
        return requireModal ? nil : appFocus
    }

    /// "Command+Shift+N", "META+SHIFT+N", "⌘⇧N" → "cmd+shift+n": modifiers by one name, in a fixed order.
    static func canonicalKey(_ key: String) -> String {
        let spaced = key.lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+").replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌥", with: "alt+").replacingOccurrences(of: "⌃", with: "ctrl+")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "+")
        let names: [String: String] = [
            "command": "cmd", "super": "cmd", "meta": "cmd", "win": "cmd", "option": "alt", "opt": "alt", "control": "ctrl",
            "arrowdown": "down", "down_arrow": "down", "downarrow": "down", "arrowup": "up", "up_arrow": "up", "uparrow": "up",
            "bracketleft": "[", "leftbracket": "[", "enter": "return", "esc": "escape",
        ]
        var parts = spaced.split(separator: "+", omittingEmptySubsequences: true).map { names[String($0)] ?? String($0) }
        if spaced.hasSuffix("++") || spaced == "+" { parts.append("+") }
        let modifiers = ["alt", "cmd", "ctrl", "shift"]
        let mods = parts.filter { modifiers.contains($0) }.sorted()
        let rest = parts.filter { !modifiers.contains($0) }
        return (mods + rest).joined(separator: "+")
    }

    /// ⌘A and ⌘S done through the app itself: a background app's menu leaves Select All and Save disabled, so
    /// the keys did nothing. Select All sets the text selection directly; Save uses the app's scripting when
    /// the document already has a file. Nil when neither applies (the key then goes the normal way).
    private func pressKeyDirectly(_ key: String, snapshot: AppSnapshot, query: String) throws -> ToolCallResult? {
        let normalized = Self.canonicalKey(key)
        if PrivateClipboard.Action(key: key) == nil,
           NSRunningApplication(processIdentifier: snapshot.app.pid)?.bundleIdentifier == "com.apple.finder",
           let message = try FinderClipboard.handle(key: normalized) {
            return insertingNote(message, into: try actionResult(for: query))
        }
        func isText(_ element: AXUIElement) -> Bool {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            return [kAXTextAreaRole as String, kAXTextFieldRole as String, "AXComboBox", "AXSearchField"].contains(role as? String ?? "")
        }
        if normalized == "cmd+a",
           let target = Self.currentInputFocus(pid: snapshot.app.pid), isText(target),
           !isSecureTextField(subrole: stringValue(of: target, attribute: kAXSubroleAttribute)) {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &raw) == .success,
                  let text = raw as? String else { return nil }
            var whole = CFRange(location: 0, length: (text as NSString).length)
            guard isSettable(element: target, attribute: kAXSelectedTextRangeAttribute),
                  let range = AXValueCreate(.cfRange, &whole) else { return nil }
            try requireCurrentTextFocus(target, pid: snapshot.app.pid)
            let result = AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, range)
            guard result == .success,
                  let applied = selectedRange(of: target), applied.location == 0, applied.length == whole.length else {
                throw ComputerUseError.stateUnavailable("Select All could not verify the text selection. Read the app state before retrying.")
            }
            return insertingNote("Selected all text (\(whole.length) characters); typing now replaces it.", into: try actionResult(for: query))
        }
        if normalized == "cmd+s", let bundle = NSRunningApplication(processIdentifier: snapshot.app.pid)?.bundleIdentifier,
           ["com.apple.TextEdit", "com.apple.Preview", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote"].contains(bundle),
           let path = AppleEventsGate.run("tell application id \"\(bundle)\" to get path of document 1", bundle: bundle)?.stringValue, !path.isEmpty,
           try AppleEventsGate.send("tell application id \"\(bundle)\" to save document 1", bundle: bundle) != nil {
            return insertingNote("Saved \(path).", into: try actionResult(for: query))
        }
        return nil
    }

    private func nativeClipboard(
        _ action: PrivateClipboard.Action, snapshot: AppSnapshot, query: String, keyMethod: KeyMethod
    ) throws -> ToolCallResult {
        if Self.requiredWindowID != nil { try requireBoundFocusedWindow(in: snapshot) }
        let clipboard = PrivateClipboard.current
        // Finder file copy/cut/paste is implemented through Finder scripting because
        // background keyboard events cannot reliably target a non-key Finder window.
        // A pinned window is still safe: requireBoundFocusedWindow above verified that
        // the supplied window is the current Finder target before resolving its selection.
        if snapshot.app.bundleIdentifier == "com.apple.finder" {
            let key: String?
            switch (action, clipboard.payload) {
            case (.copy, _): key = "cmd+c"
            case (.cut, _): key = "cmd+x"
            case (.paste, .files): key = "cmd+v"
            case (.moveFiles, .files): key = "alt+cmd+v"
            default: key = nil
            }
            if let key {
                guard let message = try FinderClipboard.handle(key: key) else {
                    throw ComputerUseError.stateUnavailable("Finder could not complete the private clipboard action. Check the selection or destination before retrying.")
                }
                return .text(message)
            }
        }
        switch action {
        case .moveFiles:
            throw ComputerUseError.invalidArguments("Move-paste requires files on the private clipboard and a Finder destination.")
        case .paste:
            let text = try clipboard.textForPaste()
            if text.isEmpty { return .text("Private clipboard text is empty.") }
            return try typeText(app: query, text: text, keyMethod: keyMethod)
        case .copy, .cut:
            let focus = Self.requiredWindowID != nil
                ? try requireBoundInputFocus(in: snapshot) : Self.currentInputFocus(pid: snapshot.app.pid)
            guard let focus,
                  !isSecureTextField(subrole: stringValue(of: focus, attribute: kAXSubroleAttribute)),
                  let selected = stringValue(of: focus, attribute: kAXSelectedTextAttribute), !selected.isEmpty else {
                throw ComputerUseError.invalidArguments("No accessible text is selected. Select ordinary text first.")
            }
            if action == .copy {
                try clipboard.writeText(selected)
                return .text("Copied selected text to the private clipboard.")
            }
            guard keyMethod == .auto,
                  isSettable(element: focus, attribute: kAXSelectedTextAttribute),
                  let original = stringValue(of: focus, attribute: kAXValueAttribute),
                  let range = selectedRange(of: focus),
                  let change = typedTextReplacement(value: original, selection: range, text: ""),
                  let selectionRange = Range(NSRange(location: range.location, length: range.length), in: original),
                  original[selectionRange].utf16.elementsEqual(selected.utf16) else {
                throw ComputerUseError.invalidArguments("This selection cannot be cut through accessibility. Copy it to the private clipboard instead.")
            }
            try requireCurrentTextFocus(focus, pid: snapshot.app.pid)
            guard stringValue(of: focus, attribute: kAXValueAttribute)?.utf16.elementsEqual(original.utf16) == true,
                  let current = selectedRange(of: focus), current.location == range.location, current.length == range.length else {
                throw ComputerUseError.stateUnavailable("The selected text changed before cut. Nothing was sent.")
            }
            try clipboard.writeText(selected)
            guard AXUIElementSetAttributeValue(focus, kAXSelectedTextAttribute as CFString, "" as CFString) == .success,
                  stringValue(of: focus, attribute: kAXValueAttribute)?.utf16.elementsEqual(change.value.utf16) == true else {
                throw ComputerUseError.stateUnavailable("The private clipboard has the text, but deletion may have taken effect. Check the field before retrying.")
            }
            return .text("Cut selected text to the private clipboard.")
        }
    }

    func holdKey(app query: String, key: String, method: KeyMethod, hold: TimeInterval) throws -> ToolCallResult {
        let parsed = try KeyPressParser.parse(key)
        guard PrivateClipboard.Action(key: key) == nil else {
            throw ComputerUseError.backgroundUnsupported("Clipboard shortcuts use the private clipboard and cannot be held.")
        }
        guard method == .auto else {
            throw ComputerUseError.backgroundUnsupported("Held keys need the observed Mac window to already have focus.")
        }
        let snapshot = try currentSnapshot(for: query, needScreenshot: false, recoveryPolicy: .readOnly)
        guard let id = snapshot.targetWindowID, let window = snapshot.windowElement, snapshot.mode != .fixture else {
            throw ComputerUseError.backgroundUnsupported("Held keys need the observed Mac window to already have focus.")
        }
        let io = BackgroundDragIO.system()
        let validate = {
            try requireUsableComputerUseSession()
            guard !FocusBorrow.isBorrowed(pid: snapshot.app.pid), !(try io.needsFocus(snapshot.app.pid)) else {
                throw ComputerUseError.backgroundUnsupported("Held keys need the observed Mac window to already have focus.")
            }
            let live = try SnapshotBuilder.resolveTargetWindow(for: snapshot.app, windowID: id)
            guard CFEqual(window, live.windowElement), live.windowBounds == snapshot.windowBounds else {
                throw self.windowBindingError(id)
            }
            try Self.$requiredWindowID.withValue(id) { try self.requireBoundFocusedWindow(in: snapshot) }
        }
        try ActionOptions.requireTime(for: hold + 0.3)
        let pid = snapshot.app.pid
        let launch = snapshot.app.runningApplication.launchDate
        try InputSimulation.deliverHeldKey(parsed, hold: hold, validate: validate, post: { $0.postToPid(pid) }, release: { event in
            if let process = NSRunningApplication(processIdentifier: pid), !process.isTerminated, process.launchDate == launch {
                event.postToPid(pid)
            }
        })
        return .text("Held \(key) for \(Int((hold * 1000).rounded())) ms and released.")
    }

    public func pressKey(app query: String, key: String, keyMethod: KeyMethod = .auto) throws -> ToolCallResult {
        let recoveryPolicy = backgroundOnlyMode() ? .readOnly : keyActionSnapshotRecoveryPolicy(for: keyMethod)
        let snapshot = try currentSnapshot(for: query, needScreenshot: false, recoveryPolicy: recoveryPolicy)
        if let action = PrivateClipboard.Action(key: key) {
            return try nativeClipboard(action, snapshot: snapshot, query: query, keyMethod: keyMethod)
        }
        if let windowID = Self.requiredWindowID {
            try requireBoundFocusedWindow(in: snapshot)
            if keyMethod == .auto, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.app.pid {
                try InputSimulation.pressKey(key, pid: snapshot.app.pid)
            } else {
                try SkyKeyboardDispatcher.pressKey(
                    target: SkyKeyboardTarget(windowID: windowID, pid: snapshot.app.pid),
                    key: key,
                    allowMenuEquivalent: false
                )
            }
            return .text("ok")
        }
        if snapshot.mode != .fixture, let direct = try pressKeyDirectly(key, snapshot: snapshot, query: query) {
            return direct
        }
        if snapshot.mode == .fixture {
            try requireAutoKeyMethodForFixture(keyMethod)
            try FixtureBridge.post(FixtureCommand(kind: "press_key", identifier: "fixture-key-capture", value: key))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        if keyMethod == .skyKey {
            let target = try skyKeyTarget(for: snapshot)
            let reportedDisabled = try InputSimulation.pressKeyWithSkyLight(key, windowID: target.windowID, pid: target.pid)
            let result = try actionResult(for: query, recoveryPolicy: recoveryPolicy)
            return reportedDisabled ? insertingNote(disabledMenuKeyNote, into: result) : result
        }

        if keyMethod == .auto,
           useSkyLightKeyRoute(
               snapshot: snapshot,
               focused: Self.focusedElement(pid: snapshot.app.pid),
               opensDialogFromMenu: backgroundOnlyMode() ? false
                   : (SkyKeyboardDispatcher.menuItemTitle(forKey: key, pid: snapshot.app.pid)
                       .map(FocusBorrow.menuTitleOpensDialog) ?? false)
           ) {
            // A raw key event to a background window that is not key is dropped silently. A command
            // chord that a menu item names is pressed as that item instead; anything else goes through
            // the key-window route, which makes the window key for the event and then puts focus back.
            switch try SkyKeyboardDispatcher.pressMenuKeyEquivalent(key, pid: snapshot.app.pid) {
            case .pressed(let reportedDisabled):
                pauseBeforeReadBack(0.1, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
                let result = try actionResult(for: query, recoveryPolicy: .readOnly)
                return reportedDisabled ? insertingNote(disabledMenuKeyNote, into: result) : result
            case .notAMenuItem:
                break
            }
            let windowID = try backgroundKeyboardWindow(for: snapshot, action: "press_key '\(key)'")
            try InputSimulation.pressKeyWithSkyLight(key, windowID: windowID, pid: snapshot.app.pid)
            return try actionResult(for: query, recoveryPolicy: .readOnly)
        }

        try InputSimulation.pressKey(key, pid: snapshot.app.pid)
        // The key is delivered; how long the app takes to show its effect only matters to
        // the read-back, so that wait is frame-driven and skipped when nothing is read.
        pauseBeforeReadBack(0.1, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
        return try actionResult(for: query)
    }

    /// A menu bar command by its path, pressed through accessibility. It needs no window or
    /// snapshot: an app with no window shown still has its menus. The press itself is the
    /// action, so a window that cannot be read back afterwards is not an error.
    public func pressMenu(app query: String, path: String) throws -> ToolCallResult {
        try pressMenu(app: query, titles: try menuPathTitles(path))
    }

    /// The same press with the path already split into titles. Background-only safe: the
    /// lookup and AXPress never activate, raise or move the pointer, so no mode check is needed.
    /// The reply is one line, so a batch can show it without the whole app state.
    func finderFileCommand(app query: String, titles: [String], path: String, newName: String?) throws -> ToolCallResult {
        let menu = try menuPathTitles(titles).map { $0.lowercased() }
        let renaming = menu == ["file", "rename"]
        guard renaming || menu == ["file", "duplicate"], path.hasPrefix("/"), Self.requiredWindowID == nil,
              renaming == (newName != nil) else {
            throw ComputerUseError.invalidArguments("Use file_path for Finder File > Duplicate or File > Rename, without a window pin. Rename also needs new_name.")
        }
        try requireUsableComputerUseSession()
        guard try AppDiscovery.resolveRunning(query).bundleIdentifier == "com.apple.finder" else {
            throw ComputerUseError.invalidArguments("Only Finder File > Duplicate and File > Rename support file_path.")
        }
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let folder = source.deletingLastPathComponent()
        guard let properties = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw ComputerUseError.notSent("The requested Finder source is not a regular file.")
        }
        let body: String
        let action: String
        if let newName {
            guard !newName.isEmpty, newName != ".", newName != "..", newName.utf8.count <= 255,
                  !newName.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline || $0 == "\0" }) else {
                throw ComputerUseError.invalidArguments("new_name must be a plain filename in the source folder.")
            }
            let destination = folder.appendingPathComponent(newName)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ComputerUseError.notSent("The destination already exists. Nothing was renamed.")
            }
            body = """
            if exists item \(FinderRename.quoted(newName)) of (container of sourceItem) then return "destination-exists"
            set name of sourceItem to \(FinderRename.quoted(newName))
            return POSIX path of (sourceItem as alias)
            """
            action = "Renamed"
        } else {
            body = """
            set copiedItem to duplicate sourceItem
            return POSIX path of (copiedItem as alias)
            """
            action = "Duplicated"
        }
        let script = """
        tell application id "com.apple.finder"
            set sourceItem to (POSIX file \(FinderRename.quoted(source.path))) as alias
            \(body)
        end tell
        """
        guard let reply = try AppleEventsGate.send(script, bundle: "com.apple.finder") else {
            throw ComputerUseError.notSent("Finder automation permission is required for this path-based command.")
        }
        if reply.stringValue == "destination-exists" {
            throw ComputerUseError.notSent("The destination already exists. Nothing was renamed.")
        }
        if let newName, let originalID = properties.fileResourceIdentifier as? NSObject {
            let expected = folder.appendingPathComponent(newName)
            if let result = try? expected.resourceValues(forKeys: [.fileResourceIdentifierKey]),
               let copiedID = result.fileResourceIdentifier as? NSObject,
               originalID.isEqual(copiedID), !FileManager.default.fileExists(atPath: source.path) {
                return .text("Renamed in Finder: \(expected.path)", deliveryState: .verified)
            }
        }
        if let returnedPath = reply.stringValue, returnedPath.hasPrefix("/") {
            let result = URL(fileURLWithPath: returnedPath).standardizedFileURL
            if result != source, result.deletingLastPathComponent() == folder,
               FileManager.default.fileExists(atPath: result.path),
               newName.map({ result.lastPathComponent == $0 && !FileManager.default.fileExists(atPath: source.path) }) ?? true {
                return .text("\(action) in Finder: \(result.path)", deliveryState: .verified)
            }
        }
        throw ComputerUseError.acknowledged("Finder accepted the command, but the result could not be verified. Check the source folder before retrying.")
    }

    public func pressMenu(app query: String, titles: [String]) throws -> ToolCallResult {
        let titles = try menuPathTitles(titles)
        if let item = titles.last?.lowercased(), let key = [
            "copy": "cmd+c", "cut": "cmd+x", "paste": "cmd+v", "paste and match style": "cmd+shift+v",
            "paste and match formatting": "cmd+shift+v"
        ][item] {
            return try pressKey(app: query, key: key)
        }
        try requireUsableComputerUseSession()
        let app = try AppDiscovery.resolveRunning(query)
        // Finder's selection commands are disabled in a background Finder's menus; its scripting does them.
        if NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier == "com.apple.finder",
           let last = titles.last?.lowercased().replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces) {
            let script: String? = [
                "new folder": "tell application id \"com.apple.finder\"\nset f to make new folder at (target of Finder window 1)\nselect f\nreturn name of f\nend tell",
                "duplicate": "tell application id \"com.apple.finder\" to set made to duplicate (get selection)\nreturn count of made",
                "move to trash": "tell application id \"com.apple.finder\" to set gone to delete (get selection)\nreturn count of gone",
            ][last]
            if let script, let reply = try AppleEventsGate.send(script, bundle: "com.apple.finder") {
                if last == "duplicate", reply.int32Value == 0 {
                    throw ComputerUseError.acknowledged(
                        "Finder reported no duplicates. Read the folder and confirm the intended file is selected before trying again."
                    )
                }
                return .text("pressed \(titles.joined(separator: " > ")) (done through Finder on the selected items)")
            }
        }
        // File > Save is disabled in a background document app's menu; its scripting saves the document.
        if titles.count == 2, titles[0].lowercased() == "file", titles[1].lowercased() == "save",
           let bundle = NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier,
           ["com.apple.TextEdit", "com.apple.Preview", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote"].contains(bundle),
           let path = AppleEventsGate.run("tell application id \"\(bundle)\" to get path of document 1", bundle: bundle)?.stringValue, !path.isEmpty,
           try AppleEventsGate.send("tell application id \"\(bundle)\" to save document 1", bundle: bundle) != nil {
            return .text("pressed File > Save (saved \(path))")
        }
        // Learned shortcut (AdaptiveLearning): an item whose key equivalent an earlier press confirmed is pressed by that
        // chord, with no key event. The chord must still name the same item; any doubt falls through to the menu.
        let joined = titles.joined(separator: " > ")
        let learning = AdaptiveLearning.shared
        let appKey = AdaptiveLearning.appKey(for: app)
        if case .shortcut(let chord) = learning.shortcuts.route(app: appKey, path: joined, strict: StrictBackground.enabled()),
           let last = titles.last,
           SkyKeyboardDispatcher.menuItemTitle(forKey: chord, pid: app.pid).map({ AdaptiveLearning.sameTitle($0, last) }) == true,
           case .pressed(let disabled) = try SkyKeyboardDispatcher.pressMenuKeyEquivalent(chord, pid: app.pid) {
            return .text("pressed \(joined)" + (disabled ? " (the closed menu listed it as disabled; check the state to see whether it ran)" : ""))
        }
        SkyKeyboardDispatcher.lastPressReportedDisabled = false
        let keyEquivalent = try SkyKeyboardDispatcher.pressMenuItem(path: titles, pid: app.pid)
        let note = SkyKeyboardDispatcher.lastPressReportedDisabled
            ? " (the closed menu listed it as disabled; check the state to see whether it ran)" : ""
        // Only a press that did not report disabled confirms the shortcut; the next press of this path may use it.
        if let keyEquivalent, !SkyKeyboardDispatcher.lastPressReportedDisabled, let last = titles.last {
            learning.shortcuts.parse(app: appKey, items: [.init(path: joined, title: last,
                commandCharacter: keyEquivalent.commandCharacter, modifierMask: keyEquivalent.modifierMask)])
            learning.shortcuts.confirm(app: appKey, path: joined)
            learning.saveShortcuts()
        }
        return .text("pressed \(joined)\(note)")
    }

    private func requireAutoKeyMethodForFixture(_ keyMethod: KeyMethod) throws {
        guard keyMethod == .auto else {
            throw ComputerUseError.message(
                "key_method '\(keyMethod.rawValue)' is not supported for fixture apps"
            )
        }
    }

    private func skyKeyTarget(for snapshot: AppSnapshot) throws -> SkyKeyboardTarget {
        guard let windowID = snapshot.targetWindowID else {
            throw ComputerUseError.stateUnavailable(
                "key_method 'sky_key' requires a current on-screen target window. Run get_app_state again."
            )
        }

        return SkyKeyboardTarget(windowID: windowID, pid: snapshot.app.pid)
    }

    func handoffMatchesDocument(app: String, windowID: UInt32, path: String) -> Bool {
        guard let snapshot = snapshotsByApp[app.lowercased()], snapshot.observedWindowID == windowID,
              let window = snapshot.windowElement,
              let actual = stringValue(of: window, attribute: kAXDocumentAttribute) else { return false }
        let documentURL = actual.hasPrefix("/") ? URL(fileURLWithPath: actual) : URL(string: actual)
        guard let documentURL, documentURL.isFileURL else { return false }
        return documentURL.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The display text can run a text area's name and contents together. Read
    /// exact AX values only for explicitly guarded fields in the observed window.
    func handoffTextControls(app: String, windowID: UInt32, labels: [String],
                             parsed: [HandoffTool.Control]) -> [HandoffTool.Control] {
        guard let snapshot = snapshotsByApp[app.lowercased()], snapshot.observedWindowID == windowID else {
            return parsed
        }
        return parsed.map { control in
            guard ["text field", "search text field", "text area", "text entry area"].contains(control.role),
                  let record = snapshot.elements[control.index], let element = record.element,
                  let name = [stringValue(of: element, attribute: kAXTitleAttribute),
                              stringValue(of: element, attribute: kAXDescriptionAttribute), record.identifier]
                    .compactMap({ $0 }).first(where: { candidate in labels.contains { HandoffTool.sameLabel($0, candidate) } }),
                  !RecipeLocator.looksSecret(name),
                  !isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)),
                  let value = stringValue(of: element, attribute: kAXValueAttribute) else { return control }
            return HandoffTool.Control(index: control.index, role: control.role, label: name, value: value,
                                       disabled: control.disabled, writableText: control.writableText)
        }
    }

    @TaskLocal static var expectedSetValue: String?

    public func setValue(app query: String, elementIndex: String, value: String) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex, requireStableBounds: false)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture set_value requires a known element identifier")
            }

            let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
            moveVisualCursor(to: cursorTarget)
            try FixtureBridge.post(FixtureCommand(kind: "set_value", identifier: identifier, value: value))
            Thread.sleep(forTimeInterval: 0.15)
            settleVisualCursor(at: cursorTarget)
            return try actionResult(for: query)
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }

        // Some fields refuse a direct value or even the question (web and Electron editors answer the settable
        // check with an error). A text field is then filled the way a person does it: focus, select all, type.
        let settable = (try? isSettableForSetValue(element: element, attribute: kAXValueAttribute)) ?? false
        guard settable else {
            if Self.expectedSetValue != nil { throw ComputerUseError.notSent("The checked field does not support direct value writes.") }
            if StrictBackground.enabled() {
                throw ComputerUseError.backgroundUnsupported("This field cannot be set without focusing it and sending keys.")
            }
            if Self.requiredWindowID != nil { _ = try currentSnapshot(for: query, needScreenshot: false) }
            if let typed = try typeIntoUnsettableTextField(app: query, element: element, record: record, value: value, pid: snapshot.app.pid) {
                return typed
            }
            throw ComputerUseError.message(nonSettableSetValueErrorMessage + setValueFallbackHint)
        }

        let cursorTarget = Self.requiredWindowID == nil ? visualCursorTarget(for: record, snapshot: snapshot) : nil
        moveVisualCursor(to: cursorTarget)

        var delivery: DeliveryState = .notSent
        do {
            try requireUsableComputerUseSession()
            if let expected = Self.expectedSetValue {
                guard !isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)),
                      stringValue(of: element, attribute: kAXValueAttribute) == expected else {
                    throw ComputerUseError.notSent("The field no longer matches the expected current value. Nothing was sent.")
                }
            }
            delivery = .outcomeUnknown
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            guard result == .success else {
                throw ComputerUseError.message("AXUIElementSetAttributeValue failed with \(result.rawValue)")
            }

            delivery = .acknowledged
            try requireUsableComputerUseSession()
            // A password field's value is never read back: AppKit answers "" whatever it holds, so the check failed a
            // write that had worked and invited sending it again.
            if !isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)) {
                try verifySetValueReadBack(requested: value, elementIndex: elementIndex, read: {
                    // Direct AX reads: never verify against a cached snapshot value.
                    var actual: CFTypeRef?
                    return AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &actual) == .success ? actual : nil
                }, validate: { try requireUsableComputerUseSession() })
                delivery = .verified
            }
        } catch {
            settleVisualCursor(at: cursorTarget)
            if delivery == .acknowledged { throw ComputerUseError.acknowledged(SmartSteps.messageText(error)) }
            throw error
        }

        settleVisualCursor(at: cursorTarget)
        return try Self.verifiedSetValueResult(verified: delivery == .verified) {
            let result = try actionResult(for: query)
            return result.replacingContent(result.content, deliveryState: delivery)
        }
    }

    static func verifiedSetValueResult(verified: Bool, readBack: () throws -> ToolCallResult) rethrows -> ToolCallResult {
        if verified, defersVerifiedSetValueObservation {
            actionObservation?.deferToBatchRead()
            return .text("ok", deliveryState: .verified)
        }
        let result = try readBack()
        return verified ? result.replacingContent(result.content, deliveryState: .verified) : result
    }

    public func selectText(
        app query: String,
        elementIndex: String,
        text: String,
        prefix: String?,
        suffix: String?,
        selection: TextSelectionMode
    ) throws -> ToolCallResult {
        try selectText(app: query, elementIndex: elementIndex, text: text, prefix: prefix, suffix: suffix,
                       selection: selection, range: nil)
    }

    func selectText(app query: String, elementIndex: String, text: String, prefix: String?, suffix: String?,
                    selection: TextSelectionMode, range: TextRangeRequest?) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex,
                                             recoveryPolicy: range == nil ? .allowActivation : .readOnly)
        func resolve(in value: String) throws -> TextSelectionTarget {
            if let range { return try TextSelectionResolver.resolve(value: value, start: range.start, length: range.length) }
            return try resolveTextSelection(value: value, text: text, prefix: prefix, suffix: suffix,
                                            selection: selection, elementIndex: elementIndex)
        }
        func verified(_ target: TextSelectionTarget) throws -> ToolCallResult {
            let result = try actionResult(for: query, recoveryPolicy: .readOnly)
            guard range != nil else { return result }
            let note = "Selected range \(target.location), length \(target.length)."
            return ToolCallResult(content: [.text(note)] + result.content, isError: result.isError)
        }
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier, identifier == "fixture-input",
                  let state = try FixtureBridge.readState(),
                  let value = state.elements.first(where: { $0.identifier == identifier })?.value else {
                throw ComputerUseError.invalidArguments("fixture select_text requires a readable input element")
            }
            let target = try resolve(in: value)
            let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
            moveVisualCursor(to: cursorTarget)
            defer { settleVisualCursor(at: cursorTarget) }
            try FixtureBridge.post(FixtureCommand(kind: "select_text", identifier: identifier, value: text,
                                                 selection: selection.rawValue, prefix: prefix, suffix: suffix,
                                                 rangeStart: range?.start, rangeLength: range?.length))
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                if let applied = try FixtureBridge.readState(), applied.focusedIdentifier == identifier,
                   applied.selectedRangeLocation == target.location, applied.selectedRangeLength == target.length,
                   let current = applied.elements.first(where: { $0.identifier == identifier })?.value,
                   current.utf16.elementsEqual(value.utf16) {
                    return try verified(target)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw ComputerUseError.message("select_text could not verify fixture selection")
        }

        try requireUsableComputerUseSession()
        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }
        guard !isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)),
              let value = stringValue(of: element, attribute: kAXValueAttribute) else {
            throw ComputerUseError.message(selectTextUnreadableValueErrorMessage(elementIndex: elementIndex))
        }
        let target = try resolve(in: value)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            throw ComputerUseError.message("element \(elementIndex) does not support setting an accessibility text range")
        }
        let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
        moveVisualCursor(to: cursorTarget)
        defer { settleVisualCursor(at: cursorTarget) }
        try applyVerifiedTextSelection(
            target: target, originalValue: value,
            validate: { try requireUsableComputerUseSession() },
            readValue: { stringValue(of: element, attribute: kAXValueAttribute) },
            writeRange: { try AccessibilityTextSelection.writeRange($0, to: element) },
            readRange: { AccessibilityTextSelection.readRange(of: element) }
        )
        return try verified(target)
    }

    private func resolveTextSelection(value: String, text: String, prefix: String?, suffix: String?,
                                      selection: TextSelectionMode, elementIndex: String) throws -> TextSelectionTarget {
        do {
            return try TextSelectionResolver.resolve(value: value, text: text, prefix: prefix, suffix: suffix, selection: selection)
        } catch let error as TextSelectionResolverError {
            throw ComputerUseError.message(selectTextErrorMessage(error, elementIndex: elementIndex))
        }
    }

    /// Find controls in the app's current window by text and/or role, using the
    /// app's own accessibility search where it offers one. No tree render, no
    /// screenshot. Each result carries an `index` the existing element actions
    /// (click, set_value, select_text, scroll, perform_secondary_action) accept.
    public func query(
        app query: String,
        text: String? = nil,
        role: String? = nil,
        exact: Bool = false,
        limit: Int = 20,
        maxNodes: Int = 500,
        windowID: CGWindowID? = nil
    ) throws -> [String: Any] {
        guard (text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false) || (role.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false) else {
            throw ComputerUseError.invalidArguments("query requires at least one of text or role")
        }

        guard text.map({ $0.utf16.count <= 1000 }) ?? true, role.map({ $0.utf16.count <= 1000 }) ?? true else {
            throw ComputerUseError.invalidArguments("query text and role must be at most 1000 UTF-16 code units")
        }
        try requireUsableComputerUseSession()
        let app = try AppDiscovery.resolveRunning(query)
        let context = try SnapshotBuilder.resolveTargetWindow(for: app, windowID: windowID)
        let criteria = TargetedAX.Criteria(text: text, exact: exact, role: role,
                                          limit: min(100, max(1, limit)), maxNodes: min(5000, max(1, maxNodes)))
        let result = try SnapshotBuilder.targetedSearch(criteria, in: context)
        try requireUsableComputerUseSession()
        let matches = result.records.map { registerTargetedElement(record: $0, context: context, criteria: criteria) }
        return ["matches": matches, "truncated": result.truncated,
                "stop_reason": result.stopReason ?? "complete", "visited_nodes": result.visitedNodes,
                "window_id": context.windowID.map { Int($0) } ?? 0,
                "max_nodes": criteria.maxNodes, "limit": criteria.limit]
    }

    /// A snapshot carrying real window context but no rendered tree or screenshot,
    /// so the existing action internals run unchanged against a queried element.
    private func liteSnapshot(context: TargetedAX.WindowContext, elements: [Int: ElementRecord]) -> AppSnapshot {
        AppSnapshot(
            app: context.app,
            windowTitle: nil,
            windowBounds: context.windowBounds,
            targetWindowID: context.windowID,
            targetWindowLayer: context.windowLayer,
            screenshotData: nil,
            mode: .accessibility,
            treeLines: [],
            focusedSummary: nil,
            focusedElement: context.focusedElement,
            selectedText: nil,
            windowElement: context.windowElement,
            elements: elements
        )
    }

    /// The snapshot an element action runs against. A queried index resolves to
    /// that control's own window context with no snapshot; any other index uses
    /// the normal current snapshot.
    private func snapshotForAction(app query: String, elementIndex: String?,
                                   recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
                                   requireStableBounds: Bool = true) throws -> AppSnapshot {
        if Self.requiredRefGeneration == nil,
           let elementIndex, let index = Int(elementIndex), index > TargetedElementRegistry<TargetedElement>.indexBase {
            try requireUsableComputerUseSession()
            let app = try AppDiscovery.resolveRunning(query)
            let target = try targetedElements.resolve(index, app: TargetedAppIdentity(app: app))
            if let windowID = Self.requiredWindowID, target.context.windowID != windowID {
                throw windowBindingError(windowID)
            }
            do {
                let (context, record) = try SnapshotBuilder.currentGeometry(of: target.record, in: target.context, criteria: target.criteria)
                if let windowID = Self.requiredWindowID,
                   !SnapshotBuilder.isUsableWindowElement(context.windowElement) {
                    throw windowBindingError(windowID)
                }
                return liteSnapshot(context: context, elements: [index: record])
            } catch {
                targetedElements.remove(index)
                throw error
            }
        }
        return try currentSnapshot(for: query, needScreenshot: elementIndex == nil, recoveryPolicy: recoveryPolicy,
                                   requireStableBounds: requireStableBounds)
    }

    private func registerTargetedElement(record source: ElementRecord, context: TargetedAX.WindowContext,
                                         criteria: TargetedAX.Criteria) -> [String: Any] {
        var record: ElementRecord!
        _ = targetedElements.insert(app: TargetedAppIdentity(app: context.app)) { index in
            record = ElementRecord(index: index, identifier: source.identifier, element: source.element,
                                   localFrame: source.localFrame, role: source.role, title: source.title, value: source.value,
                                   rawActions: source.rawActions, prettyActions: source.prettyActions, isSyntheticText: source.isSyntheticText)
            return TargetedElement(record: record, context: context, criteria: criteria)
        }
        return compactRecordDictionary(record)
    }

    private func compactRecordDictionary(_ record: ElementRecord) -> [String: Any] {
        var dict: [String: Any] = ["index": record.index]
        if let role = record.role, !role.isEmpty { dict["role"] = role }
        if let title = record.title, !title.isEmpty { dict["title"] = title }
        if let value = record.value, !value.isEmpty { dict["value"] = value }
        if let identifier = record.identifier, !identifier.isEmpty { dict["identifier"] = identifier }
        if let frame = record.localFrame {
            dict["bounds"] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height]
        }
        if !record.prettyActions.isEmpty { dict["actions"] = record.prettyActions }
        return dict
    }

    private func windowBindingError(_ id: CGWindowID, reason: String? = nil, line: UInt = #line) -> ComputerUseError {
        let detail = inputFallbackDebugEnabled(environment: RequestConfiguration.environment)
            ? "ComputerUseService.swift:\(line)" + (reason.map { " " + $0 } ?? "") : nil
        return .windowChanged(id, detail: detail)
    }

    private func requireBoundFocusedWindow(in snapshot: AppSnapshot) throws {
        guard let windowID = Self.requiredWindowID else { return }
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        AXUIElementSetMessagingTimeout(appElement, AppTiming.messagingTimeout(pid: snapshot.app.pid, fixed: 0.2))
        guard let window = snapshot.windowElement,
              let focused = Self.elementAttribute(appElement, kAXFocusedWindowAttribute),
              CFEqual(focused, window),
              SkyLightSPI.shared.windowID(for: focused) == windowID else {
            throw windowBindingError(windowID)
        }
    }

    private func requireBoundInputFocus(in snapshot: AppSnapshot) throws -> AXUIElement {
        try requireBoundFocusedWindow(in: snapshot)
        guard let window = snapshot.windowElement,
              let focused = Self.currentInputFocus(pid: snapshot.app.pid),
              SnapshotBuilder.belongsToWindow(focused, window: window) else {
            throw ComputerUseError.stateUnavailable("There is no confirmed input focus in the observed window.")
        }
        return focused
    }

    func currentSnapshot(for query: String, needScreenshot: Bool = true,
                         recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
                         requireStableBounds: Bool = true) throws -> AppSnapshot {
        if let windowID = Self.requiredWindowID {
            try requireUsableComputerUseSession()
            let app: RunningAppDescriptor
            do {
                app = try AppDiscovery.resolveRunning(query)
            } catch ComputerUseError.appNotFound {
                debugClickDecision("window pin: app no longer running")
                throw windowBindingError(windowID)
            }
            guard let snapshot = snapshotsByApp[query.lowercased()],
                  let binding = snapshot.nativeWindow,
                  binding.matches(windowID: windowID, app: TargetedAppIdentity(app: app)),
                  !snapshot.app.runningApplication.isTerminated,
                  let observedWindow = snapshot.windowElement else {
                debugClickDecision("window pin: cached observation does not match requested window or process")
                throw windowBindingError(windowID)
            }
            if let generation = Self.requiredRefGeneration {
                guard snapshot.elementRefs?.generation == generation,
                      snapshot.elementRefs?.client == ClientScope.current,
                      snapshotsByApp[String(app.pid)]?.elementRefs?.generation == generation else {
                    throw ComputerUseError.staleRef
                }
            }
            func observedWindowRejection() throws -> String? {
                let live: TargetedAX.WindowContext
                do {
                    live = try SnapshotBuilder.resolveTargetWindow(for: app, windowID: windowID, matchingRoot: observedWindow)
                } catch ComputerUseError.stateUnavailable(let reason) {
                    return reason
                }
                guard live.windowID == windowID, SnapshotBuilder.isUsableWindowElement(live.windowElement) else {
                    return "observed root is no longer usable"
                }
                guard !requireStableBounds || live.windowBounds == snapshot.windowBounds else {
                    return "observed window bounds changed"
                }
                return nil
            }
            if try observedWindowRejection() != nil {
                // Retry the same root and bounds once without binding to a replacement.
                try RequestCancellation.check(delivery: .notSent)
                if let reason = try observedWindowRejection() {
                    throw windowBindingError(windowID, reason: reason)
                }
            }
            return snapshot
        }
        if let snapshot = snapshotsByApp[query.lowercased()] {
            if snapshot.mode != .fixture {
                do {
                    try requireUsableComputerUseSession()
                } catch {
                    snapshotsByApp.removeAll()
                    throw error
                }
            }
            return snapshot
        }

        if invalidatedSnapshotAliases.contains(query.lowercased()) {
            throw ComputerUseError.stateUnavailable(SnapshotObservationOptions.accessibilityOmittedNote)
        }
        // Element-targeted actions only need the AX tree: skip the screenshot (it cost ~0.3-0.5 s on
        // the first action of every call and was thrown away).
        return try refreshSnapshot(for: query, recoveryPolicy: recoveryPolicy,
                                   observation: needScreenshot ? .defaults : SnapshotObservationOptions(includeAX: true, includeScreenshot: false))
    }

    /// Element index for the first of `labels` (a title, AX identifier, or value-as-title; then aliases)
    /// in the app's current window. Clickable roles win over others; a partial match (3+ characters)
    /// is the last resort. A miss re-reads the window once, so an item that appeared after an earlier
    /// step (an opened menu) is found. Returns the record too, so callers can see role and value.
    /// `recoveryPolicy` is `.readOnly` for policy classification, so judging an action never raises an app.
    func resolveLabel(app query: String, labels: [String], strict: Bool = false,
                      recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation) throws -> ElementRecord {
        // Compared without spaces, so "All Clear" matches the identifier "AllClear".
        func norm(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: " External link", with: "").lowercased().filter { !$0.isWhitespace }
        }
        func roleKey(_ r: String?) -> String {
            var k = (r ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            if k.hasPrefix("ax") { k.removeFirst(2) }
            return k
        }
        let clickable: Set<String> = ["button", "menuitem", "menubutton", "menubaritem", "checkbox", "radiobutton", "popupbutton",
                                      "tab", "switch", "link", "cell", "row", "disclosuretriangle", "toggle", "segment"]
        let wrapperRoles: Set<String> = ["row", "cell"]
        let given = labels.map { norm($0) }.filter { !$0.isEmpty }
        guard !given.isEmpty else { throw ComputerUseError.invalidArguments("label is empty") }
        // Each label plus the spellings apps use for it: Calculator's keys are "one", "add", "multiply".
        var wanted: [String] = []
        for label in given {
            for spelling in [label] + LabelSpellings.alternatives(label) where !wanted.contains(spelling) {
                wanted.append(spelling)
            }
        }

        // Several different controls with the same label are never guessed between: the first "Delete" in a
        // list is rarely the one meant. A control and the row or cell around it count as one.
        func single(_ hits: [ElementRecord], names: (ElementRecord) -> [String]) throws -> ElementRecord? {
            guard hits.count > 1 else { return hits.first }
            var distinct: [ElementRecord] = []
            for hit in hits {
                let nested = distinct.contains { kept in
                    guard let a = kept.element, let b = hit.element else { return false }
                    if CFEqual(a, b) { return true }
                    // Overlapping or missing rectangles don't prove two controls are the same.
                    // Only collapse a row or cell with a matching descendant on its actual AX path.
                    guard let keptFrame = kept.localFrame, let hitFrame = hit.localFrame,
                          keptFrame.insetBy(dx: -1, dy: -1).contains(hitFrame)
                            || hitFrame.insetBy(dx: -1, dy: -1).contains(keptFrame) else { return false }
                    let outer: AXUIElement
                    var child: AXUIElement?
                    if wrapperRoles.contains(roleKey(kept.role)) {
                        outer = a
                        child = b
                    } else if wrapperRoles.contains(roleKey(hit.role)) {
                        outer = b
                        child = a
                    } else {
                        return false
                    }
                    for _ in 0..<6 {
                        child = child.flatMap { copyParent(of: $0) }
                        guard let child else { return false }
                        if CFEqual(child, outer) { return true }
                    }
                    return false
                }
                if !nested { distinct.append(hit) }
            }
            guard distinct.count > 1 else { return distinct.first }
            let listed = distinct.prefix(6).map { "\($0.index) \(roleKey($0.role)) \(names($0).first ?? "")" }.joined(separator: ", ")
            throw ComputerUseError.ambiguousTarget(
                "'\(labels[0])' \(SmartSteps.ambiguousPhrase) (\(distinct.count)): \(listed). Pick one with element_index."
            )
        }

        func find(in snapshot: AppSnapshot) throws -> ElementRecord? {
            let all = snapshot.elements.values.sorted { $0.index < $1.index }
            // Title, identifier and accessibility description first; a value only when nothing else names it.
            let names: (ElementRecord) -> [String] = { r in
                let t = norm(r.title)
                return [t, norm(r.identifier), norm(r.identity?.name), t.isEmpty ? norm(r.value) : ""].filter { !$0.isEmpty }
            }
            if strict {
                for w in given {
                    if let hit = try single(all.filter { names($0).contains(w) }, names: names) { return hit }
                }
                return nil
            }
            let buttons = all.filter { clickable.contains(roleKey($0.role)) }
            for pool in [buttons, all] {
                for w in given {
                    if let hit = try single(pool.filter { names($0).contains(w) }, names: names) { return hit }
                }
            }
            // Other spellings ("1" for "one", "+" for "add") only on a keypad, and only for its buttons: in any
            // other app "+" must not find a button that happens to be called Add.
            if LabelSpellings.isKeypad(buttonNames: buttons.flatMap(names)) {
                for w in wanted where !given.contains(w) {
                    if let hit = try single(buttons.filter { names($0).contains(w) }, names: names) { return hit }
                }
            }
            // A row that is drawn as one line (a Finder file, a table row) has no name of its own: its line in
            // the state is its name. The line is "<index> <role, state> <text>".
            var lineText: [Int: String] = [:]
            for line in snapshot.treeLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(of: " "), let index = Int(trimmed[..<space]) else { continue }
                lineText[index] = String(trimmed[trimmed.index(after: space)...]).lowercased()
            }
            for label in labels {
                let wantedText = label.trimmingCharacters(in: .whitespaces).lowercased()
                guard wantedText.count >= 2 else { continue }
                let rows = all.filter { record in
                    guard ["row", "cell"].contains(roleKey(record.role)), let text = lineText[record.index],
                          text.hasSuffix(" " + wantedText) else { return false }
                    return text.dropLast(wantedText.count).split(separator: " ").count <= 3
                }
                if let hit = try single(rows, names: names) { return hit }
            }
            // A file or row is often named only by its text value (Finder lists, table cells).
            for w in given where w.count >= 2 {
                let valued = all.filter { norm($0.value) == w }
                if valued.count == 1 { return valued[0] }
            }
            // A label copied from a state line with its identifier in front ("First Text View Bench line one.").
            for w in given {
                let prefixed = all.filter { r in
                    let id = norm(r.identifier)
                    return id.count >= 4 && w.hasPrefix(id) && w.count > id.count
                }
                if prefixed.count == 1 { return prefixed[0] }
            }
            // Part of a button's name, at least four characters: "Save As" finds "Save As…".
            if let w = given.first, w.count >= 4 {
                return try single(buttons.filter { names($0).contains(where: { $0.contains(w) }) }, names: names)
            }
            return nil
        }

        // The strict route preserves the current observation and never heals a missing target.
        if strict {
            let snapshot = try currentSnapshot(for: query, needScreenshot: false, recoveryPolicy: .readOnly, requireStableBounds: false)
            guard let hit = try find(in: snapshot) else {
                throw ComputerUseError.stateUnavailable("No exact control matches '\(labels[0])'. Read the window again.")
            }
            return hit
        }

        // A cached state may list controls that are gone, so an ambiguity there is checked against a fresh read.
        let fresh: AppSnapshot
        if Self.requiredWindowID != nil {
            fresh = try currentSnapshot(for: query, needScreenshot: false, requireStableBounds: false)
            if let hit = try find(in: fresh) { return hit }
        } else {
            // The expensive fresh read is skipped when this same label already missed on the current snapshot
            // generation (the generation changes on every stored read, so a new read always searches again).
            let labelKey = given.joined(separator: "\n")
            let outcome = try negativeLookups.searchTwoStep(
                keyFor: { NegativeLookupCache.Key(app: query.lowercased(), windowID: Int($0.targetWindowID ?? 0), label: labelKey, role: "") },
                cached: try? currentSnapshot(for: query, needScreenshot: false),
                generation: { self.snapshotStoreCount },
                now: { TimingLog.now() },
                find: { try find(in: $0) },
                readFresh: { try refreshSnapshot(for: query, recoveryPolicy: recoveryPolicy,
                                                 observation: SnapshotObservationOptions(includeAX: true, includeScreenshot: false)) })
            if let hit = outcome.hit { return hit }
            fresh = outcome.state
        }
        // A text field or document named by what it contains ("The quick blue fox."): the one field holding it.
        if let w = given.first, w.count >= 4 {
            let holders = fresh.elements.values.filter { r in
                let role = (r.role ?? "").lowercased()
                return (role.contains("text") || role.contains("field") || role.contains("entry")) && norm(r.value).contains(w)
            }
            if holders.count == 1 { return holders[0] }
        }
        // The document named by what it is ("text entry area", "text area", "document"): the window's one text area.
        if let w = given.first, ["text entry area", "text area", "textarea", "text view", "document", "text", "body", "editor", "text field"].contains(w) {
            let areas = fresh.elements.values.filter { ($0.role ?? "") == (kAXTextAreaRole as String) }
            if areas.count == 1 { return areas[0] }
            let fields = fresh.elements.values.filter { ($0.role ?? "") == (kAXTextFieldRole as String) }
            if areas.isEmpty, fields.count == 1 { return fields[0] }
        }
        let avail = Set(fresh.elements.values.filter { clickable.contains(roleKey($0.role)) }
            .map { norm($0.title).isEmpty ? norm($0.identifier) : norm($0.title) }.filter { !$0.isEmpty }).sorted()
        if LabelSpellings.menuBarTitles.contains(given[0]) {
            throw ComputerUseError.invalidArguments("'\(labels[0])' is a menu bar menu, not a window control. Use press_menu, e.g. {\"app\": \"\(query)\", \"path\": \"\(labels[0]) > Save\"}; press_menu with just \"\(labels[0])\" lists its items.")
        }
        let shown = avail.isEmpty
            ? "none with a name; use element_index from the state, or query to find text"
            : avail.prefix(60).joined(separator: ", ")
        throw ComputerUseError.targetNotFound("no element labelled '\(labels[0])'. Clickable labels now: \(shown)")
    }

    static func isToggleRole(_ role: String?) -> Bool {
        var k = (role ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if k.hasPrefix("ax") { k.removeFirst(2) }
        return ["menuitem", "checkbox", "switch", "radiobutton", "toggle"].contains(k)
    }

    @discardableResult
    private func refreshSnapshot(
        for query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
        observation: SnapshotObservationOptions = .defaults
    ) throws -> AppSnapshot {
        let app = try TimingLog.measure("snapshot.resolve_app") {
            try observation.includeRefs ? AppDiscovery.resolveRunning(query) : AppDiscovery.resolve(query)
        }
        let snapshot = try SnapshotBuilder.build(
            for: app,
            textLimit: textLimit,
            treeLimits: treeLimits,
            recoveryPolicy: observation.includeRefs ? .readOnly : recoveryPolicy,
            observation: observation
        )

        rememberSnapshot(snapshot, for: query)
        return snapshot
    }

    func rememberSnapshot(_ snapshot: AppSnapshot, for query: String) {
        let app = snapshot.app
        // Remember each element's role and name per number (for "gone" messages and restore healing), for every
        // read that is stored, not only get_app_state: an action's own re-read may show new elements too.
        if ElementNumbering.isEnabled, snapshot.numberingHighWater != nil {
            ElementNumbering.forApp(pid: app.pid).remember(snapshot: snapshot)
        }
        if !snapshot.observation.includeAX {
            var pids: Set<Int32> = [app.pid]
            if let previous = snapshotsByApp[query.lowercased()] { pids.insert(previous.app.pid) }
            let aliases = snapshotsByApp.compactMap { pids.contains($0.value.app.pid) ? $0.key : nil }
            for alias in aliases {
                snapshotsByApp.removeValue(forKey: alias)
                invalidatedSnapshotAliases.insert(alias)
            }
            targetedElements.removeAll(forPIDs: pids)
        }

        let keys = Set([
            query.lowercased(),
            String(app.pid),
            app.name.lowercased(),
            (app.bundleIdentifier ?? "").lowercased(),
        ].filter { !$0.isEmpty })

        // Every stored read is a new generation for NegativeLookupCache, so misses from an older tree are not reused.
        snapshotStoreCount += 1
        for key in keys {
            snapshotsByApp[key] = snapshot
            invalidatedSnapshotAliases.remove(key)
        }

    }

    func isSecurePolicyField(_ record: ElementRecord) -> Bool {
        let subrole = record.element.flatMap { stringValue(of: $0, attribute: kAXSubroleAttribute) }
            ?? record.identity?.subrole
        return isSecureTextField(subrole: subrole)
    }

    func policyElement(app: String, index: String) -> ElementRecord? {
        guard let snapshot = try? snapshotForAction(app: app, elementIndex: index) else { return nil }
        return try? lookupElement(snapshot: snapshot, index: index)
    }

    func liveInputPolicyTarget(app: String) -> ActionPolicy.Target? {
        guard let descriptor = try? AppDiscovery.resolveRunning(app),
              let focus = Self.currentInputFocus(pid: descriptor.pid) else { return nil }
        return ActionPolicy.Target(
            role: stringValue(of: focus, attribute: kAXRoleAttribute),
            secureField: isSecureTextField(subrole: stringValue(of: focus, attribute: kAXSubroleAttribute)),
            inDialog: Self.isInsideSheetOrDialog(focus)
        )
    }

    private func lookupElement(snapshot: AppSnapshot, index: String) throws -> ElementRecord {
        guard let parsedIndex = Int(index), let record = snapshot.elements[parsedIndex] else {
            if Self.requiredRefGeneration != nil { throw ComputerUseError.staleRef }
            // Numbers are stable across reads: one that was handed out before but is not shown now is gone.
            if let parsedIndex = Int(index), parsedIndex >= 0, let high = snapshot.numberingHighWater, parsedIndex < high {
                let known = ElementNumbering.forApp(pid: snapshot.app.pid).remembered(parsedIndex)
                throw ComputerUseError.elementGone(ElementNumbering.goneMessage(index: index, role: known?.role, label: known?.label))
            }
            throw ComputerUseError.invalidArguments("unknown element_index '\(index)'")
        }

        if let windowID = Self.requiredWindowID {
            guard let element = record.element, let window = snapshot.windowElement,
                  SnapshotBuilder.belongsToWindow(element, window: window) else {
                debugClickDecision("window pin: selected accessibility element is outside the observed root")
                throw windowBindingError(windowID)
            }
        }
        if Self.requiredRefGeneration != nil {
            var pid: pid_t = 0
            guard let element = record.element, let identity = record.identity, identity.role != nil,
                  AXUIElementGetPid(element, &pid) == .success, pid == snapshot.app.pid,
                  try ElementIdentity.read(element) == identity else {
                throw ComputerUseError.staleRef
            }
            return record
        }
        return try keptRecord(record, index: index, snapshot: snapshot)
    }

    private func keptRecord(_ record: ElementRecord, index: String, snapshot: AppSnapshot) throws -> ElementRecord {
        guard let recorded = record.identity, let element = record.element else { return record }
        let now = try ElementIdentity.read(element)
        // An element that cannot be read at all has left the app: say so plainly (the number is never reused).
        if now == nil, snapshot.numberingHighWater != nil, Self.elementIsGone(element) {
            throw ComputerUseError.elementGone(ElementNumbering.goneMessage(
                index: index, role: SmartSteps.roleKey(record.role), label: SmartSteps.name(of: record)
            ))
        }
        try ElementIdentity.validate(index: index, recorded: recorded, now: now)
        return record
    }

    /// True only when the app answers that this element no longer exists. A busy or slow app (cannotComplete,
    /// a timeout) is not "gone": the caller then gets the "could not be checked" message instead.
    static func elementIsGone(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .invalidUIElement
    }

    /// Reads AXEnabled now, not from the snapshot: the control may have changed since the read.
    private func refuseDisabledControl(_ record: ElementRecord, elementIndex: String) throws {
        guard let element = record.element else { return }
        var enabled: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        if let refusal = disabledControlRefusal(enabled: enabled as? Bool, role: record.role, elementIndex: elementIndex) {
            throw ComputerUseError.notSent(refusal)
        }
    }

    func matchingAction(requested: String, record: ElementRecord) -> String? {
        if let exact = record.rawActions.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }
        let visibleActions = record.role.map { meaningfulRawActions(record.rawActions, role: $0) } ?? record.rawActions
        let matches = visibleActions.filter { rawAction in
            secondaryActionNamesEquivalent(requested, secondaryActionDisplayName(rawAction))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func invalidSecondaryActionMessage(action: String, record: ElementRecord) -> String {
        invalidSecondaryActionErrorMessage(action: action, elementIndex: record.index)
    }

    private func performPreferredClick(on record: ElementRecord, button: MouseButtonKind, clickCount: Int) throws -> Bool {
        guard let element = record.element else {
            return false
        }

        switch button {
        case .left:
            if Self.requiredRefGeneration == nil, clickCount <= 1,
               !hasAncestorRole("AXWebArea", of: element),
               try selectContainingListItem(for: element)
            {
                return true
            }

            if try performAction(named: kAXPressAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if try performAction(named: kAXConfirmAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if !backgroundOnlyMode(), try performAction(named: "AXOpen", on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .right:
            if !backgroundOnlyMode(), try performAction(named: kAXShowMenuAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .middle:
            break
        }

        return false
    }

    private func clickCandidates(at point: CGPoint, in snapshot: AppSnapshot) throws -> [ElementRecord] {
        var candidates: [ElementRecord] = []

        if let bestRecord = bestElement(containing: point, in: snapshot) {
            candidates.append(bestRecord)
        }

        if let hitRecord = try hitTestElement(at: point, in: snapshot) {
            candidates.append(hitRecord)
        }

        return candidates.reduce(into: []) { uniqueCandidates, candidate in
            if !uniqueCandidates.contains(where: { sameElement($0.element, candidate.element) }) {
                uniqueCandidates.append(candidate)
            }
        }
    }

    private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return CFEqual(lhs, rhs)
    }

    private func selectContainingListItem(for element: AXUIElement) throws -> Bool {
        guard let target = selectableListItem(containing: element) else {
            return false
        }

        try requireUsableComputerUseSession()
        let result = AXUIElementSetAttributeValue(
            target.list,
            kAXSelectedChildrenAttribute as CFString,
            [target.item] as CFArray
        )

        guard try clickAttributeWasSet(result, attribute: kAXSelectedChildrenAttribute) else {
            return false
        }
        pauseBeforeReadBack(0.15)
        return true
    }

    /// Selects the outline or table row that `record` is (or whose text, cell or icon it is), when that row
    /// is not selected yet. Buttons, checkboxes and other controls inside a row are left to the normal click,
    /// and so is a row that is already selected (a second click there may start editing). Native tables only.
    private func selectContainingTableRow(for record: ElementRecord) throws -> Bool {
        guard let element = record.element,
              let role = stringValue(of: element, attribute: kAXRoleAttribute),
              [kAXRowRole as String, kAXCellRole as String, kAXStaticTextRole as String,
               kAXTextFieldRole as String, kAXImageRole as String].contains(role)
        else { return false }
        var row: AXUIElement?
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let node = current else { break }
            if stringValue(of: node, attribute: kAXRoleAttribute) == kAXRowRole as String {
                row = node
                break
            }
            current = copyParent(of: node)
        }
        guard let row, let table = copyParent(of: row),
              let tableRole = stringValue(of: table, attribute: kAXRoleAttribute),
              [kAXOutlineRole as String, kAXTableRole as String].contains(tableRole),
              !Self.isInsideWebArea(row)
        else { return false }

        func isSelected() -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(row, kAXSelectedAttribute as CFString, &value) == .success
                && (value as? NSNumber)?.boolValue == true
        }
        guard !isSelected() else { return false }
        try requireUsableComputerUseSession()
        // Replacing the table's selection selects only this row; setting the row's own flag is the fallback.
        if isSettable(element: table, attribute: kAXSelectedRowsAttribute) {
            _ = AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
        }
        if !isSelected(), isSettable(element: row, attribute: kAXSelectedAttribute) {
            _ = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        }
        pauseBeforeReadBack(0.1)
        return isSelected()
    }

    private func selectableListItem(containing element: AXUIElement) -> (list: AXUIElement, item: AXUIElement)? {
        var current = element
        var directChild = element

        for _ in 0..<8 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == kAXListRole as String,
               isSettable(element: parent, attribute: kAXSelectedChildrenAttribute)
            {
                return (parent, directChild)
            }

            directChild = parent
            current = parent
        }

        return nil
    }

    private func performAXClickSequence(
        on record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int,
        includeNearbyHitTesting: Bool,
        allowActivationFallback: Bool,
        clickPoint: CGPoint? = nil
    ) throws -> Bool {
        // A ref authorizes exactly this AX object. Parent, descendant and pixel
        // fallbacks can activate a different control.
        if Self.requiredRefGeneration != nil {
            return try performPreferredClick(on: record, button: button, clickCount: clickCount)
        }

        // The activation fallback raises and focuses the window, which takes the user's focus. It only runs while
        // the app is borrowed (a batch with foreground: true), in every mode.
        let allowActivationFallback = allowActivationFallback
            && FocusBorrow.isBorrowed(pid: snapshot.app.pid)
        let targetFrame = clickFrame(for: record, snapshot: snapshot)
        let isAtTarget = { (candidate: ElementRecord) in
            isDescendantClickCandidateAtTarget(candidateFrame: candidate.localFrame, clickPoint: clickPoint, targetFrame: targetFrame)
        }
        // A plain click on a row of a native list or table means "select it". Pressing the row's text did not
        // select it in Finder, so a following Return renamed whichever file was selected before.
        if button == .left, clickCount == 1, clickPoint == nil, try selectContainingTableRow(for: record) {
            debugClickDecision("handled by selecting the table row of \(clickDebugDescription(record))")
            pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
            return true
        }

        let preferContainingWebRowAXClick = shouldPreferContainingWebRowAXClick(record, in: snapshot)
        debugClickDecision("record=\(clickDebugDescription(record)) preferContainingWebRowAXClick=\(preferContainingWebRowAXClick)")

        if preferContainingWebRowAXClick,
           try performContainingWebRowClick(for: record, snapshot: snapshot, button: button, clickCount: clickCount)
        {
            pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
            return true
        }

        // Selecting a window or sheet index means the root itself, not a button inside it.
        // Skip both descendant and nearby-point searches and use the existing raise path.
        let windowIndexClick = clickPoint == nil && record.element.map {
            canUseActivationOnlyClickFallback(role: stringValue(of: $0, attribute: kAXRoleAttribute))
        } == true
        if !preferContainingWebRowAXClick && !windowIndexClick {
            if try performPreferredClick(on: record, button: button, clickCount: clickCount) {
                debugClickDecision("handled by preferred target \(clickDebugDescription(record))")
                pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
                return true
            }

            for candidate in descendantClickCandidates(for: record, snapshot: snapshot) where isAtTarget(candidate) {
                if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                    debugClickDecision("handled by descendant \(clickDebugDescription(candidate))")
                    pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
                    return true
                }
            }

            if includeNearbyHitTesting {
                for localPoint in clickActionPoints(for: record, snapshot: snapshot) {
                    guard let hitRecord = try hitTestElement(at: localPoint, in: snapshot) ?? bestElement(containing: localPoint, in: snapshot) else {
                        continue
                    }

                    if !isLikelySyntheticSideAction(hitRecord, in: record),
                       try performPreferredClick(on: hitRecord, button: button, clickCount: clickCount)
                    {
                        debugClickDecision("handled by hit record \(clickDebugDescription(hitRecord))")
                        pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
                        return true
                    }

                    if shouldScanDescendantsOfHitRecord(
                        originalFrame: targetFrame,
                        hitFrame: hitRecord.localFrame
                    ) {
                        for candidate in descendantClickCandidates(
                            for: hitRecord,
                            snapshot: snapshot,
                            sideActionScope: record
                        ) where isAtTarget(candidate) {
                            if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                                debugClickDecision("handled by hit descendant \(clickDebugDescription(candidate))")
                                pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
                                return true
                            }
                        }
                    }
                }
            }
        }

        guard
            allowActivationFallback,
            !record.isSyntheticText,
            button == .left,
            let element = record.element,
            canUseActivationOnlyClickFallback(role: stringValue(of: element, attribute: kAXRoleAttribute))
        else {
            return false
        }

        if try activateClickTarget(element: element, availableActions: record.rawActions) {
            debugClickDecision("handled by activation fallback \(clickDebugDescription(record))")
            pauseBeforeReadBack(0.15, windowID: snapshot.targetWindowID, window: snapshot.windowElement)
            return true
        }

        return false
    }

    private func performAction(named action: String, on element: AXUIElement, availableActions: [String], repeatCount: Int = 1) throws -> Bool {
        guard availableActions.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) else {
            return false
        }

        // A short gap between repeated presses only (a single click never waits): sent back-to-back,
        // some apps merge a double-click into one press.
        return try performClickActionSequence(action: action, repeatCount: repeatCount, send: {
            try requireUsableComputerUseSession()
            return AXUIElementPerformAction(element, action as CFString)
        }, pause: { Thread.sleep(forTimeInterval: 0.04) })
    }

    private func activateClickTarget(element: AXUIElement, availableActions: [String]) throws -> Bool {
        var activated = false

        if try performAction(named: kAXRaiseAction as String, on: element, availableActions: availableActions) {
            activated = true
        }

        if try setBoolAttribute(named: kAXMainAttribute, on: element) {
            activated = true
        }

        if try setBoolAttribute(named: kAXFocusedAttribute, on: element) {
            activated = true
        }

        return activated
    }

    private func setBoolAttribute(named attribute: String, on element: AXUIElement) throws -> Bool {
        try requireUsableComputerUseSession()
        return try clickAttributeWasSet(AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue), attribute: attribute)
    }

    private func isSettable(element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    /// set_value's fallback for a text field whose value cannot be written directly. Returns nil when the element
    /// is not a plain, non-secure text field or will not take focus, so the caller reports the original problem.
    private func typeIntoUnsettableTextField(app query: String, element: AXUIElement, record: ElementRecord, value: String, pid: pid_t) throws -> ToolCallResult? {
        guard Self.typingRoles.contains(SmartSteps.roleKey(record.role)),
              !isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)),
              Self.isFocusableTextTarget(element) || Self.isEditableTextTarget(element),
              AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        var focused = false
        repeat {
            Thread.sleep(forTimeInterval: 0.03)
            if let now = Self.currentInputFocus(pid: pid), Self.focus(now, isWithin: element) { focused = true }
        } while !focused && ProcessInfo.processInfo.systemUptime < deadline
        guard focused else { return nil }
        _ = try pressKey(app: query, key: "cmd+a")
        let result = value.isEmpty ? try pressKey(app: query, key: "Delete") : try typeText(app: query, text: value)
        guard !result.isError else { return result }
        var note = "This field does not take a value directly, so its text was selected and the new value typed."
        if let readBack = stringValue(of: element, attribute: kAXValueAttribute),
           readBack.trimmingCharacters(in: .whitespacesAndNewlines) != value.trimmingCharacters(in: .whitespacesAndNewlines) {
            note += " The field now reads differently from the value; check it in the state below."
        }
        return ToolCallResult(content: [.text(note)] + result.content, isError: false)
    }

    private func isSettableForSetValue(element: AXUIElement, attribute: String) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return try setValueAttributeIsSettable(
            result: result,
            settable: settable.boolValue,
            attribute: attribute
        )
    }

    private func bestElement(containing point: CGPoint, in snapshot: AppSnapshot) -> ElementRecord? {
        snapshot.elements.values
            .filter { $0.localFrame?.contains(point) ?? false }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
            .first
    }

    /// `point` is a window point (the space of `ElementRecord.localFrame`), not a screenshot pixel.
    private func hitTestElement(at point: CGPoint, in snapshot: AppSnapshot) throws -> ElementRecord? {
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        let globalPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: point)
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appElement, Float(globalPoint.x), Float(globalPoint.y), &hitElement)
        debugClickDecision("hit test window=\(point) screen=\(globalPoint) result=\(result.rawValue)")
        guard result == .success, let hitElement else {
            return nil
        }

        let rawActions = copyActions(for: hitElement) ?? []
        return ElementRecord(
            index: -1,
            identifier: nil,
            element: hitElement,
            localFrame: localFrame(of: hitElement, windowBounds: snapshot.windowBounds),
            rawActions: rawActions,
            prettyActions: rawActions
        )
    }

    private func clickPriority(for record: ElementRecord) -> Int {
        if record.rawActions.contains(where: {
            $0.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame
        }) {
            return 0
        }

        if let element = record.element,
           isSettable(element: element, attribute: kAXMainAttribute) ||
           isSettable(element: element, attribute: kAXFocusedAttribute) {
            return 1
        }

        return 2
    }

    private func frameArea(of record: ElementRecord) -> CGFloat {
        guard let frame = record.localFrame else {
            return .greatestFiniteMagnitude
        }

        return frame.width * frame.height
    }

    private func localCenter(for record: ElementRecord) -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func clickActionPoints(for record: ElementRecord, snapshot: AppSnapshot) -> [CGPoint] {
        guard let frame = clickFrame(for: record, snapshot: snapshot) else {
            return []
        }

        return localClickActionPoints(frame: frame, isSyntheticText: record.isSyntheticText)
    }

    private func descendantClickCandidates(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        sideActionScope: ElementRecord? = nil
    ) -> [ElementRecord] {
        guard let element = record.element else {
            return []
        }

        let sideActionParent = sideActionScope ?? record
        return descendantClickCandidates(of: element, windowBounds: snapshot.windowBounds)
            .filter { candidate in
                !isLikelySyntheticSideAction(candidate, in: sideActionParent)
            }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
    }

    private func descendantClickCandidates(of element: AXUIElement, windowBounds: CGRect?, depth: Int = 0) -> [ElementRecord] {
        guard depth < 3 else {
            return []
        }

        var results: [ElementRecord] = []
        for child in copyChildren(of: element) {
            let rawActions = copyActions(for: child) ?? []
            results.append(
                ElementRecord(
                    index: -1,
                    identifier: nil,
                    element: child,
                    localFrame: localFrame(of: child, windowBounds: windowBounds),
                    rawActions: rawActions,
                    prettyActions: rawActions
                )
            )
            results.append(contentsOf: descendantClickCandidates(of: child, windowBounds: windowBounds, depth: depth + 1))
        }

        return results
    }

    private func isLikelySyntheticSideAction(_ candidate: ElementRecord, in parent: ElementRecord) -> Bool {
        isLikelySyntheticSideActionCandidate(
            parentFrame: parent.localFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate),
            labels: accessibilityLabels(for: candidate.element)
        )
    }

    private func hasPrimaryClickAction(_ record: ElementRecord) -> Bool {
        record.rawActions.contains { action in
            action.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
                action.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
                action.caseInsensitiveCompare("AXOpen") == .orderedSame ||
                action.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame
        }
    }

    private func shouldPreferContainingWebRowAXClick(_ record: ElementRecord, in snapshot: AppSnapshot) -> Bool {
        guard
            let element = record.element
        else {
            return false
        }

        return shouldPreferContainingWebRowAXClickCandidate(
            role: stringValue(of: element, attribute: kAXRoleAttribute),
            isSyntheticText: record.isSyntheticText,
            hasWebAreaAncestor: hasAncestorRole("AXWebArea", of: element),
            appName: snapshot.app.name,
            bundleIdentifier: snapshot.app.bundleIdentifier
        )
    }

    private func performContainingWebRowClick(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int
    ) throws -> Bool {
        guard
            button == .left,
            clickCount <= 1,
            let element = record.element,
            let targetFrame = record.localFrame
        else {
            return false
        }

        var current = element

        for _ in 0..<6 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            let rawActions = copyActions(for: parent) ?? []
            let candidate = ElementRecord(
                index: -1,
                identifier: nil,
                element: parent,
                localFrame: localFrame(of: parent, windowBounds: snapshot.windowBounds),
                rawActions: rawActions,
                prettyActions: rawActions
            )

            if isLikelyContainingWebRowAction(targetFrame: targetFrame, candidate: candidate),
               !isLikelySyntheticSideAction(candidate, in: record),
               try performAction(named: kAXPressAction as String, on: parent, availableActions: rawActions)
            {
                debugClickDecision("handled by containing web row \(clickDebugDescription(candidate))")
                return true
            }

            current = parent
        }

        return false
    }

    private func isLikelyContainingWebRowAction(
        targetFrame: CGRect,
        candidate: ElementRecord
    ) -> Bool {
        isLikelyContainingRowActionFrame(
            targetFrame: targetFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate)
        )
    }

    private func hasAncestorRole(_ role: String, of element: AXUIElement) -> Bool {
        var current = element

        for _ in 0..<12 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == role {
                return true
            }

            current = parent
        }

        return false
    }

    private func accessibilityLabels(for element: AXUIElement?) -> [String] {
        guard let element else {
            return []
        }

        return [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXValueAttribute as String,
            "AXIdentifier"
        ].compactMap { attribute in
            stringValue(of: element, attribute: attribute)
        }
    }

    private func requireCurrentTextFocus(_ element: AXUIElement, pid: pid_t) throws {
        try requireUsableComputerUseSession()
        guard let current = Self.currentInputFocus(pid: pid), CFEqual(element, current) else {
            throw ComputerUseError.stateUnavailable("type_text focus changed before input. Read the app state and try again.")
        }
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID(),
              AXValueGetType(raw as! AXValue) == .cfRange,
              AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func typeTextUsingAccessibility(_ text: String, on element: AXUIElement, pid: pid_t) throws -> Bool {
        if isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)) { return false }
        // Renaming a file selects its name without the extension. A model types the whole new name, extension
        // included, and over that selection it became "name.txt.txt". The whole old name is replaced instead.
        if replacesWholeName(of: element, pid: pid, text: text) {
            return try replaceWholeName(text, on: element, pid: pid)
        }
        let attribute: String
        let value: String
        var caret: Int?
        var valueExpectedToChange: String?
        // SelectedText preserves the selection/caret and rich text. It can be
        // writable even when replacing the entire AXValue is not supported.
        if isSettable(element: element, attribute: kAXSelectedTextAttribute) {
            attribute = kAXSelectedTextAttribute
            value = text
            if let original = stringValue(of: element, attribute: kAXValueAttribute),
               let selection = selectedRange(of: element),
               let replacement = typedTextReplacement(value: original, selection: selection, text: text),
               replacement.value != original {
                valueExpectedToChange = original
            }
        } else {
            let valueWritable = isSettable(element: element, attribute: kAXValueAttribute)
            let rangeWritable = isSettable(element: element, attribute: kAXSelectedTextRangeAttribute)
            let originalValue = stringValue(of: element, attribute: kAXValueAttribute)
            let currentSelection = selectedRange(of: element)
            if inputFallbackDebugEnabled(environment: RequestConfiguration.environment) {
                fputs("[open-computer-use] type_text value_writable=\(valueWritable) range_writable=\(rangeWritable) value_readable=\(originalValue != nil) selection_readable=\(currentSelection != nil)\n", stderr)
            }
            guard valueWritable, rangeWritable, let original = originalValue, let selection = currentSelection else { return false }
            // Retain placeholder handling, but never splice a range into a
            // synthesized descendant string that differs from the reported value.
            let editable = editableBaseValue(for: element)
            let base = editable.isEmpty && !normalizeEditablePlaceholderText(original).isEmpty ? editable : original
            guard let replacement = typedTextReplacement(value: base, selection: selection, text: text) else { return false }
            guard stringValue(of: element, attribute: kAXValueAttribute) == original,
                  let current = selectedRange(of: element), current.location == selection.location, current.length == selection.length
            else { throw ComputerUseError.stateUnavailable("type_text text or selection changed before input. Read the app state and try again.") }
            attribute = kAXValueAttribute
            value = replacement.value
            caret = replacement.caret
        }

        try requireCurrentTextFocus(element, pid: pid)
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value as CFString)
        guard result == .success else {
            // A failed/timed-out write may already have changed the control.
            // Never append or resend the same input through another path.
            throw ComputerUseError.message("type_text AXUIElementSetAttributeValue(\(attribute)) failed with \(result.rawValue). Read the current text before retrying.")
        }
        if let original = valueExpectedToChange,
           stringValue(of: element, attribute: kAXValueAttribute) == original {
            throw ComputerUseError.stateUnavailable("type_text sent an accessibility write, but the field's text did not change. Read the app state before retrying.")
        }
        if let caret {
            try requireCurrentTextFocus(element, pid: pid)
            guard stringValue(of: element, attribute: kAXValueAttribute) == value else {
                throw ComputerUseError.stateUnavailable("type_text value changed after writing; caret was not moved. Read the current text before retrying.")
            }
            var range = CFRange(location: caret, length: 0)
            guard let axRange = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
                  let applied = selectedRange(of: element), applied.location == caret, applied.length == 0
            else { throw ComputerUseError.stateUnavailable("type_text wrote the text but could not restore the caret. Read the current text before retrying.") }
        }
        return true
    }

    /// Whether `text` is a full new name typed over a rename selection in Finder's rename editor `element`
    /// (see typedNameReplacesWholeValue and isFinderRenameEditor). Any other text field is never renamed this way.
    private func replacesWholeName(of element: AXUIElement, pid: pid_t, text: String) -> Bool {
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard isFinderRenameEditor(
            bundleIdentifier: bundleIdentifier,
            role: stringValue(of: element, attribute: kAXRoleAttribute),
            insideSheetOrDialog: Self.isInsideSheetOrDialog(element)
        ) else { return false }
        guard let value = stringValue(of: element, attribute: kAXValueAttribute),
              let selection = selectedRange(of: element) else { return false }
        return typedNameReplacesWholeValue(value: value, selection: selection, text: text)
    }

    /// Whether `element` sits in a sheet or dialog (checked up the parents, a bounded walk).
    private static func isInsideSheetOrDialog(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return false }
            let role = copyStringAttribute(node, kAXRoleAttribute)
            let subrole = copyStringAttribute(node, kAXSubroleAttribute)
            if role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Writes a whole new name over an old one. The selection is widened to the whole value first when it can be
    /// set, and then written as selected text; otherwise the whole value is written. False when neither can be set.
    private func replaceWholeName(_ text: String, on element: AXUIElement, pid: pid_t) throws -> Bool {
        let valueSettable = isSettable(element: element, attribute: kAXValueAttribute)
        var selectedWhole = false
        if isSettable(element: element, attribute: kAXSelectedTextRangeAttribute),
           let original = stringValue(of: element, attribute: kAXValueAttribute) {
            var whole = CFRange(location: 0, length: (original as NSString).length)
            if let range = AXValueCreate(.cfRange, &whole),
               AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, range) == .success,
               let applied = selectedRange(of: element), applied.location == 0, applied.length == whole.length {
                selectedWhole = true
            }
        }
        let attribute: String
        if selectedWhole, isSettable(element: element, attribute: kAXSelectedTextAttribute) {
            attribute = kAXSelectedTextAttribute
        } else if valueSettable {
            attribute = kAXValueAttribute
        } else {
            return false
        }
        try requireCurrentTextFocus(element, pid: pid)
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, text as CFString)
        guard result == .success else {
            throw ComputerUseError.message("type_text AXUIElementSetAttributeValue(\(attribute)) failed with \(result.rawValue). Read the current text before retrying.")
        }
        return true
    }

    private func canTypeTextUsingKeyboardFallback(on element: AXUIElement) -> Bool {
        let role = stringValue(of: element, attribute: kAXRoleAttribute)
        let roleDescription = role.flatMap {
            stringValue(of: element, attribute: kAXRoleDescriptionAttribute) ?? humanizedRoleDescription(for: $0)
        }
        return canUseKeyboardTextFallback(
            role: role,
            roleDescription: roleDescription,
            isValueSettable: isSettable(element: element, attribute: kAXValueAttribute)
        )
    }

    private func humanizedRoleDescription(for role: String) -> String {
        if role == kAXTextFieldRole as String {
            return "text field"
        }

        switch role {
        case "AXTextArea", "AXTextView":
            return "text entry area"
        default:
            return ""
        }
    }

    private func editableBaseValue(for element: AXUIElement) -> String {
        let childTextValues = editableDescendantTextValues(in: element)
            .filter { !looksLikeEditablePlaceholder($0) }
        if !childTextValues.isEmpty {
            return childTextValues.joined()
        }

        guard let currentValue = stringValue(of: element, attribute: kAXValueAttribute) else {
            return ""
        }

        let normalizedValue = normalizeEditablePlaceholderText(currentValue)
        if normalizedValue.isEmpty || looksLikeEditablePlaceholder(normalizedValue) {
            return ""
        }

        for attribute in ["AXPlaceholderValue", "AXPlaceholder"] {
            guard let placeholder = stringValue(of: element, attribute: attribute) else {
                continue
            }

            if normalizedValue == normalizeEditablePlaceholderText(placeholder) {
                return ""
            }
        }

        return currentValue
    }

    private func editableDescendantTextValues(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 4 else {
            return []
        }

        var values: [String] = []
        for child in copyChildren(of: element) {
            if stringValue(of: child, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
               let value = stringValue(of: child, attribute: kAXValueAttribute)
                    ?? stringValue(of: child, attribute: kAXTitleAttribute)
            {
                let normalized = normalizeEditablePlaceholderText(value)
                if !normalized.isEmpty {
                    values.append(normalized)
                }
            }

            values.append(contentsOf: editableDescendantTextValues(in: child, depth: depth + 1))
        }

        return values
    }

    private func looksLikeEditablePlaceholder(_ value: String) -> Bool {
        let normalized = normalizeEditablePlaceholderText(value)
        return normalized == "沟通时请保持“公开可接受”"
    }

    private func normalizeEditablePlaceholderText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clickFrame(for record: ElementRecord, snapshot: AppSnapshot) -> CGRect? {
        guard let frame = record.localFrame else {
            return nil
        }

        guard
            !record.isSyntheticText,
            let element = record.element,
            stringValue(of: element, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
            let rowFrame = containingRowFrame(for: element, textFrame: frame, windowBounds: snapshot.windowBounds)
        else {
            return frame
        }

        return rowFrame
    }

    private func containingRowFrame(for element: AXUIElement, textFrame: CGRect, windowBounds: CGRect?) -> CGRect? {
        let textCenter = CGPoint(x: textFrame.midX, y: textFrame.midY)
        var current = element

        for _ in 0..<4 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if let frame = localFrame(of: parent, windowBounds: windowBounds),
               frame.insetBy(dx: -2, dy: -2).contains(textCenter),
               frame.width >= textFrame.width + 40,
               frame.height >= textFrame.height,
               frame.height <= max(textFrame.height * 4, 96)
            {
                return frame
            }

            current = parent
        }

        return nil
    }

    private func copyActions(for element: AXUIElement) -> [String]? {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success else {
            return nil
        }

        return actions as? [String]
    }

    private func copyChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let value else {
            return []
        }

        return value as? [AXUIElement] ?? []
    }

    private func copyParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func stringValue(of element: AXUIElement, attribute: String) -> String? {
        if (attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String),
           isSecureTextField(subrole: stringValue(of: element, attribute: kAXSubroleAttribute)) {
            return nil
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }

    private func localFrame(of element: AXUIElement, windowBounds: CGRect?) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard
            positionResult == .success,
            sizeResult == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return validatedAXFrame(position: position, size: size, windowBounds: windowBounds)
    }

    private func globalPoint(for record: ElementRecord, snapshot: AppSnapshot) throws -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: CGPoint(x: frame.midX, y: frame.midY)
        )
    }

    private func clickPoint(for record: ElementRecord, snapshot: AppSnapshot) -> CGPoint? {
        clickActionPoints(for: record, snapshot: snapshot).first ?? localCenter(for: record)
    }

    private func screenshotToGlobalPoint(snapshot: AppSnapshot, x: Double, y: Double) throws -> CGPoint {
        try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: try screenshotPixelToWindowPointInSnapshot(
                snapshot: snapshot,
                point: CGPoint(x: x, y: y)
            )
        )
    }

    private func screenshotPixelToWindowPointInSnapshot(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        if snapshot.screenshotData == nil, let note = snapshot.screenshotNote {
            throw ComputerUseError.stateUnavailable(note + "; coordinate input requires a delivered screenshot")
        }
        let pixelSize = screenshotPixelSize(snapshot: snapshot)
        if Self.requiredWindowID != nil, pixelSize == nil {
            throw ComputerUseError.stateUnavailable("Bound coordinate input requires a delivered screenshot.")
        }
        return screenshotPixelToWindowPoint(
            point,
            screenshotPixelSize: pixelSize,
            windowBounds: snapshot.windowBounds
        )
    }

    private func screenshotPixelSize(snapshot: AppSnapshot) -> CGSize? {
        guard
            let screenshotData = snapshot.screenshotData,
            let imageSource = CGImageSourceCreateWithData(screenshotData as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            return nil
        }

        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private func windowPointToGlobalPoint(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        guard let windowBounds = snapshot.windowBounds else {
            let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
            throw ComputerUseError.stateUnavailable("No window bounds are available for \(appReference). Run get_app_state after bringing the app on screen.")
        }

        return CGPoint(x: windowBounds.minX + point.x, y: windowBounds.minY + point.y)
    }

    private func fixtureIdentifier(at point: CGPoint, snapshot: AppSnapshot) throws -> String {
        let candidates = snapshot.elements.values
            .filter { $0.identifier != nil && ($0.localFrame?.contains(point) ?? false) }
            .sorted { lhs, rhs in
                let lhsArea = (lhs.localFrame?.width ?? 0) * (lhs.localFrame?.height ?? 0)
                let rhsArea = (rhs.localFrame?.width ?? 0) * (rhs.localFrame?.height ?? 0)
                return lhsArea < rhsArea
            }

        guard let identifier = candidates.first?.identifier else {
            throw ComputerUseError.invalidArguments("No fixture element contains coordinate (\(Int(point.x)), \(Int(point.y)))")
        }

        return identifier
    }

    private func visualCursorTarget(for record: ElementRecord, snapshot: AppSnapshot) -> VisualCursorTarget? {
        // The accessibility element is the overlay's only immediate source of
        // truth for the window frame: the window list can keep reporting the
        // pre-move origin for about a second. The anchor carries it and the
        // overlay registers it when the animation runs.
        return makeVisualCursorTarget(
            localFrame: record.localFrame,
            windowBounds: snapshot.windowBounds,
            targetWindowID: snapshot.targetWindowID,
            targetWindowLayer: snapshot.targetWindowLayer,
            windowElement: snapshot.windowElement
        )
    }

    private func fixtureVisualCursorTarget(identifier: String, snapshot: AppSnapshot) -> VisualCursorTarget? {
        let record = snapshot.elements.values.first { $0.identifier == identifier }
        return record.flatMap { visualCursorTarget(for: $0, snapshot: snapshot) }
    }

    private func moveVisualCursor(to target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.performCursorAnimation(kind: .move) {
            SoftwareCursorOverlay.moveCursor(to: target.point, in: target.window, anchor: target.anchor)
        }
    }

    private func settleVisualCursor(at target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.performCursorAnimation {
            SoftwareCursorOverlay.settle(at: target.point, in: target.window, anchor: target.anchor)
        }
    }

    private func withVisualFeedback<T>(
        _ feedback: CursorInteractionFeedback,
        at target: VisualCursorTarget?,
        completingAt endTarget: VisualCursorTarget? = nil,
        _ deliver: () throws -> T
    ) rethrows -> T {
        guard VisualCursorSupport.isEnabled, let target else { return try deliver() }
        if feedback != .drag { moveVisualCursor(to: target) }
        VisualCursorSupport.performCursorAnimation {
            SoftwareCursorOverlay.beginFeedback(feedback, at: target.point, in: target.window, anchor: target.anchor)
        }
        do {
            let result = try deliver()
            if let endTarget { moveVisualCursor(to: endTarget) }
            let resting = endTarget ?? target
            VisualCursorSupport.performCursorAnimation {
                SoftwareCursorOverlay.endFeedback(feedback, at: resting.point, in: resting.window, anchor: resting.anchor)
            }
            return result
        } catch {
            VisualCursorSupport.performCursorAnimation {
                SoftwareCursorOverlay.cancelFeedback(feedback)
            }
            throw error
        }
    }

    private func pulseVisualCursor(at target: VisualCursorTarget?, clickCount: Int, mouseButton: MouseButtonKind) {
        guard let target else {
            return
        }

        VisualCursorSupport.performCursorAnimation {
            SoftwareCursorOverlay.pulseClick(
                at: target.point,
                clickCount: clickCount,
                mouseButton: mouseButton,
                in: target.window,
                anchor: target.anchor
            )
        }
    }

    private func debugInputFallback(tool: String, targetDescription: String, snapshot: AppSnapshot) {
        guard inputFallbackDebugEnabled(environment: RequestConfiguration.environment) else {
            return
        }

        let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
        fputs(
            "[open-computer-use] global pointer fallback tool=\(tool) app=\(appReference) target=\(targetDescription)\n",
            stderr
        )
    }

    private func debugClickDecision(_ message: String) {
        guard inputFallbackDebugEnabled(environment: RequestConfiguration.environment) else {
            return
        }

        fputs("[open-computer-use] click decision \(message)\n", stderr)
    }

    private func clickDebugDescription(_ record: ElementRecord) -> String {
        let role = record.element.flatMap { stringValue(of: $0, attribute: kAXRoleAttribute) } ?? "nil"
        let actions = record.rawActions.joined(separator: ",")
        let frame = record.localFrame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "nil"
        return "index=\(record.index) role=\(role) synthetic=\(record.isSyntheticText) actions=[\(actions)] frame=\(frame)"
    }

    /// AXScrollByPage once per page. Stops at the first refusal and reports how many pages were accepted.
    private func scrollPagesByAccessibility(_ element: AXUIElement, action: String, count: Int) throws -> (done: Int, refusal: AXError?) {
        var done = 0
        for _ in 0..<count {
            try requireUsableComputerUseSession()
            let result = AXUIElementPerformAction(element, action as CFString)
            guard result == .success else {
                return (done, result)
            }
            done += 1
        }
        return (done, nil)
    }

    private func integralScrollPageCount(_ pages: Double) -> Int? {
        let rounded = pages.rounded(.toNearestOrAwayFromZero)
        guard abs(pages - rounded) < 0.000001 else {
            return nil
        }
        return max(Int(rounded), 1)
    }

    private func performScrollEvent(
        at point: CGPoint,
        direction: String,
        pages: Double,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: RequestConfiguration.environment) {
            debugInputFallback(
                tool: "scroll",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            try raiseForGlobalPointerInput(snapshot.app)
            try InputSimulation.scrollGlobally(at: eventPoint, direction: direction, pages: pages)
            return
        }

        try InputSimulation.scrollTargeted(at: eventPoint, direction: direction, pages: pages, pid: snapshot.app.pid)
    }

    private func performDragEvent(
        from start: CGPoint,
        to end: CGPoint,
        targetDescription: String,
        snapshot: AppSnapshot,
        path: DragDeliveryPath,
        flags: CGEventFlags
    ) throws -> DragDeliveryPath {
        let eventStart = inputEventPoint(fromScreenStatePoint: start)
        let eventEnd = inputEventPoint(fromScreenStatePoint: end)

        switch path {
        case .global:
            debugInputFallback(
                tool: "drag",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            try raiseForGlobalPointerInput(snapshot.app)
            try InputSimulation.dragGlobally(from: eventStart, to: eventEnd, flags: flags)
        case .appPost:
            guard let windowID = snapshot.targetWindowID, let windowBounds = snapshot.windowBounds else {
                throw ComputerUseError.stateUnavailable("drag requires an observed target window; run get_app_state again")
            }
            try InputSimulation.dragTargeted(from: eventStart, to: eventEnd, windowBounds: windowBounds, windowID: windowID, pid: snapshot.app.pid, flags: flags)
        }

        return path
    }

    private func performNonAXClickFallback(
        at point: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: RequestConfiguration.environment) {
            debugInputFallback(
                tool: "click",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            try raiseForGlobalPointerInput(snapshot.app)
            try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)
            return
        }

        do {
            try InputSimulation.clickTargeted(
                at: eventPoint,
                button: button,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
            return
        } catch {
            guard globalPointerFallbacksEnabled(environment: RequestConfiguration.environment) else {
                throw ComputerUseError.message(
                    "click could not be handled through accessibility, and global pointer fallback is disabled. Set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 to allow physical-pointer fallback for this process."
                )
            }
        }
    }

    private func performExplicitMouseClick(
        method: ClickMethod,
        at point: CGPoint,
        windowPoint: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        switch method {
        case .appPost:
            debugClickDecision("requested=app_post executed=pid_post target=\(targetDescription)")
            try InputSimulation.clickTargeted(
                at: eventPoint,
                button: button,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
        case .skyClick:
            guard let windowBounds = snapshot.windowBounds, let windowID = snapshot.targetWindowID else {
                throw ComputerUseError.stateUnavailable(
                    "click_method 'sky_click' requires a current on-screen target window. Run get_app_state again."
                )
            }
            debugClickDecision("requested=sky_click executed=skylight_pid_post target=\(targetDescription)")
            try InputSimulation.clickWithSkyLight(
                at: eventPoint,
                windowPoint: windowPoint,
                windowBounds: windowBounds,
                windowID: windowID,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
        case .global:
            guard globalPointerFallbacksEnabled(environment: RequestConfiguration.environment) else {
                throw ComputerUseError.message(
                    "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
                )
            }
            debugClickDecision("requested=global executed=global_hid target=\(targetDescription)")
            try raiseForGlobalPointerInput(snapshot.app)
            try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)
        case .auto, .accessibility:
            throw ComputerUseError.message(
                "click_method '\(method.rawValue)' is not a direct mouse event method"
            )
        }
    }

    private func snapshotResult(for snapshot: AppSnapshot, style: SnapshotTextStyle) -> ToolCallResult {
        let text = TimingLog.measure("snapshot.render_text") { snapshot.renderedText(style: style) }
        TimingLog.count("snapshot.ax_elements", snapshot.elements.count)
        TimingLog.count("snapshot.text_bytes", text.utf8.count)
        TimingLog.count("snapshot.image_bytes", snapshot.screenshotData?.count ?? 0)
        var content = [ToolResultContentItem.text(text)]
        if snapshot.observation.includeRefs {
            content.append(.text(snapshot.elementRefs?.text ?? "No element refs available for this window."))
        }
        if let note = snapshot.screenshotNote { content.append(.text(note)) }
        if let screenshotData = snapshot.screenshotData {
            content.append(TimingLog.measure("snapshot.base64_encode") { .screenshotImage(screenshotData) })
        }
        return ToolCallResult(content: content)
    }
}


extension ComputerUseService {
    /// Roles a person types into.
    static let typingRoles: Set<String> = ["textfield", "textarea", "searchfield", "combobox"]

    /// True when exactly one enabled, settable, non-secure text element is in the observed window and it now has
    /// keyboard focus. Two or more candidates: nothing is focused, since the text could land in the wrong one.
    func focusSoleEditableTextElement(in snapshot: AppSnapshot) -> Bool {
        let candidates = snapshot.elements.values.compactMap { record -> AXUIElement? in
            guard Self.typingRoles.contains(SmartSteps.roleKey(record.role)), let element = record.element else { return nil }
            return element
        }
        var editable = candidates.filter(Self.isEditableTextTarget)
        // Web and Electron editors (contenteditable chat and search boxes) expose a text role whose value is
        // not settable. When no settable field exists, a single focusable, enabled, non-secure text element is
        // the place to type.
        if editable.isEmpty {
            editable = candidates.filter(Self.isFocusableTextTarget)
        }
        guard editable.count == 1, let field = editable.first else { return false }
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        // Web views report the new focus a little later than native fields.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        repeat {
            Thread.sleep(forTimeInterval: 0.03)
            if let now = Self.currentInputFocus(pid: snapshot.app.pid), Self.focus(now, isWithin: field) { return true }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// The focused element is the field itself or sits inside it (a contenteditable's inner paragraph).
    static func focus(_ focused: AXUIElement, isWithin field: AXUIElement) -> Bool {
        var current: AXUIElement? = focused
        for _ in 0..<6 {
            guard let element = current else { return false }
            if CFEqual(element, field) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    static func isFocusableTextTarget(_ element: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           (enabled as? Bool) == false { return false }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == "AXSecureTextField" { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func isEditableTextTarget(_ element: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           (enabled as? Bool) == false { return false }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == "AXSecureTextField" { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    func withAutoFocusNote(_ result: ToolCallResult) -> ToolCallResult {
        guard !result.isError else { return result }
        return ToolCallResult(content: [.text("Nothing editable had focus; typed into the window's only text field.")] + result.content,
                              isError: result.isError)
    }
}
