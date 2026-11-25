import AppKit
import CoreGraphics
import Foundation

func normalizedElementIndexArgument(_ value: Any?) -> String? {
    if let string = value as? String {
        return string.isEmpty ? nil : string
    }

    if let integer = value as? Int {
        return String(integer)
    }

    if let number = value as? NSNumber {
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return nil
        }

        return normalizedElementIndexNumber(number.doubleValue)
    }

    if let double = value as? Double {
        return normalizedElementIndexNumber(double)
    }

    return nil
}

private func normalizedElementIndexNumber(_ value: Double) -> String? {
    Int(exactly: value).map(String.init)
}

public final class ComputerUseToolDispatcher {
    let service: ComputerUseService

    private let actionPolicyURL: URL
    let recipeStore: BatchRecipes
    /// The `teach` tool's session (watch-me recording).
    let teach: TeachMode
    private let workspaceObservation: SharedWorkspace.Observation

    func localDecisionImage(app: String, state: String) -> Data? {
        service.localDecisionImage(app: app, state: state)
    }

    public convenience init(service: ComputerUseService = ComputerUseService()) {
        self.init(service: service, actionPolicyURL: ActionPolicy.fileURL)
    }

    init(service: ComputerUseService = ComputerUseService(), actionPolicyURL: URL, recipeStore: BatchRecipes = .shared,
         teach: TeachMode = .shared, workspaceObservation: SharedWorkspace.Observation = .system) {
        self.service = service
        self.actionPolicyURL = actionPolicyURL
        self.recipeStore = recipeStore
        self.teach = teach
        self.workspaceObservation = workspaceObservation
    }

    func currentActionPolicy() throws -> ActionPolicy { try ActionPolicy.load(from: actionPolicyURL) }

    public func callTool(name: String, arguments rawArguments: [String: Any]) throws -> ToolCallResult {
        try callTool(name: name, arguments: rawArguments, log: SmartLog())
    }

    /// The call, with the notes it collects written to `log`. A batch passes its own log per step, so the
    /// notes (a dialog that opened, a Cancel press) reach the batch reply. `notesInResult: false` keeps them out of
    /// the result text: the batch writes them itself, and a note in the text would also be read as the step's error line.
    func callTool(name: String, arguments rawArguments: [String: Any], log: SmartLog, notesInResult: Bool = true,
                  beforeNativeDispatch: (() -> Void)? = nil) throws -> ToolCallResult {
        if let value = rawArguments["strict_background"],
           !(value is NSNumber && CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()) {
            throw ComputerUseError.invalidArguments("strict_background must be true or false")
        }
        let strict = StrictBackground.enabled() || StrictBackground.requestedBy(name, arguments: rawArguments)
        return try StrictBackground.$requested.withValue(strict) {
            try callScopedTool(name: name, arguments: rawArguments, log: log,
                               notesInResult: notesInResult, beforeNativeDispatch: beforeNativeDispatch)
        }
    }

