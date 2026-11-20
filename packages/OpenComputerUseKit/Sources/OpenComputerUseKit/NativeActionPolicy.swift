import AppKit
import Foundation

extension ActionPolicy {
    /// Resolve names and default file handlers using the same discovery path as delivery.
    func nativeBundleIDs(tool: String, arguments: [String: Any]) -> [String] {
        if tool == "open" {
            switch SmartSteps.openPlan(path: arguments["path"] as? String, url: arguments["url"] as? String,
                                      app: arguments["app"] as? String, home: NSHomeDirectory()) {
            case .app(let name), .file(_, .some(let name)):
                if let url = SmartSteps.applicationURL(named: name), let id = Bundle(url: url)?.bundleIdentifier {
                    return [id]
                }
                return name.contains(".") ? [name] : []
            case .file(let path, nil):
                return handlerBundleIDs(URL(fileURLWithPath: path))
            case .appLink(let address):
                if address.lowercased().hasPrefix("x-apple.systempreferences:") {
                    return ["com.apple.systempreferences"]
                }
                return URL(string: address).map(handlerBundleIDs) ?? []
            case .url, nil:
                return []
            }
        }
        guard let app = arguments["app"] as? String else { return [] }
        if let id = AppDiscovery.policyBundleIdentifier(app) {
            return app.contains(".") && id.caseInsensitiveCompare(app) != .orderedSame ? [id, app] : [id]
        }
        return app.contains(".") ? [app] : []
    }

    private func handlerBundleIDs(_ url: URL) -> [String] {
        if url.isFileURL, url.pathExtension.lowercased() == "app", let id = Bundle(url: url)?.bundleIdentifier {
            return [id]
        }
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
              let id = Bundle(url: handler)?.bundleIdentifier else { return [] }
        return [id]
    }

    /// The element an action would target, read for classification only. Classification runs before
    /// authorization, so it must never unhide, activate, raise or open a window to find that element.
    static func classificationRecord(index: String, readSnapshot: (SnapshotRecoveryPolicy) throws -> AppSnapshot) -> ElementRecord? {
        guard let parsed = Int(index), let snapshot = try? readSnapshot(.readOnly) else { return nil }
        return snapshot.elements[parsed]
    }

    static let nativeTargetTools: Set<String> = ["click", "set_value", "type_text", "press_key", "perform_secondary_action", "drag"]

    /// A drag's risk comes from where it drops. The destination arguments name that element.
    static func dropTargetArguments(_ arguments: [String: Any]) -> [String: Any] {
        ["label": arguments["to_label"], "element_index": arguments["to_index"]].compactMapValues { $0 }
    }
    static let nativeScopedTools: Set<String> = nativeTargetTools.union([
        "open", "query", "get_app_state", "press_menu", "save_as", "select_text", "scroll", "hover", "drag", HandoffTool.name,
        // L9 actions: a gesture can press an app menu command; the others act on or read one app's controls.
        "gesture", "scroll_into_view", "wait_for",
    ])
}

extension ComputerUseService {
    /// Examine the same AX target delivery uses. Never launch or recover a window to classify an action.
    func actionPolicyTarget(tool: String, app: String, index: String?, labels: [String]?) -> ActionPolicy.Target? {
        guard (try? AppDiscovery.resolveRunning(app)) != nil else { return nil }
        if tool == "press_key" || tool == "type_text" {
            return liveInputPolicyTarget(app: app)
        }
        let record: ElementRecord?
        if let labels {
            record = try? resolveLabel(app: app, labels: labels, recoveryPolicy: .readOnly)
        } else if let index {
            record = policyRecord(app: app, index: index)
        } else {
            record = nil
        }
        guard let record else { return nil }
        return ActionPolicy.Target(title: record.title, identifier: record.identifier, role: record.role,
                                   secureField: isSecurePolicyField(record))
    }
}

extension ComputerUseService {
    /// Targeted (registry) indexes never recover a window, so they keep their own lookup. Any other index is read
    /// with a read-only recovery policy instead of the default that may activate the app.
    func policyRecord(app: String, index: String) -> ElementRecord? {
        if ComputerUseService.requiredRefGeneration == nil, let parsed = Int(index),
           parsed > TargetedElementRegistry<Int>.indexBase {
            return policyElement(app: app, index: index)
        }
        return ActionPolicy.classificationRecord(index: index) { policy in
            try currentSnapshot(for: app, needScreenshot: false, recoveryPolicy: policy)
        }
    }
}

extension ComputerUseToolDispatcher {
    // Browser actions supply the actual tab and DOM context. Native actions use the same policy decision.
    func authorizeAction(_ policy: ActionPolicy, bundleIDs: [String], addresses: [String] = [],
                         risks: Set<ActionPolicy.Risk> = []) throws {
        try policy.authorize(bundleIDs: bundleIDs, addresses: addresses, risks: risks)
    }

    func authorizeNativeAction(name: String, arguments: [String: Any]) throws {
        guard name != "browser", name != BatchTool.name else { return }
        let policy = try currentActionPolicy()
        guard ActionPolicy.nativeScopedTools.contains(name) else { return }
        let scoped = policy.checksApps || policy.checksOrigins || policy.checksRisks
        guard scoped else { return }
        let bundleIDs = policy.nativeBundleIDs(tool: name, arguments: arguments)
        if name == "open", case .url = SmartSteps.openPlan(
            path: arguments["path"] as? String, url: arguments["url"] as? String,
            app: arguments["app"] as? String, home: NSHomeDirectory()
        ) { return } // The web opener re-enters the dispatcher.
        if policy.checksApps, bundleIDs.isEmpty {
            throw ComputerUseError.actionDenied("The target app's bundle ID could not be confirmed.")
        }
        if policy.checksOrigins, bundleIDs.contains(where: ActionPolicy.isBrowser) {
            throw ComputerUseError.actionDenied("Use the browser tool so the local action policy can check the page origin.")
        }
        try authorizeAction(policy, bundleIDs: bundleIDs)
        if (policy.checksApps || policy.checksOrigins), ActionPolicy.finderMayOpenDifferentApp(tool: name, arguments: arguments, bundleID: bundleIDs.first) {
            throw ComputerUseError.actionDenied("Use open with the exact path so the action policy can check the app that opens it.")
        }
        if policy.checksRisks, name != HandoffTool.name {
            let risks = StrictBackground.$requested.withValue(true) {
                nativeRisks(name: name, arguments: arguments, bundleID: bundleIDs.first)
            }
            try authorizeAction(policy, bundleIDs: [], risks: risks)
        }
    }

    private func nativeRisks(name: String, arguments: [String: Any], bundleID: String?) -> Set<ActionPolicy.Risk> {
        let target: ActionPolicy.Target?
        if let app = arguments["app"] as? String, ActionPolicy.nativeTargetTools.contains(name) {
            let targetArguments = name == "drag" ? ActionPolicy.dropTargetArguments(arguments) : arguments
            target = service.actionPolicyTarget(tool: name, app: app, index: optionalElementIndex(in: targetArguments),
                                                labels: labelArguments(in: targetArguments))
        } else {
            target = nil
        }
        var risks = ActionPolicy.nativeRisks(tool: name, arguments: arguments, bundleID: bundleID, target: target)
        if name == "press_key", let app = arguments["app"] as? String, let key = arguments["key"] as? String,
           let descriptor = try? AppDiscovery.resolveRunning(app) {
            risks.formUnion(ActionPolicy.namedRisks([FocusBorrow.menuTitle(forKey: key, pid: descriptor.pid)]))
        }
        return risks
    }
}
