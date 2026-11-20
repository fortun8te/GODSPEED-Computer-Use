import Foundation

extension ComputerUseToolDispatcher {
    static let browserOpenActions: Set<String> = ["open", "new_tab", "open_tab"]
    static let browserNavigateActions: Set<String> = ["go", "goto", "navigate", "visit"]
    static let browserPreviewActions: Set<String> = ["peek", "read_many", "open_many"]
    static let browserClaimActions: Set<String> = ["use_tab", "claim", "claim_tab", "switch"]
    static let browserListActions: Set<String> = ["tabs", "list"]

    func authorizeBrowserRequest(_ policy: ActionPolicy, action: String, arguments: [String: Any]) throws {
        let tabManagement = Self.browserOpenActions.union(Self.browserPreviewActions)
            .union(Self.browserClaimActions).union(["close_tab"])
        if StrictBackground.enabled(), tabManagement.contains(action) {
            throw ComputerUseError.backgroundUnsupported("This browser action needs Chrome tab management.")
        }
        let destinations: [String]
        if Self.browserOpenActions.contains(action) || Self.browserNavigateActions.contains(action) {
            destinations = try Self.navigationURL(arguments["url"]).map { [$0] } ?? []
        } else if Self.browserPreviewActions.contains(action) {
            destinations = try (arguments["urls"] as? [String] ?? []).compactMap { try Self.navigationURL($0) }
        } else {
            destinations = []
        }
        if StrictBackground.enabled(), destinations.contains(where: { ActionPolicy.origin($0) == nil }) {
            throw ComputerUseError.backgroundUnsupported("This URL could open outside the background tab.")
        }
        try authorizeAction(policy, bundleIDs: [ActionPolicy.browserBundleID], addresses: destinations)
        try Self.requireKnownBrowserOrigins(policy, addresses: destinations)
    }

    static func authorizeBrowserAddresses(_ policy: ActionPolicy, addresses: [String]) throws {
        guard policy.checksOrigins else { return }
        try policy.authorize(addresses: addresses)
        try requireKnownBrowserOrigins(policy, addresses: addresses)
    }

    private static func requireKnownBrowserOrigins(_ policy: ActionPolicy, addresses: [String]) throws {
        guard policy.checksOrigins else { return }
        guard addresses.allSatisfy({ ActionPolicy.origin($0) != nil || ["about:blank", "about:srcdoc", "chrome://newtab/"].contains($0) }) else {
            throw ComputerUseError.actionDenied("The browser could not confirm an HTTP or HTTPS origin.")
        }
    }

    static func authorizeBrowserPage(_ policy: ActionPolicy, page: BrowserPage, afterDelivery: Bool = false) throws {
        guard policy.checksOrigins else { return }
        do {
            try authorizeBrowserAddresses(policy, addresses: page.policyFrames().addresses)
        } catch let error as ComputerUseError where afterDelivery {
            let note = " The action may have taken effect before the destination was checked."
            switch error {
            case .approvalRequired(let message): throw ComputerUseError.approvalRequired(message + note)
            case .actionDenied(let message): throw ComputerUseError.actionDenied(message + note)
            default: throw error
            }
        }
    }

    func authorizeBrowserEffect(_ policy: ActionPolicy, action: String, arguments: [String: Any],
                                page: BrowserPage, node: BrowserNode? = nil) throws {
        guard policy.checksOrigins || policy.checksRisks || StrictBackground.enabled() else { return }
        let evidence = try page.policyTarget(node: node, keyboard: ["key", "press_key"].contains(action))
        if StrictBackground.enabled(), let destination = evidence.destination, ActionPolicy.origin(destination) == nil {
            throw ComputerUseError.backgroundUnsupported("The control leads outside the background tab.")
        }
        if let destination = evidence.destination {
            try Self.authorizeBrowserAddresses(policy, addresses: [destination])
        }
        try authorizeAction(policy, bundleIDs: [], risks: ActionPolicy.browserRisks(action: action, arguments: arguments, target: evidence.target))
    }
}

extension BrowserPage {
    /// Frame URLs come from Chrome's protocol, without reading page text or running page JavaScript.
    func policyFrames() throws -> (id: String, addresses: [String]) {
        let response = try cdp("Page.getFrameTree")
        guard let root = response["frameTree"] as? [String: Any],
              let main = root["frame"] as? [String: Any], let id = main["id"] as? String else {
            throw ComputerUseError.actionDenied("The browser could not confirm the document for the action policy.")
        }
        var stack = [root]
        var addresses: [String] = []
        while let entry = stack.popLast() {
            guard let frame = entry["frame"] as? [String: Any], let url = frame["url"] as? String, !url.isEmpty else {
                throw ComputerUseError.actionDenied("The browser could not confirm a frame's origin.")
            }
            addresses.append(url)
            stack.append(contentsOf: entry["childFrames"] as? [[String: Any]] ?? [])
        }
        return (id, addresses)
    }

    func policyTarget(node: BrowserNode?, keyboard: Bool) throws -> (target: ActionPolicy.Target, destination: String?) {
        let frame = try policyFrames()
        let world = try cdp("Page.createIsolatedWorld", ["frameId": frame.id, "worldName": "Godspeed Action Policy"])
        guard let contextID = world["executionContextId"] as? Int else {
            throw ComputerUseError.actionDenied("The browser could not inspect the control for the action policy.")
        }
        let function = Self.policyTargetFunction
        let payload: [String: Any]
        if let node {
            let resolved = try cdp("DOM.resolveNode", ["backendNodeId": node.backendNodeID, "executionContextId": contextID])
            guard let object = resolved["object"] as? [String: Any], let objectID = object["objectId"] as? String else {
                throw ComputerUseError.actionDenied("The browser could not confirm the control for the action policy.")
            }
            payload = try cdp("Runtime.callFunctionOn", [
                "objectId": objectID, "functionDeclaration": function,
                "arguments": [["value": keyboard]], "returnByValue": true,
            ])
        } else {
            payload = try cdp("Runtime.evaluate", [
                "contextId": contextID, "returnByValue": true,
                "expression": """
                (() => {
                    let el = document.activeElement;
                    while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
                    return (\(function)).call(el, \(keyboard ? "true" : "false"));
                })()
                """,
            ])
        }
        guard let result = payload["result"] as? [String: Any],
              let facts = result["value"] as? [String: Any],
              let secure = facts["secure"] as? Bool, let submits = facts["submits"] as? Bool else {
            throw ComputerUseError.actionDenied("The browser could not confirm the control for the action policy.")
        }
        return (ActionPolicy.Target(title: node?.name, identifier: facts["id"] as? String, role: node?.role,
                                    secureField: secure, submitsForm: submits), facts["destination"] as? String)
    }

    private static let policyTargetFunction = """
    function(keyboard) {
        const el = this instanceof Element ? this : null;
        const control = el?.closest('button,input,select,textarea');
        const form = control?.form ?? el?.closest('form');
        const submits = !!(form && ((control instanceof HTMLButtonElement && control.type === 'submit')
            || (control instanceof HTMLInputElement && ['submit', 'image'].includes(control.type))
            || (keyboard && control instanceof HTMLInputElement)));
        const autocomplete = control?.autocomplete?.split(/\\s+/) ?? [];
        const secure = control?.type === 'password' ||
            autocomplete.some(value => ['current-password', 'new-password', 'one-time-code'].includes(value));
        const link = el?.closest('a[href],area[href]');
        return {secure, submits, id: control?.id ?? el?.id ?? null,
                destination: link?.href ?? (submits ? (control?.hasAttribute('formaction') ? control.formAction : form.action) : null)};
    }
    """
}