    private func callScopedTool(name: String, arguments rawArguments: [String: Any], log: SmartLog,
                                notesInResult: Bool, beforeNativeDispatch: (() -> Void)?) throws -> ToolCallResult {
        // Workflow tools return their own partial cancellation receipts.
        if name != BatchTool.name, name != HandoffTool.name { try RequestCancellation.check(delivery: .notSent) }
        // Every call (single, or a batch step) is forgiven first: wrong names, types and key spellings
        // are corrected, and a missing app is taken from the last one used. Still-missing required
        // arguments answer with one corrective line instead of reaching the app.
        let arguments = ArgumentNormalizer.normalize(
            tool: name, arguments: rawArguments, lastApp: RecentAppMemory.shared.current
        )
        let ref = try NativeSnapshotRefs.argument(in: arguments, tool: name)
        if let problem = ArgumentNormalizer.problem(tool: name, arguments: arguments) {
            throw ComputerUseError.notSent(problem)
        }
        try StrictBackground.validate(name, arguments: arguments)
        if name == "scroll", try ScrollChunks(arguments) == nil, let raw = arguments["pages"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw ComputerUseError.invalidArguments("pages must be greater than 0 and at most 100")
            }
            try ComputerUseService.validateScrollPages(number.doubleValue)
        }
        // Journal logical steps here so standalone actions, batches and handoffs share the same boundary.
        let telemetry = ToolTelemetry.current
        telemetry?.add("dispatches")
        let browserAction = (arguments["action"] as? String).map { Self.canonicalBrowserAction($0.lowercased()) }
        let clicks = name == "click" || (name == "browser" && ["click", "press", "tap"].contains(browserAction ?? ""))
        let result = try OperationJournal.recordStep(tool: name, arguments: arguments) {
            try callNormalizedTool(name: name, arguments: arguments, ref: ref, log: log,
                                   notesInResult: notesInResult, beforeNativeDispatch: beforeNativeDispatch)
        }
        if clicks {
            telemetry?.add("click_operations")
            if result.deliveryState == .notSent { telemetry?.add("click_operations_not_sent") }
        }
        if result.isError { telemetry?.add("dispatch_errors") }
        return result
    }

    private func callNormalizedTool(
        name: String, arguments: [String: Any], ref: String?, log: SmartLog, notesInResult: Bool,
        beforeNativeDispatch: (() -> Void)?
    ) throws -> ToolCallResult {
        let visualToken = try VisualSearch.actionToken(tool: name, arguments: arguments)
        let hasWindowPin = arguments["window_id"] != nil && name != "query" && name != "get_app_state"
            && name != BatchTool.name && name != HandoffTool.name
        if ref != nil || hasWindowPin {
            guard ArgumentNormalizer.windowBoundTools.contains(name) else {
                throw ComputerUseError.invalidArguments("\(name) cannot be bound to a native window")
            }
            let app = try requireString("app", in: arguments)
            let requestedWindow = try validatedQueryWindowID(arguments["window_id"])
            let target = try ref.map { try service.resolveElementRef($0, app: app) }
            if let target, let requestedWindow, target.windowID != requestedWindow {
                throw ComputerUseError.windowChanged(requestedWindow)
            }
            guard let windowID = target?.windowID ?? requestedWindow else {
                throw ComputerUseError.invalidArguments("window_id is required for a bound action")
            }
            // Ref actions take the same direct route as pinned actions. Smart
            // retries, label healing and focus borrowing cannot change the target.
            var boundArguments = arguments
            if let target { boundArguments["element_index"] = String(target.index) }
            let result = try autoreleasepool {
                try ComputerUseService.$requiredWindowID.withValue(windowID) {
                    try authorizeNativeAction(name: name, arguments: boundArguments)
                    try requireSharedWorkspace(name: name, arguments: boundArguments)
                    if let visualToken {
                        try service.validateVisualSnapshot(app: app, token: visualToken, windowID: windowID)
                    }
                    return try ComputerUseService.$requiredRefGeneration.withValue(target?.generation) {
                        try dispatchTool(name: name, arguments: boundArguments, log: log)
                    }
                }
            }
            RecentAppMemory.shared.remember(app)
            let condensed = LeanOutput.condensed(result)
            return notesInResult ? log.apply(to: condensed) : condensed
        }
        // Focus and legacy shortcuts run only after authorization.
        try authorizeNativeAction(name: name, arguments: arguments)
        try requireSharedWorkspace(name: name, arguments: arguments)
        if !backgroundOnlyMode(), name != "browser" { beforeNativeDispatch?() }
        if let app = arguments["app"] as? String, !app.isEmpty {
            RecentAppMemory.shared.remember(app)
        }

        // Calls run on threads whose autorelease pool never drains (the stdio read loop, an
        // app-agent connection), so without one per call every screenshot's bitmap and
        // encoded data stayed alive for the whole session.
        // Every state text the model sees is condensed (LeanOutput); indexes are kept.
        // A batch's state was already condensed when its own read went through here.
        // Lane 9 actions take the checked route without automatic retargeting or focus borrowing.
        if ActionOptions.usesStrictRoute(name, arguments) {
            let result = try autoreleasepool { try dispatchTool(name: name, arguments: arguments, log: log) }
            return notesInResult ? log.apply(to: LeanOutput.condensed(result)) : LeanOutput.condensed(result)
        }

        // System Settings: a pane's name opens the pane by its link (its sidebar is often unreadable).
        if !backgroundOnlyMode(), ["click", "query", "open", "press_menu", "type_text", "set_value"].contains(name),
           let app = arguments["app"] as? String, SettingsPanes.isSettings(app),
           let label = SettingsPanes.paneName(in: arguments), try SettingsPanes.open(label: label) {
            // A failed readback cannot justify running the original action too.
            guard let state = try? runWithSmartSteps(name: "get_app_state", arguments: ["app": app], log: log) else {
                return .text("Opened the \(label) pane. Read Settings to check the result.")
            }
            log.note("Opened the \(label) pane directly.")
            return LeanOutput.condensed(state)
        }
        // Finder: a double click (or open with a label) opens a folder or file; in the background the clicks do nothing.
        if !StrictBackground.enabled(), name == "click" || name == "open", let app = arguments["app"] as? String,
           FinderRename.targetsFinder(app),
           let label = arguments["label"] as? String, arguments["path"] == nil,
           name == "open" || ((arguments["click_count"] as? Int) ?? Int((arguments["click_count"] as? String) ?? "") ?? 1) >= 2,
           let opened = try FinderOpen.item(named: label) {
            guard let state = try? runWithSmartSteps(name: "get_app_state", arguments: ["app": app], log: log) else {
                return .text(opened)
            }
            log.note(opened)
            return LeanOutput.condensed(state)
        }
        // browser {"action": "batch", "steps": [...]}: the model meant a batch of web steps.
        if name == "browser", (arguments["action"] as? String)?.lowercased() == "batch", let steps = arguments["steps"] as? [Any] {
            let webSteps: [Any] = steps.map { step in
                guard var object = step as? [String: Any] else { return step }
                if object["web"] == nil { object["web"] = true }
                return object
            }
            return try callTool(name: BatchTool.name, arguments: ["steps": webSteps, "goal": arguments["goal"] ?? "web steps"], log: log, notesInResult: notesInResult)
        }
        let result: ToolCallResult
        do {
            result = try autoreleasepool { try runWithSmartSteps(name: name, arguments: arguments, log: log) }
        } catch {
            if RequestCancellation.requested { throw error }
            // Renaming in Finder: Finder's rename field takes no typing in the background. Finder's own scripting
            // renames the selected (type_text) or named (set_value) item without focus, keys or a dialog.
            // Strict background mode and policy refusals never fall back to another route.
            if StrictBackground.enabled()
                || (error as? ComputerUseError).map({ TrajectoryLog.failureCode(error: $0).isActionRefusal }) == true {
                throw error
            }
            // A failed reply can follow actual delivery. Only an explicitly unsent action can use a fallback.
            if (error as? ComputerUseError)?.deliveryState == .notSent,
               let renamed = try FinderRename.attempt(tool: name, arguments: arguments) { return renamed }
            // A click on a menu item's name ("Make Plain Text"): press that menu item.
            if name == "click", let label = arguments["label"] as? String, let app = arguments["app"] as? String,
               SmartSteps.isNotFound(error),
               let descriptor = try? AppDiscovery.resolveRunning(app),
               let path = MenuItemLookup.path(for: label, pid: descriptor.pid) {
                // "Delete", "Don't Save", "Quit": usually a dialog button the model expected. Its menu
                // namesake acts on whatever is selected, so it is never pressed in its place.
                if MenuItemLookup.isDestructive(label) {
                    throw ComputerUseError.notSent(
                        "No '\(label)' button is on screen, so nothing was clicked. \(path.joined(separator: " > ")) is a menu item that acts on the current selection; if that is what you want, use press_menu {path: \"\(path.joined(separator: " > "))\"}. If you expected a dialog, read the app state first."
                    )
                }
                let pressed = try callTool(name: "press_menu", arguments: ["app": app, "path": path.joined(separator: " > ")], log: log)
                log.note("'\(label)' is a menu item; pressed \(path.joined(separator: " > ")).")
                return pressed
            }
            // A failed native step (AdaptiveLearning): a learned recovery hint for this kind of failure is named on one
            // more line. Refusals never reach here, and send/pay/delete-type steps are never recorded (FailureSignatures).
            if !StrictBackground.enabled(), let failure = error as? ComputerUseError,
               let app = arguments["app"] as? String, !app.isEmpty {
                let bundle = (try? AppDiscovery.resolveRunning(app))?.bundleIdentifier ?? app
                let signature = FailureSignature.forStep(tool: name, arguments: arguments, error: failure, appBundleID: bundle)
                throw AdaptiveLearning.shared.hints.recordFailure(signature, error: failure)
            }
            throw error
        }
        // The step went through: a hint that this step followed is credited (AdaptiveLearning).
        if !result.isError, !StrictBackground.enabled() { AdaptiveLearning.shared.hints.recordSuccess() }
        // Opening an app comes with its state, so the model needs no separate read before acting.
        if name == "open", !result.isError, let app = arguments["app"] as? String, !app.isEmpty,
           arguments["path"] == nil, arguments["url"] == nil,
           let state = try? runWithSmartSteps(name: "get_app_state", arguments: ["app": app], log: log), !state.isError {
            if SettingsPanes.isSettings(app) {
                log.tail("To go to a pane, click it by name: click {app, label: \"Desktop & Dock\"}. The sidebar and search need not be used.")
            }
            return LeanOutput.condensed(result.replacingContent(result.content + state.content))
        }
        // A read that shows an open sheet or dialog says so in one line (with save_as for a save panel), so the
        // model handles the dialog first instead of working around it.
        if name == "get_app_state", !result.isError, let state = LeanOutput.stateText(of: result),
           RefereeSummary.dialogOpen(in: state) {
            let savePanel = state.contains("save-panel") || state.contains("Save As:")
            if StrictBackground.enabled() {
                log.tail("A sheet or dialog is open. Use accessible fields and buttons in strict background mode.")
            } else {
                log.tail("A sheet or dialog is open. Use its accessible controls. Focus borrowing requires explicit enablement."
                    + (savePanel ? " Use save_as {app, path} to name and save the file." : ""))
            }
        }
        // Each element's role and name per number is remembered when the snapshot is stored
        // (ComputerUseService.rememberSnapshot), so a number that later disappears can be healed.
        if name == "get_app_state", !result.isError, let app = arguments["app"] as? String,
           let hint = BatchRecipes.shared.hint(app: app, state: LeanOutput.stateText(of: result)) {
            log.tail(hint)
        }
        let compact = name == "get_app_state" && (arguments["compact"] as? Bool) == true
        let condensed = name == BatchTool.name || compact ? result : LeanOutput.condensed(result)
        return notesInResult ? log.apply(to: condensed) : condensed
    }

    /// One call with the smart steps around it. Only element actions get them: a stale index is re-resolved by
    /// its previous name, an action with no visible effect in a background window is retried once with focus
    /// borrowed, and a sheet, dialog or alert that opened is reported on one line.
    private func runWithSmartSteps(name: String, arguments: [String: Any], log: SmartLog) throws -> ToolCallResult {
        guard !StrictBackground.enabled(), SmartSteps.actionTools.contains(name), let app = arguments["app"] as? String, !app.isEmpty else {
            return try dispatchTool(name: name, arguments: arguments, log: log)
        }

        let frontmostPID = (try? AppDiscovery.resolveRunning(app))?.pid
        let frontmost: () -> Bool = {
            frontmostPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID
        }
        let wasFrontmost = frontmost()
        // Escape for a background app with a dialog open means "cancel the dialog": keys do not reach a
        // background sheet, and a save panel's large file list makes every extra read slow, so its Cancel
        // button is pressed straight away.
        if name == "press_key", SmartSteps.isEscapeKey(arguments["key"]), !wasFrontmost,
           let snapshot = try? service.currentSnapshot(for: app, needScreenshot: false),
           let cancel = SmartSteps.dialogCancelButton(in: SmartSteps.nodes(of: snapshot)) {
            let cancelArguments = ["app": app, "element_index": String(cancel)]
            try authorizeNativeAction(name: "click", arguments: cancelArguments)
            let result = try dispatchTool(name: "click", arguments: cancelArguments, log: log)
            log.note("A dialog was open, so Escape pressed its Cancel button.")
            return result
        }

        let before: [String]? = (FocusBorrow.isEnabled && !backgroundOnlyMode()
                                  && SmartSteps.retryTools.contains(name) && !wasFrontmost)
            ? (try? service.currentSnapshot(for: app, needScreenshot: false))?.treeLines
            : nil

        // Escape's own effect is judged against the state before it (see the Cancel fallback below).
        let escapeBefore: [String]? = (name == "press_key" && SmartSteps.isEscapeKey(arguments["key"]))
            ? (before ?? (try? service.currentSnapshot(for: app, needScreenshot: false))?.treeLines)
            : nil

        // Use the service's post-action read for dialog detection and positive changes.
        var actionObservation = NativeActionObservation()
        func dispatchAction() throws -> ToolCallResult {
            actionObservation = NativeActionObservation()
            return try ComputerUseService.$actionObservation.withValue(actionObservation) {
                try dispatchHealingStaleIndex(name: name, arguments: arguments, app: app, log: log)
            }
        }
        var result = try dispatchAction()
        var latest: AppSnapshot?

        if let before, let pid = frontmostPID, !result.isError {
            let after = actionObservation.read(before: before) {
                SmartSteps.freshSnapshot(app: app, service: service)
            }
            latest = after
            let shouldRetry = SmartSteps.shouldRetryWithoutEffect(
                actionSucceeded: true,
                before: before,
                after: after?.treeLines,
                appIsFrontmost: frontmost(),
                borrowingAllowed: FocusBorrow.isEnabled && !backgroundOnlyMode(),
                alreadyBorrowed: FocusBorrow.isBorrowed(pid: pid)
            )
            // "Reported ok, tree unchanged" does not prove the step was lost: a Send, Buy or Like click, a
            // toggle, or a shortcut can work without changing the window. Only steps that are harmless twice
            // are repeated; for the rest the model is told and decides.
            // An uncertain or independently verified action is never repeated.
            if shouldRetry, !backgroundOnlyMode(), result.deliveryState == .acknowledged,
               isSafeToRepeat(name: name, arguments: arguments, app: app, snapshot: after) {
                result = try FocusBorrow.withBorrow(pid: pid) {
                    try dispatchAction()
                }
                log.note("No visible change in the background, so the step was retried once with the app in front; focus was given back.")
                latest = actionObservation.read(before: before) {
                    SmartSteps.freshSnapshot(app: app, service: service)
                }
            } else if shouldRetry, name == "click" || name == "perform_secondary_action" || name == "press_key" {
                log.note("No visible change after this step. It was not repeated, in case it did work; if it had no effect, try another way (a label, a menu, set_value).")
            }
        }

        // Escape left a sheet or dialog open (a save panel in a background TextEdit ignored it, even in front):
        // press the dialog's own Cancel button, which is what Escape means there.
        // Only when Escape changed nothing: an Escape that closed a suggestion list inside the dialog must not
        // also cancel the dialog.
        // The sheet may still be animating out right after the key, so look again after a short wait.
        if let escapeBefore, !result.isError, result.deliveryState == .acknowledged,
           (latest ?? SmartSteps.freshSnapshot(app: app, service: service))?.treeLines == escapeBefore,
           let snapshot = { () -> AppSnapshot? in
               Thread.sleep(forTimeInterval: 0.35)
               return SmartSteps.freshSnapshot(app: app, service: service)
           }(),
           snapshot.treeLines == escapeBefore,
           let cancel = SmartSteps.dialogCancelButton(in: SmartSteps.nodes(of: snapshot)) {
            let cancelArguments = ["app": app, "element_index": String(cancel)]
            try authorizeNativeAction(name: "click", arguments: cancelArguments)
            result = try dispatchTool(name: "click", arguments: cancelArguments, log: log)
            log.note("Escape did not close the dialog, so its Cancel button was pressed.")
            latest = SmartSteps.freshSnapshot(app: app, service: service)
        }

        if !result.isError, SmartSteps.actionTools.contains(name) {
            let snapshot = latest ?? actionObservation.read {
                SmartSteps.freshSnapshot(app: app, service: service)
            }
            log.afterActionSnapshot = snapshot
            if let snapshot, let line = SmartSteps.dialogLine(in: SmartSteps.nodes(of: snapshot)) {
                log.tail(line)
            }
        }
        return result
    }

    /// Whether running the step a second time cannot do harm: Escape, or a click on something that only takes
    /// focus or selection (a text field, a tab, a radio button, a row). Everything else might act twice.
    private func isSafeToRepeat(name: String, arguments: [String: Any], app: String, snapshot: AppSnapshot?) -> Bool {
        if name == "press_key" { return SmartSteps.isEscapeKey(arguments["key"]) }
        guard name == "click", let snapshot else { return false }
        // A double click, or a right click (which may open a menu that a second press closes), is not repeated.
        guard (optionalDouble("click_count", in: arguments) ?? 1) == 1,
              (arguments["mouse_button"] as? String ?? "left").lowercased() == "left" else { return false }
        var record: ElementRecord?
        if let index = normalizedElementIndexArgument(arguments["element_index"]) {
            record = snapshot.elements.values.first { String($0.index) == index }
        } else if let labels = labelArguments(in: arguments) {
            record = try? service.resolveLabel(app: app, labels: labels)
        }
        guard let record else { return false }
        return SmartSteps.repeatSafeRoles.contains(SmartSteps.roleKey(record.role))
            || SmartSteps.repeatSafeRoles.contains(SmartSteps.roleKey(record.identity?.subrole))
    }

    /// Runs an element action. When its element_index is gone or no longer shows what the last read showed, the
    /// element is found again by its remembered role and name, if exactly one control has them now; otherwise the
    /// caller gets the stale message with the candidates (nothing was sent).
    private func dispatchHealingStaleIndex(name: String, arguments: [String: Any], app: String, log: SmartLog) throws -> ToolCallResult {
        let priorIndex = normalizedElementIndexArgument(arguments["element_index"])
        var prior: (role: String?, label: String?)?
        var priorWindow: NativeWindowObservation?
        if let index = priorIndex {
            let snapshot = try? service.currentSnapshot(for: app, needScreenshot: false)
            priorWindow = snapshot?.nativeWindow
            if let record = snapshot?.elements.values.first(where: { String($0.index) == index }) {
                prior = (SmartSteps.roleKey(record.role), SmartSteps.name(of: record))
            } else if let snapshot, let number = Int(index),
                      let known = ElementNumbering.forApp(pid: snapshot.app.pid).remembered(number) {
                prior = (known.role, known.label)
            }
            if prior?.label == nil, let given = arguments["label"] as? String, !given.isEmpty {
                prior = (prior?.role, given)
            }
        }
        do {
            return try dispatchTool(name: name, arguments: arguments, log: log)
        } catch let error as ComputerUseError where SmartSteps.isStale(error) || ElementNumbering.isGone(error) {
            guard let index = priorIndex, let prior, prior.label != nil, let priorWindow else { throw error }
            // A new front window can contain an identical control. Read the original window only;
            // neither a user's window switch nor a process restart may redirect a healed action.
            _ = try service.getAppState(app: app,
                observation: SnapshotObservationOptions(includeAX: true, includeScreenshot: false), windowID: priorWindow.id)
            let fresh = try service.currentSnapshot(for: app, needScreenshot: false, recoveryPolicy: .readOnly)
            switch StaleHealing.recover(index: index, role: prior.role, label: prior.label,
                                        observedWindow: priorWindow, currentWindow: fresh.nativeWindow,
                                        nodes: SmartSteps.nodes(of: fresh)) {
            case .refuse(let message):
                throw ComputerUseError.staleTarget(message)
            case .use(let now, let note):
                log.note(note)
                var retried = arguments
                retried["element_index"] = String(now)
                retried["window_id"] = priorWindow.id
                return try ComputerUseService.$requiredWindowID.withValue(priorWindow.id) {
                    try authorizeNativeAction(name: name, arguments: retried)
                    return try dispatchTool(name: name, arguments: retried, log: log)
                }
            }
        }
    }

    /// The label resolved as usual; when no control has that name, a close match or a text query may find the
    /// one it means (noted in the reply). Several close matches are listed, never guessed between.
    private func resolveLabelHealing(app: String, labels: [String], log: SmartLog, forValue: Bool = false) throws -> ElementRecord {
        if ComputerUseService.requiredWindowID != nil {
            return try service.resolveLabel(app: app, labels: labels)
        }
        do {
            return try service.resolveLabel(app: app, labels: labels)
        } catch let error as ComputerUseError where SmartSteps.isNotFound(error) || (forValue && SmartSteps.isAmbiguous(error)) {
            // For a value, a label shared by a field and other controls means the field.
            if forValue, SmartSteps.isAmbiguous(error), let wanted = labels.first,
               let snapshot = SmartSteps.freshSnapshot(app: app, service: service),
               let index = SmartSteps.captionField(for: wanted, in: SmartSteps.nodes(of: snapshot)),
               let record = snapshot.elements.values.first(where: { $0.index == index }) {
                return record
            }
            guard SmartSteps.isNotFound(error) else { throw error }
            guard let wanted = labels.first,
                  let healed = try SmartSteps.healLabel(wanted, app: app, service: service, forValue: forValue) else {
                throw error
            }
            log.note(healed.note)
            return healed.record
        }
    }

    private func dispatchTool(name: String, arguments: [String: Any], log: SmartLog) throws -> ToolCallResult {
        // Smart fallbacks can reach the native dispatcher without another tool call.
        if name != BatchTool.name, name != HandoffTool.name { try RequestCancellation.check() }
        try requireSharedWorkspace(name: name, arguments: arguments)
        switch name {
        case BatchTool.name:
            // The goal and step number go into each journaled intent, so a restart notice can name them.
            return try OperationJournal.withBatchGoal(arguments["goal"] as? String ?? "") { try runBatch(arguments: arguments) }
        case HandoffTool.name:
            return try runHandoff(arguments: arguments)
        case LocalDecisionTool.name:
            return try LocalDecisionTool.run(arguments: arguments, baseURL: LocalDecisionTool.baseURL())
        case "browser":
            return try runBrowser(arguments: arguments)
        case SmartSteps.saveAsName:
            return try SmartSteps.saveAs(
                app: requireString("app", in: arguments),
                path: requireString("path", in: arguments),
                service: service
            )
        case SmartSteps.openName:
            return try SmartSteps.open(arguments: arguments, browser: { try self.callTool(name: "browser", arguments: $0) })
        case TeachMode.toolName:
            // The window is read with get_app_state, so a saved recipe is tied to the window it was recorded in.
            return try teach.run(arguments: arguments, readState: { app in
                (try? self.callTool(name: "get_app_state", arguments: ["app": app])).map { BatchTool.stateText(of: $0) }
            })
        case "clipboard":
            let clipboard = PrivateClipboard.current
            switch try requireString("action", in: arguments).lowercased() {
            case "write":
                try clipboard.writeText(requireString("text", in: arguments, allowEmpty: true))
                return .text("Stored text on the private clipboard.")
            case "read":
                switch clipboard.payload {
                case .text(let text): return .text(text)
                case .files(let paths, _): return .text(paths.joined(separator: "\n"))
                case nil: return .text("Private clipboard is empty.")
                }
            case "clear":
                clipboard.clear()
                return .text("Private clipboard cleared.")
            default:
                throw ComputerUseError.invalidArguments("clipboard action must be read, write, or clear.")
            }
        case "list_apps":
            return service.listApps()
        case "query":
            // The targeted search or a full-tree read, whichever ReadRouting has learned to be better for this app.
            let matches = try ReadRouting.query(
                service: service,
                app: requireString("app", in: arguments),
                text: try validatedQueryString(arguments["text"], key: "text"),
                role: try validatedQueryString(arguments["role"], key: "role"),
                exact: try validatedQueryExact(arguments["exact"]),
                limit: try optionalPositiveInt("limit", in: arguments) ?? 20,
                maxNodes: try optionalPositiveInt("max_nodes", in: arguments) ?? 500,
                windowID: try validatedQueryWindowID(arguments["window_id"])
            )
            return .text(try renderedQueryMatches(matches))
        case "get_app_state":
            // A settle wait the caller asked for is capped by the tuned wait when that is shorter (ReadRouting).
            let stateApp = try requireString("app", in: arguments)
            let stateWindow = try validatedQueryWindowID(arguments["window_id"])
            let visualQueries = try VisualSearch.queries(arguments["visual_queries"])
            let visualRegion = try VisualSearch.region(arguments["visual_region"])
            if visualRegion != nil, visualQueries.isEmpty {
                throw ComputerUseError.invalidArguments("visual_region requires visual_queries.")
            }
            if !visualQueries.isEmpty {
                guard stateWindow != nil,
                      try strictObservationBool("include_ax", in: arguments),
                      try strictObservationBool("include_screenshot", in: arguments, default: false) else {
                    throw ComputerUseError.invalidArguments("visual_queries requires window_id, include_ax and include_screenshot: true.")
                }
            }
            let settle = ReadRouting.settlePlan(requested: try optionalSettleMs(in: arguments), app: stateApp, windowID: stateWindow)
            let settleStarted = Date()
            let state = try service.getAppState(
                app: stateApp,
                textLimit: try optionalTextLimit("text_limit", in: arguments) ?? .defaults,
                treeLimits: AccessibilityTreeLimits.defaults.replacing(
                    maxNodeCount: try optionalPositiveInt("max_tree_nodes", in: arguments),
                    maxDepth: try optionalPositiveInt("max_tree_depth", in: arguments)
                ),
                windowPlacement: try parseWindowPlacement(optionalString("window_placement", in: arguments)),
                observation: SnapshotObservationOptions(
                    includeAX: try strictObservationBool("include_ax", in: arguments),
                    includeScreenshot: try strictObservationBool(
                        "include_screenshot", in: arguments, default: LeanDefaults.includeScreenshot
                    ),
                    includeRefs: try strictObservationBool("include_refs", in: arguments, default: false),
                    // The menu tree is separate from the window's controls.
                    includeMenuBar: try strictObservationBool("include_menu_bar", in: arguments, default: false)
                ),
                settleMs: settle.wait,
                compact: visualQueries.isEmpty ? try strictObservationBool(
                    "compact", in: arguments,
                    default: LeanOutput.usesCompactReads
                ) : false,
                windowID: stateWindow
            )
            ReadRouting.recordSettle(settle.tuned, result: state, startedAt: settleStarted, app: stateApp)
            if let stateWindow, !visualQueries.isEmpty {
                return try VisualSearch.annotate(state, queries: visualQueries, region: visualRegion, windowID: stateWindow)
            }
            return state
        case "click":
            // Precise clicks use one window-addressed route and never fall back to vision.
            if ActionOptions.usesStrictRoute(name, arguments) {
                let app = try requireString("app", in: arguments)
                let method = try parseClickMethod(optionalString("click_method", in: arguments))
                guard method == .auto || method == .appPost else {
                    throw ComputerUseError.backgroundUnsupported("Precise clicks use window-addressed delivery.")
                }
                let count = try ActionOptions.integer("click_count", in: arguments, range: 1...3) ?? 1
                let button = optionalString("mouse_button", in: arguments) ?? "left"
                let modifiers = arguments["modifiers"] as? [String]
                guard arguments["modifiers"] == nil || modifiers != nil else {
                    throw ComputerUseError.invalidArguments("modifiers must be an array of key names")
                }
                let index = try strictActionIndex(app: app, arguments: arguments)
                return try service.preciseClick(app: app, elementIndex: index,
                    x: optionalDouble("x", in: arguments), y: optionalDouble("y", in: arguments),
                    placement: ClickPlacement(arguments), hasPlacement: ClickPlacement.isRequested(arguments),
                    count: count, buttonName: button, modifiers: modifiers ?? [])
            }
            let clickCount = try optionalPositiveInt("click_count", in: arguments) ?? 1
            guard clickCount <= 32 else {
                throw ComputerUseError.invalidArguments("click_count must be between 1 and 32")
            }
            let elementIndex: String?
            // A pixel click needs both points; one of them alone would click somewhere the model did not mean.
            if optionalDouble("x", in: arguments) != nil || optionalDouble("y", in: arguments) != nil,
               optionalDouble("x", in: arguments) == nil || optionalDouble("y", in: arguments) == nil,
               labelArguments(in: arguments) == nil, optionalElementIndex(in: arguments) == nil {
                throw ComputerUseError.invalidArguments("click at pixels needs both x and y (from a screenshot)")
            }
            do {
                elementIndex = try labelledElementIndex(in: arguments, log: log) ?? optionalElementIndex(in: arguments)
            } catch let error as ComputerUseError {
                // Only a real, unambiguous label miss can use the local perception path (OCR, then the vision
                // model), never in strict background mode or for a window-bound action.
                if ComputerUseService.allowsLocalPerceptionFallback(error: error, strict: StrictBackground.enabled(),
                   windowBound: ComputerUseService.requiredWindowID != nil, clickCount: clickCount,
                   mouseButton: optionalString("mouse_button", in: arguments) ?? "left"),
                   let label = labelArguments(in: arguments)?.first,
                   let result = try service.visionClick(app: requireString("app", in: arguments), label: label,
                                                       method: parseClickMethod(optionalString("click_method", in: arguments))) {
                    return result
                }
                throw error
            }
            return try service.click(
                app: requireString("app", in: arguments),
                elementIndex: elementIndex,
                x: optionalDouble("x", in: arguments),
                y: optionalDouble("y", in: arguments),
                clickCount: clickCount,
                mouseButton: optionalString("mouse_button", in: arguments) ?? "left",
                clickMethod: try parseClickMethod(optionalString("click_method", in: arguments))
            )
        case "perform_secondary_action":
            return try service.performSecondaryAction(
                app: requireString("app", in: arguments),
                elementIndex: labelledOrRequiredElementIndex(in: arguments, log: log),
                action: requireString("action", in: arguments)
            )
        case "hover":
            if let dwell = try ActionOptions.duration("dwell_ms", in: arguments, maxMs: 2000) {
                let app = try requireString("app", in: arguments)
                return try service.hover(app: app, elementIndex: requireStrictActionIndex(app: app, arguments: arguments), dwell: dwell)
            }
            return try service.hover(
                app: requireString("app", in: arguments),
                elementIndex: labelledOrRequiredElementIndex(in: arguments, log: log)
            )
        case "gesture":
            let app = try requireString("app", in: arguments)
            let gesture = try GestureAction(arguments: arguments)
            if arguments["menu_path"] != nil {
                guard ComputerUseService.requiredWindowID == nil else {
                    throw ComputerUseError.backgroundUnsupported("An app-level gesture menu command cannot be pinned to a window.")
                }
                guard labelArguments(in: arguments) == nil, optionalElementIndex(in: arguments) == nil else {
                    throw ComputerUseError.invalidArguments("Use a menu command or a control for the gesture.")
                }
                let path = try menuPathArgument(arguments["menu_path"])
                guard path.count >= 2 else {
                    throw ComputerUseError.invalidArguments("Give the menu and command, such as View > Zoom In.")
                }
                // A gesture stands in for zoom, rotate or history. A destructive command is never one.
                if let title = path.last, MenuItemLookup.isDestructive(title) || ShortcutCache.isDestructive(title) {
                    throw ComputerUseError.notSent("\(title) is not a gesture equivalent. Use press_menu if that is really what you want.")
                }
                return try service.pressMenu(app: app, titles: path)
            }
            guard let increase = gesture.zoomIncreases,
                  let index = try strictActionIndex(app: app, arguments: arguments) else {
                throw ComputerUseError.backgroundUnsupported("This gesture needs an exposed app menu command or zoom control.")
            }
            return try service.zoomControl(app: app, elementIndex: index, increase: increase)
        case "wait_for":
            guard let wait = try ControlWait(arguments) else {
                throw ComputerUseError.invalidArguments("wait_for requires appears, disappears or value_changed.")
            }
            return try service.waitForControl(app: requireString("app", in: arguments), wait: wait)
        case "scroll_into_view":
            let app = try requireString("app", in: arguments)
            return try service.scrollIntoView(app: app, elementIndex: requireStrictActionIndex(app: app, arguments: arguments))
        case "scroll":
            // Explicit chunks use a pinned scroll area and verify progress after each input.
            if let chunks = try ScrollChunks(arguments) {
                let app = try requireString("app", in: arguments)
                return try service.scroll(
                    app: app, direction: requireString("direction", in: arguments),
                    elementIndex: requireStrictActionIndex(app: app, arguments: arguments),
                    chunks: chunks
                )
            }
            return try service.scroll(
                app: requireString("app", in: arguments),
                direction: requireString("direction", in: arguments),
                elementIndex: labelledOrRequiredElementIndex(in: arguments, log: log),
                pages: optionalDouble("pages", in: arguments) ?? 1
            )
        case "drag":
            let modifiers = arguments["modifiers"] as? [String]
            guard arguments["modifiers"] == nil || modifiers != nil else {
                throw ComputerUseError.invalidArguments("drag modifiers must be an array of strings")
            }
            // Extended drags resolve both endpoints before the only press.
            if DragOptions.isRequested(arguments) {
                let app = try requireString("app", in: arguments)
                let options = try DragOptions(arguments)
                let sourceArguments = ["label": arguments["from_label"] ?? arguments["label"],
                                       "element_index": arguments["from_index"] ?? arguments["element_index"]]
                let destinationArguments = ["label": arguments["to_label"], "element_index": arguments["to_index"]]
                let source = try strictActionIndex(app: app, arguments: sourceArguments.compactMapValues { $0 })
                let destination = try strictActionIndex(app: app, arguments: destinationArguments.compactMapValues { $0 })
                return try service.dragBetween(app: app, sourceIndex: source, destinationIndex: destination,
                    fromX: optionalDouble("from_x", in: arguments), fromY: optionalDouble("from_y", in: arguments),
                    toX: optionalDouble("to_x", in: arguments), toY: optionalDouble("to_y", in: arguments),
                    modifiers: modifiers ?? [], options: options)
            }
            return try service.drag(
                app: requireString("app", in: arguments),
                fromX: requireDouble("from_x", in: arguments),
                fromY: requireDouble("from_y", in: arguments),
                toX: requireDouble("to_x", in: arguments),
                toY: requireDouble("to_y", in: arguments),
                modifiers: modifiers ?? []
            )
        case "type_text":
            let app = try requireString("app", in: arguments)
            let text = try requireString("text", in: arguments)
            let keyMethod = try parseKeyMethod(optionalString("key_method", in: arguments))
            // replace: true selects what the focused field holds (cmd+a) before typing, so a search
            // box or contenteditable that set_value cannot write gets the new text instead of an
            // appended one. Seen in Discord search (2026-11-19).
            let replaceRaw = arguments["replace"] ?? arguments["replace_existing"] ?? arguments["clear"] ?? arguments["clear_first"]
            let replace = (replaceRaw as? Bool) ?? ["1", "true", "yes", "on"].contains(((replaceRaw as? String) ?? "").lowercased())
            if replace {
                _ = try service.pressKey(app: app, key: "cmd+a", keyMethod: keyMethod)
            }
            return try service.typeText(app: app, text: text, keyMethod: keyMethod)
        case "press_key":
            if let hold = try ActionOptions.duration("hold_ms", in: arguments, maxMs: 1000) {
                return try service.holdKey(app: requireString("app", in: arguments), key: requireString("key", in: arguments),
                    method: parseKeyMethod(optionalString("key_method", in: arguments)), hold: hold)
            }
            return try service.pressKey(
                app: requireString("app", in: arguments),
                key: requireString("key", in: arguments),
                keyMethod: try parseKeyMethod(optionalString("key_method", in: arguments))
            )
        case "press_menu":
            if arguments["file_path"] != nil || arguments["new_name"] != nil {
                return try service.finderFileCommand(
                    app: requireString("app", in: arguments),
                    titles: try menuPathArgument(arguments["path"]),
                    path: requireString("file_path", in: arguments),
                    newName: try arguments["new_name"].map { _ in try requireString("new_name", in: arguments) }
                )
            }
            return try service.pressMenu(
                app: requireString("app", in: arguments),
                titles: try menuPathArgument(arguments["path"])
            )
        case "set_value":
            let app = try requireString("app", in: arguments)
            if let labels = labelArguments(in: arguments) {
                let record = try resolveLabelHealing(app: app, labels: labels, log: log, forValue: true)
                let value = try requireString("value", in: arguments, allowEmpty: true)
                // set_value on a toggle does nothing in most apps: click it, only if its state differs.
                if ComputerUseService.isToggleRole(record.role) {
                    let on: (String?) -> Bool = { ["1", "true", "on", "yes"].contains(($0 ?? "").lowercased()) }
                    if on(value) == on(record.value) { return .text("already \(on(value) ? "on" : "off")") }
                    return try service.click(app: app, elementIndex: String(record.index), x: nil, y: nil,
                                             clickCount: 1, mouseButton: "left", clickMethod: .auto)
                }
                return try service.setValue(app: app, elementIndex: String(record.index), value: value)
            }
            return try service.setValue(
                app: app,
                elementIndex: requireElementIndex(in: arguments),
                value: requireString("value", in: arguments, allowEmpty: true)
            )
        case "select_text":
            // Explicit ranges need a named or observed control and verify the resulting AX range.
            if let range = try TextRangeRequest(arguments) {
                let app = try requireString("app", in: arguments)
                return try service.selectText(app: app, elementIndex: requireStrictActionIndex(app: app, arguments: arguments),
                    text: "", prefix: nil, suffix: nil, selection: .text, range: range)
            }
            return try service.selectText(
                app: requireString("app", in: arguments),
                elementIndex: labelledOrRequiredElementIndex(in: arguments, log: log),
                text: requireString("text", in: arguments),
                prefix: try selectionString("prefix", in: arguments),
                suffix: try selectionString("suffix", in: arguments),
                selection: try parseSelectionMode(try selectionString("selection", in: arguments))
            )
        default:
            throw ComputerUseError.unsupportedTool(name)
        }
    }

    private func requireSharedWorkspace(name: String, arguments: [String: Any]) throws {
        try SharedWorkspace.requireAvailable(tool: name, arguments: arguments,
            backgroundOnly: backgroundOnlyMode(), pinnedWindowID: ComputerUseService.requiredWindowID,
            observation: workspaceObservation)
    }

    /// The batch can check its result in the ref's window without an app-wide read.
    func observedNativeRefWindow(in arguments: [String: Any]) -> UInt32? {
        guard let ref = arguments["ref"] as? String, let app = arguments["app"] as? String else { return nil }
        return try? service.resolveElementRef(ref, app: app).windowID
    }

    public func callToolAsResult(name: String, arguments: [String: Any]) -> ToolCallResult {
        callStepAsResult(name: name, arguments: arguments, log: SmartLog())
    }

    func callStepAsResult(name: String, arguments: [String: Any], log: SmartLog, notesInResult: Bool = true,
                          beforeNativeDispatch: (() -> Void)? = nil) -> ToolCallResult {
        let result: ToolCallResult
        do {
            result = try callTool(name: name, arguments: arguments, log: log, notesInResult: notesInResult,
                                  beforeNativeDispatch: beforeNativeDispatch)
        } catch {
            result = .failure(error)
        }
        // A Save, Export or save chord that failed in the background with borrowing off: say it needs focus borrowing.
        guard result.isError, !FocusBorrow.isEnabled, name == "press_menu" || name == "press_key",
              let app = arguments["app"] as? String, let pid = (try? AppDiscovery.resolveRunning(app))?.pid else {
            return result
        }
        return FocusBorrow.dialogStepReply(
            result, opensDialog: opensDialog(tool: name, arguments: arguments, pid: pid),
            appIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, enabled: false
        )
    }

    private func requireString(_ key: String, in arguments: [String: Any], allowEmpty: Bool = false) throws -> String {
        guard let value = arguments[key] as? String, allowEmpty || !value.isEmpty else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    private func strictObservationBool(_ key: String, in arguments: [String: Any], default fallback: Bool = true) throws -> Bool {
        guard let value = arguments[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ComputerUseError.invalidArguments("\(key) must be a boolean")
        }
        return number.boolValue
    }

    private func optionalBool(_ key: String, in arguments: [String: Any]) -> Bool? {
        switch arguments[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return Bool(value.lowercased())
        default: return nil
        }
    }

    /// Machine-readable matches with explicit completeness metadata.
    private func renderedQueryMatches(_ matches: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: matches, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.stateUnavailable("Query response could not be encoded")
        }
        return text
    }

    private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
        arguments[key] as? String
    }

    /// `press_menu`'s path: "File > Save", "File/Save", or ["File", "Save"].
    private func menuPathArgument(_ value: Any?) throws -> [String] {
        guard let value else {
            throw ComputerUseError.missingArgument("path")
        }
        if let path = value as? String {
            return try menuPathTitles(path)
        }
        if let parts = value as? [Any] {
            let strings = parts.compactMap { $0 as? String }
            guard strings.count == parts.count else {
                throw ComputerUseError.invalidArguments("path must be a string or an array of menu titles")
            }
            return try menuPathTitles(strings)
        }
        throw ComputerUseError.invalidArguments("path must be a string or an array of menu titles")
    }

    func selectionString(_ key: String, in arguments: [String: Any]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else {
            throw ComputerUseError.invalidArguments("\(key) must be a string")
        }
        return string
    }

    func parseSelectionMode(_ raw: String?) throws -> TextSelectionMode {
        guard let raw else { return .text }

        guard let mode = TextSelectionMode(rawValue: raw) else {
            throw ComputerUseError.message(
                "selection must be one of \(TextSelectionMode.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        return mode
    }

    private func optionalTextLimit(_ key: String, in arguments: [String: Any]) throws -> SnapshotTextLimit? {
        guard let value = arguments[key] else {
            return nil
        }

        if let string = value as? String {
            guard string.lowercased() == SnapshotTextLimit.maxKeyword else {
                throw ComputerUseError.invalidArguments("\(key) must be a positive integer or max")
            }
            return .max
        }

        let maxCount = try positiveInt(from: value, key: key, expectedDescription: "a positive integer or max")
        return SnapshotTextLimit(maxCount: maxCount)
    }

    private func requireElementIndex(in arguments: [String: Any]) throws -> String {
        guard let value = optionalElementIndex(in: arguments) else {
            throw ComputerUseError.missingArgument("element_index")
        }

        return value
    }

    /// "label": "Seven" or "labels": ["+", "add"] (first match wins), resolved in the current window.
    func labelArguments(in arguments: [String: Any]) -> [String]? {
        if let many = arguments["labels"] as? [String], !many.isEmpty { return many }
        if let one = arguments["label"] as? String, !one.isEmpty { return [one] }
        return nil
    }

    private func labelledElementIndex(in arguments: [String: Any], log: SmartLog) throws -> String? {
        guard optionalElementIndex(in: arguments) == nil, let labels = labelArguments(in: arguments) else { return nil }
        return String(try resolveLabelHealing(app: try requireString("app", in: arguments), labels: labels, log: log).index)
    }

    /// An element named by `label`/`labels` (its visible name) or by `element_index`, for actions that need one.
    // New actions do not use label healing or a vision fallback.
    private func strictActionIndex(app: String, arguments: [String: Any]) throws -> String? {
        if let index = optionalElementIndex(in: arguments) { return index }
        guard let labels = labelArguments(in: arguments) else { return nil }
        return String(try service.resolveLabel(app: app, labels: labels, strict: true).index)
    }

    private func requireStrictActionIndex(app: String, arguments: [String: Any]) throws -> String {
        guard let index = try strictActionIndex(app: app, arguments: arguments) else {
            throw ComputerUseError.missingArgument("label or element_index")
        }
        return index
    }

    private func labelledOrRequiredElementIndex(in arguments: [String: Any], log: SmartLog) throws -> String {
        try labelledElementIndex(in: arguments, log: log) ?? requireElementIndex(in: arguments)
    }

    func optionalElementIndex(in arguments: [String: Any]) -> String? {
        normalizedElementIndexArgument(arguments["element_index"])
    }

    private func requireDouble(_ key: String, in arguments: [String: Any]) throws -> Double {
        guard let value = optionalDouble(key, in: arguments) else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    private func optionalDouble(_ key: String, in arguments: [String: Any]) -> Double? {
        if let double = arguments[key] as? Double {
            return double
        }

        if let integer = arguments[key] as? Int {
            return Double(integer)
        }

        if let number = arguments[key] as? NSNumber {
            return number.doubleValue
        }

        return nil
    }

    /// settle_ms: a positive number of ms to wait while the window is busy; 0 means do not wait (a batch's own
    /// reads send 0, which used to fail as "must be a positive integer" and silently disabled effects and waits).
    private func optionalSettleMs(in arguments: [String: Any]) throws -> Int? {
        if let number = arguments["settle_ms"] as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
           number.doubleValue == 0 {
            return nil
        }
        return try optionalPositiveInt("settle_ms", in: arguments)
    }

    private func optionalPositiveInt(_ key: String, in arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[key] else {
            return nil
        }

        return try positiveInt(from: value, key: key, expectedDescription: "a positive integer")
    }

    private func positiveInt(from value: Any, key: String, expectedDescription: String) throws -> Int {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }
        if let integer = value as? Int {
            return try validatePositiveInt(integer, key: key, expectedDescription: expectedDescription)
        }

        if let double = value as? Double {
            return try validatePositiveWholeNumber(double, key: key, expectedDescription: expectedDescription)
        }

        if let number = value as? NSNumber {
            return try validatePositiveWholeNumber(number.doubleValue, key: key, expectedDescription: expectedDescription)
        }

        throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
    }

    private func validatePositiveWholeNumber(_ value: Double, key: String, expectedDescription: String) throws -> Int {
        guard value.isFinite, value.rounded(.towardZero) == value else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }

        guard let integer = Int(exactly: value) else {
            throw ComputerUseError.invalidArguments("\(key) is outside the supported integer range")
        }

        return try validatePositiveInt(integer, key: key, expectedDescription: expectedDescription)
    }

    private func validatePositiveInt(_ value: Int, key: String, expectedDescription: String) throws -> Int {
        guard value > 0 else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }
        return value
    }
}

