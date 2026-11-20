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

    /// Risk words that the shared classifier misses: Dutch labels and a bare "Trash".
    static func browserEffectRisks(action: String, arguments: [String: Any], target: ActionPolicy.Target?) -> Set<ActionPolicy.Risk> {
        // A drag lands on its drop target, so classify that target the way a click on it would be classified.
        let base = action == "drag" ? "click" : action
        var risks = ActionPolicy.browserRisks(action: base, arguments: arguments, target: target)
        let words: [(ActionPolicy.Risk, Set<String>)] = [
            (.delete, ["trash", "verwijderen", "verwijder", "wissen", "prullenbak"]),
            (.send, ["verzenden", "versturen", "verstuur", "verzend"]),
            (.purchase, ["betalen", "afrekenen", "bestellen", "kopen"]),
        ]
        let names = [target?.title, target?.identifier].compactMap { $0 }.flatMap { name in
            name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        for (risk, vocabulary) in words where names.contains(where: vocabulary.contains) {
            risks.insert(risk)
        }
        return risks
    }

    /// Actions that can send input. Their origin is re-checked even when they report an error.
    static func browserActionMayDeliverInput(_ action: String) -> Bool {
        let readOnly: Set<String> = [
            "read", "state", "look", "snapshot", "screenshot", "see", "look_at", "read_text", "link_destination",
            "location", "info", "outline", "frames", "control_state", "value", "wait", "wait_load", "wait_for",
            "tabs", "list", "peek", "read_many", "open_many", "close_tab",
        ]
        return !readOnly.contains(action)
    }

    func authorizeBrowserEffect(_ policy: ActionPolicy, action: String, arguments: [String: Any],
                                page: BrowserPage, node: BrowserNode? = nil, point: CGPoint? = nil) throws {
        guard policy.checksOrigins || policy.checksRisks || StrictBackground.enabled() else { return }
        let evidence = try page.policyTarget(node: node, keyboard: ["key", "press_key"].contains(action), point: point)
        if StrictBackground.enabled(), let destination = evidence.destination, ActionPolicy.origin(destination) == nil {
            throw ComputerUseError.backgroundUnsupported("The control leads outside the background tab.")
        }
        if let destination = evidence.destination {
            try Self.authorizeBrowserAddresses(policy, addresses: [destination])
        }
        try authorizeAction(policy, bundleIDs: [], risks: Self.browserEffectRisks(action: action, arguments: arguments, target: evidence.target))
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

    /// A frame's focus step: the focused element, or a frame owner whose own document holds the focus.
    enum FocusStep {
        case element(objectID: String)
        case frameOwner(objectID: String)
    }

    /// Follows focus through nested frames to the focused element. Each frame is its own document, so the
    /// caller reads its focus there. Gives up with a denial instead of guessing.
    static func focusedPolicyElement<Context>(start: Context, maxDepth: Int = 8,
                                              focus: (Context) throws -> FocusStep,
                                              enter: (String) throws -> Context) throws -> String {
        var context = start
        for _ in 0...maxDepth {
            switch try focus(context) {
            case .element(let objectID): return objectID
            case .frameOwner(let objectID): context = try enter(objectID)
            }
        }
        throw ComputerUseError.actionDenied("The browser could not confirm the focused control for the action policy.")
    }

    func policyTarget(node: BrowserNode?, keyboard: Bool, point: CGPoint? = nil) throws -> (target: ActionPolicy.Target, destination: String?) {
        let frame = try policyFrames()
        let world = try cdp("Page.createIsolatedWorld", ["frameId": frame.id, "worldName": "Godspeed Action Policy"])
        guard let contextID = world["executionContextId"] as? Int else {
            throw ComputerUseError.actionDenied("The browser could not inspect the control for the action policy.")
        }
        let denied = ComputerUseError.actionDenied("The browser could not confirm the control for the action policy.")
        let objectID: String
        if let node {
            let resolved = try cdp("DOM.resolveNode", ["backendNodeId": node.backendNodeID, "executionContextId": contextID])
            guard let object = resolved["object"] as? [String: Any], let id = object["objectId"] as? String else {
                throw denied
            }
            objectID = id
        } else if let point {
            // A coordinate drop lands on whatever is under the point. Frames are not classified from here,
            // so a point inside one fails closed rather than being checked against the wrong document.
            guard point.x.isFinite, point.y.isFinite else {
                throw ComputerUseError.actionDenied("The browser could not confirm the drop target for the action policy.")
            }
            let found = try cdp("Runtime.evaluate", [
                "contextId": contextID, "returnByValue": false,
                "expression": "document.elementFromPoint(\(point.x), \(point.y))",
            ])
            guard let result = found["result"] as? [String: Any], let id = result["objectId"] as? String else {
                throw ComputerUseError.actionDenied("The browser could not confirm the drop target for the action policy.")
            }
            if Self.isFrameOwner(try cdp("DOM.describeNode", ["objectId": id])) {
                throw ComputerUseError.actionDenied("A drop inside a frame cannot be checked by the action policy. Drop onto a labelled control instead.")
            }
            objectID = id
        } else {
            // Keyboard input goes to the focused element of the focused frame, which can be nested.
            objectID = try Self.focusedPolicyElement(start: (frame: frame.id, context: contextID), focus: { current in
                let evaluated = try cdp("Runtime.evaluate", [
                    "contextId": current.context, "returnByValue": false,
                    "expression": Self.deepestActiveElementJS,
                ])
                guard let result = evaluated["result"] as? [String: Any], let id = result["objectId"] as? String else {
                    throw denied
                }
                let described = try cdp("DOM.describeNode", ["objectId": id])
                return Self.isFrameOwner(described) ? .frameOwner(objectID: id) : .element(objectID: id)
            }, enter: { owner in
                let described = try cdp("DOM.describeNode", ["objectId": owner])
                guard let childFrame = (described["node"] as? [String: Any])?["frameId"] as? String else { throw denied }
                let world = try cdp("Page.createIsolatedWorld", ["frameId": childFrame, "worldName": "Godspeed Action Policy"])
                guard let childContext = world["executionContextId"] as? Int else { throw denied }
                return (frame: childFrame, context: childContext)
            })
        }
        let payload = try cdp("Runtime.callFunctionOn", [
            "objectId": objectID, "functionDeclaration": Self.policyTargetFunction,
            "arguments": [["value": keyboard]], "returnByValue": true,
        ])
        guard let result = payload["result"] as? [String: Any],
              let facts = result["value"] as? [String: Any],
              let secure = facts["secure"] as? Bool, let submits = facts["submits"] as? Bool else {
            throw denied
        }
        return (ActionPolicy.Target(title: node?.name, identifier: facts["id"] as? String, role: node?.role,
                                    secureField: secure, submitsForm: submits), facts["destination"] as? String)
    }

    /// Only a frame owner (iframe, frame, object, embed) reports a frame ID for its node.
    private static func isFrameOwner(_ described: [String: Any]) -> Bool {
        (described["node"] as? [String: Any])?["frameId"] != nil
    }

    /// The focused element, looking through open shadow roots.
    private static let deepestActiveElementJS = """
    (() => { let el = document.activeElement; while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement; return el; })()
    """

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