public struct OpenComputerUseCallSpec {
    public let tool: String
    public let arguments: [String: Any]

    public init(tool: String, arguments: [String: Any]) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct OpenComputerUseCallOutput {
    public let jsonObject: Any
    public let hasToolError: Bool

    public init(jsonObject: Any, hasToolError: Bool) {
        self.jsonObject = jsonObject
        self.hasToolError = hasToolError
    }

    public func jsonText() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode call output as JSON.")
        }
        return text
    }
}

public typealias OpenComputerUseSleepHandler = (TimeInterval) -> Void

public func runOpenComputerUseCall(
    _ invocation: OpenComputerUseCallInvocation,
    service: ComputerUseService = ComputerUseService(),
    sleepHandler: OpenComputerUseSleepHandler = { Thread.sleep(forTimeInterval: $0) }
) throws -> OpenComputerUseCallOutput {
    let dispatcher = ComputerUseToolDispatcher(service: service)

    switch invocation {
    case let .single(toolName, argumentsJSON, argumentsFile):
        let arguments = try readOpenComputerUseToolArguments(
            json: argumentsJSON,
            file: argumentsFile
        )
        let result = dispatcher.callToolAsResult(name: toolName, arguments: arguments)
        return OpenComputerUseCallOutput(
            jsonObject: result.asDictionary,
            hasToolError: result.isError
        )

    case let .sequence(callsJSON, callsFile, interCallDelay):
        let calls = try readOpenComputerUseCallSequence(json: callsJSON, file: callsFile)
        var outputs: [[String: Any]] = []
        var hasToolError = false

        for (index, call) in calls.enumerated() {
            let result = dispatcher.callToolAsResult(name: call.tool, arguments: call.arguments)
            outputs.append([
                "tool": call.tool,
                "result": result.asDictionary,
            ])

            if result.isError {
                hasToolError = true
                break
            }

            if index < calls.count - 1, interCallDelay > 0 {
                sleepHandler(interCallDelay)
            }
        }

        return OpenComputerUseCallOutput(jsonObject: outputs, hasToolError: hasToolError)
    }
}

public func readOpenComputerUseToolArguments(
    json: String?,
    file: String?
) throws -> [String: Any] {
    guard let source = try readOpenComputerUseJSONSource(json: json, file: file) else {
        return [:]
    }

    let object = try decodeOpenComputerUseJSONObject(source)
    guard let arguments = object as? [String: Any] else {
        throw OpenComputerUseCLIError(message: "--args must be a JSON object", helpCommand: "call")
    }

    return arguments
}

public func readOpenComputerUseCallSequence(
    json: String?,
    file: String?
) throws -> [OpenComputerUseCallSpec] {
    guard let source = try readOpenComputerUseJSONSource(json: json, file: file) else {
        throw OpenComputerUseCLIError(message: "call sequence requires --calls or --calls-file", helpCommand: "call")
    }

    let object = try decodeOpenComputerUseJSONObject(source)
    guard let array = object as? [Any] else {
        throw OpenComputerUseCLIError(message: "--calls must be a JSON array", helpCommand: "call")
    }

    return try array.enumerated().map { index, item in
        guard let dictionary = item as? [String: Any] else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) must be a JSON object",
                helpCommand: "call"
            )
        }

        guard let tool = (dictionary["tool"] ?? dictionary["name"]) as? String, !tool.isEmpty else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) requires a non-empty tool",
                helpCommand: "call"
            )
        }

        let rawArguments = dictionary["args"] ?? dictionary["arguments"] ?? [:]
        guard let arguments = rawArguments as? [String: Any] else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) args must be a JSON object",
                helpCommand: "call"
            )
        }

        return OpenComputerUseCallSpec(tool: tool, arguments: arguments)
    }
}

private func readOpenComputerUseJSONSource(json: String?, file: String?) throws -> String? {
    if json != nil, file != nil {
        throw OpenComputerUseCLIError(message: "Use either inline JSON or a JSON file, not both", helpCommand: "call")
    }

    if let json {
        return json
    }

    guard let file else {
        return nil
    }

    do {
        return try String(contentsOfFile: file, encoding: .utf8)
    } catch {
        throw OpenComputerUseCLIError(
            message: "Unable to read JSON file \(file): \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}

private func decodeOpenComputerUseJSONObject(_ source: String) throws -> Any {
    guard let data = source.data(using: .utf8) else {
        throw OpenComputerUseCLIError(message: "JSON input must be UTF-8 text", helpCommand: "call")
    }

    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw OpenComputerUseCLIError(
            message: "Invalid JSON input: \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}

func validatedQueryWindowID(_ value: Any?) throws -> CGWindowID? {
    guard let value else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 1,
          number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded(.down) == number.doubleValue else {
        throw ComputerUseError.invalidArguments("window_id must be an integer from 1 to \(UInt32.max)")
    }
    return CGWindowID(number.doubleValue)
}

func validatedQueryString(_ value: Any?, key: String) throws -> String? {
    guard let value else { return nil }
    guard let string = value as? String, string.utf16.count <= 1000 else {
        throw ComputerUseError.invalidArguments("\(key) must be a string of at most 1000 UTF-16 code units")
    }
    return string
}

func validatedQueryExact(_ value: Any?) throws -> Bool {
    guard let value else { return false }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw ComputerUseError.invalidArguments("exact must be true or false")
    }
    return number.boolValue
}
