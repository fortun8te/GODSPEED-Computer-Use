import Foundation

/// Reads and drives a page in a tab that Open Browser Use manages, through Chrome DevTools Protocol
/// calls sent with OBU's `cdp` tool. OBU opens its tabs in the background, so the macOS accessibility
/// path would read whatever tab the user is looking at; CDP reaches the agent's own tab instead and
/// never touches the user's.
///
/// `read` renders the page's accessibility tree as a short numbered list: controls first, then a capped
/// run of headings and text. `click`, `type`, `key`, `select`, `check`, `hover` and `scroll` act on a numbered
/// element or on a label. A label is first looked up with Chrome's own name search
/// (`Accessibility.queryAXTree`), and the whole tree is read only when that finds nothing.
struct BrowserNode: Sendable {
    let index: Int
    let role: String
    let name: String
    let value: String
    let backendNodeID: Int
    /// True when Chrome reports the node inside an iframe other than the page's main frame.
    var inFrame = false
    /// Index of the nearest control this one sits inside (a button inside a link), 0 when none.
    var parentControl = 0
    /// Short text that sat just before the control in the page when it was read (a product name before its
    /// "Add to cart"). Part of the fingerprint checked again before a click. Empty when unknown.
    var context = ""
    /// Not in the agent's previous `read` of this page: shown as "3*".
    var isNew = false

    /// The line a model reads: "3 textbox Email = sam@x.com"; "3*" when new since the last read.
    var line: String {
        let valuePart = value.isEmpty ? "" : " = \(value.prefix(80))"
        return "\(index)\(isNew ? "*" : "") \(role) \(name.prefix(100))\(valuePart)"
    }
}

/// What an action did to the page, in the one short line the model reads after it.
enum BrowserChange: Equatable, Sendable {
    case navigated(String)
    case changed
    case none

    var line: String {
        switch self {
        case .navigated(let url): return "navigated to \(url)"
        case .changed: return "page changed"
        case .none: return "no change"
        }
    }
}

/// What typing into a field produced: the model reads `reply(target:)`.
struct BrowserTypeOutcome: Sendable {
    /// Set when the field was a native <select> and the text picked an option ("chose "Canada" in "Country"").
    var picked: String?
    /// "(field now shows "...")" when the field does not read back as typed.
    var note: String?
    /// Visible role=option entries that appeared under a combobox / autocomplete.
    var options: [String] = []
    var change: BrowserChange = .none

    func reply(verb: String, target: String) -> String {
        if let picked { return picked }
        var parts = ["\(verb) \(target)"]
        if let note { parts.append(note) }
        // Typing changes a field's value, which the page's change counter does not see: "no change" here
        // read as a failure and the model typed again.
        if change != .none { parts.append(change.line) }
        if !options.isEmpty { parts.append("options: " + options.joined(separator: " | ")) }
        return parts.joined(separator: "; ")
    }
}

/// What one accessibility tree read produced, before any formatting.
struct BrowserAXParse: Sendable {
    var controls: [BrowserNode] = []
    /// Headings ("# …") and text lines ("  …"), in page order, already capped.
    var texts: [String] = []
    var droppedControls = 0
    var framedControls = 0
    /// Controls marked new since the last read (see `BrowserRules.markNew`).
    var newControls = 0
}

struct BrowserLocation: Sendable {
    let href: String
    let title: String
    let readyState: String
}

final class BrowserPage {
    let bridge: BrowserBridge
    let tab: [String: Any]
    /// Keep the numbered list for later index clicks. Off for throwaway reads (peek lanes).
    let remember: Bool
    private var indexedGeneration: Int?

    init(bridge: BrowserBridge, tab: [String: Any], remember: Bool = true) {
        self.bridge = bridge
        self.tab = tab
        self.remember = remember
    }

    /// Roles a model can act on.
    static let interactiveRoles: Set<String> = [
        "button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "switch", "tab",
        "menuitem", "menuitemcheckbox", "menuitemradio", "option", "slider", "spinbutton", "listbox",
        "treeitem", "disclosuretriangle",
    ]
    static let fieldRoles: Set<String> = ["textbox", "searchbox", "combobox", "spinbutton"]
    static let clickableRoles: Set<String> = ["button", "link", "menuitem", "tab", "checkbox", "radio", "switch", "option"]
    /// Most numbered controls kept for one page.
    static let maxElements = 400
    /// Characters one `read` may spend on control lines and on text lines.
    static let controlBudget = 7_000
    static let textBudget = 2_500

    private var tabID: Int? { tab["tab_id"] as? Int }

    private static let staleIndex = ComputerUseError.invalidArguments(
        "browser: the tab or document changed; browser read again before using an element number"
    )

    private func documentIdentity() throws -> BrowserDocumentIdentity? {
        guard let frames = try cdp("Page.getFrameTree")["frameTree"] as? [String: Any] else { return nil }
        return BrowserDocumentIdentity(tree: frames)
    }

    // MARK: Read

    /// `find`: only the controls and text lines that mention it (indexes stay valid). `full`: about four
    /// times the usual budget, for pages whose controls did not all fit.
    func read(find: String? = nil, full: Bool = false) throws -> String {
        guardForeignFrames()
        let identity = remember && tabID != nil ? try? documentIdentity() : nil
        let generation = bridge.referenceGeneration
        let raw = try fullTree()
        let query = find?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A find looks through the whole page, however long (only its matches are printed); a full read lists
        // about four times the usual amount.
        let parsed = query.isEmpty
            ? Self.parseAX(raw,
                           controlBudget: full ? BrowserPage.controlBudget * 4 : BrowserPage.controlBudget,
                           textBudget: full ? BrowserPage.textBudget * 4 : BrowserPage.textBudget,
                           maxControls: full ? BrowserPage.maxElements * 2 : BrowserPage.maxElements)
            : Self.parseAX(raw, controlBudget: .max, textBudget: .max, maxControls: .max)
        var parse = parsed
        let place = try? location()
        parse.texts = visibleTexts(parse.texts)
        var indicesAvailable = false
        if remember, let tabID {
            let memory = BrowserPageMemory.shared
            if let identity, (try? documentIdentity()) == identity, generation == bridge.referenceGeneration {
                let previous = memory.observation(bridge: bridge, tab: tabID, document: identity)
                parse.controls = BrowserRules.markNew(parse.controls, previousKeys: previous?.keys)
                parse.newControls = parse.controls.filter(\.isNew).count
                memory.store(parse.controls, bridge: bridge, tab: tabID, document: identity, generation: generation)
                indicesAvailable = true
            } else {
                memory.forgetTab(bridge: bridge, tab: tabID)
            }
        }
        var shown = query.isEmpty ? parse : Self.filtered(parse, find: query)
        if !query.isEmpty, shown.controls.count > 150 || shown.texts.count > 80 {
            shown.droppedControls = Swift.max(0, shown.controls.count - 150)
            shown.controls = Array(shown.controls.prefix(150))
            shown.texts = Array(shown.texts.prefix(80))
        }
        var text = Self.renderRead(shown, href: place?.href ?? "?", title: place?.title ?? "", readyState: place?.readyState ?? "complete", wholePage: query.isEmpty)
        if !query.isEmpty {
            text += shown.controls.isEmpty && shown.texts.isEmpty
                ? "\n(nothing on this page mentions \"\(query)\"; read without find, scroll, or try other words)"
                : "\n(only lines mentioning \"\(query)\"; indexes are valid for click and type)"
        }
        return text
    }

    /// The parse narrowed to controls and text lines that contain `find`, ignoring case.
    static func filtered(_ parse: BrowserAXParse, find: String) -> BrowserAXParse {
        let words = find.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ line: String) -> Bool {
            let lower = line.lowercased()
            return words.allSatisfy { lower.contains($0) }
        }
        var out = BrowserAXParse()
        out.controls = parse.controls.filter { matches($0.line) }
        out.texts = parse.texts.filter { matches($0) }
        out.framedControls = out.controls.filter(\.inFrame).count
        return out
    }

    /// The visible part of the page as a JPEG, for pages drawn as pictures (maps, canvases, editors).
    func screenshot() throws -> Data {
        let result = try cdp("Page.captureScreenshot", ["format": "jpeg", "quality": 60, "captureBeyondViewport": false])
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw ComputerUseError.message("browser: Chrome returned no screenshot; browser wait, then try again")
        }
        return data
    }

    /// Text lines whose words are not on screen (display:none, visibility:hidden, collapsed content) are dropped,
    /// by one page script over the candidate lines. Any failure keeps every line.
    func visibleTexts(_ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return lines }
        let names = lines.map { String($0.dropFirst(2)) }
        let probes = names.map { String(Self.collapse($0).lowercased().prefix(40)) }
        guard let data = try? JSONSerialization.data(withJSONObject: probes),
              let json = String(data: data, encoding: .utf8),
              let flags = (try? evaluate("(\(Self.visibleTextJS))(\(json))")) as? [Any], flags.count == lines.count
        else { return lines }
        return Self.keepVisible(lines, flags: flags.map { ($0 as? Bool) ?? true })
    }

    static func keepVisible(_ lines: [String], flags: [Bool]) -> [String] {
        guard flags.count == lines.count else { return lines }
        return zip(lines, flags).filter(\.1).map(\.0)
    }

    /// For each probe (lowercase text start): is it inside a text node, aria-label or title that is visible?
    /// Without `checkVisibility` (old Chrome) everything counts as visible.
    static let visibleTextJS = """
    function(probes){if(!document.body||!Element.prototype.checkVisibility)return probes.map(function(){return true;});\
    const norm=(t)=>String(t||'').replace(/\\s+/g,' ').trim().toLowerCase();\
    const opt={checkOpacity:true,checkVisibilityCSS:true,contentVisibilityAuto:true};const seen=new Map();\
    const vis=(e)=>{if(!e)return false;if(seen.has(e))return seen.get(e);let v=false;try{v=e.checkVisibility(opt);}catch(x){v=true;}seen.set(e,v);return v;};\
    const hay=[];let n=0;const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);\
    while(w.nextNode()&&n++<20000){const t=w.currentNode;if(t.nodeValue&&t.nodeValue.trim()&&vis(t.parentElement))hay.push(norm(t.nodeValue));}\
    for(const e of document.body.querySelectorAll('[aria-label],[title]')){if(vis(e)){hay.push(norm(e.getAttribute('aria-label')));hay.push(norm(e.getAttribute('title')));}}\
    const blob=hay.join(' ');return probes.map(function(p){return !p||blob.includes(p);});}
    """

    func location() throws -> BrowserLocation {
        guardForeignFrames()
        let raw = try evaluate("[location.href, document.title, document.readyState]")
        let values = (raw as? [Any]) ?? []
        guard values.count == 3 else {
            throw ComputerUseError.message("browser: could not read the page address; browser wait, then try again")
        }
        return BrowserLocation(href: values[0] as? String ?? "", title: values[1] as? String ?? "", readyState: values[2] as? String ?? "")
    }

    /// The accessibility nodes of the whole page. Accessibility is enabled once per tab; if Chrome answers
    /// with nothing, it is enabled again and the tree read once more.
    private func fullTree() throws -> [[String: Any]] {
        enableOnce("Accessibility.enable")
        var nodes = Self.nodes(of: try cdp("Accessibility.getFullAXTree"))
        if nodes.isEmpty {
            forgetDomain("Accessibility.enable")
            enableOnce("Accessibility.enable")
            nodes = Self.nodes(of: try cdp("Accessibility.getFullAXTree"))
        }
        return nodes
    }

    private static func nodes(of payload: [String: Any]) -> [[String: Any]] {
        payload["nodes"] as? [[String: Any]] ?? []
    }

    /// Parses an accessibility tree: numbered interactive controls (with their Chrome node ids) and a capped
    /// list of headings and text. Ignored nodes and unnamed non-field controls are skipped.
    static func parseAX(
        _ raw: [[String: Any]],
        controlBudget: Int = BrowserPage.controlBudget,
        textBudget: Int = BrowserPage.textBudget,
        maxControls: Int = BrowserPage.maxElements
    ) -> BrowserAXParse {
        var result = BrowserAXParse()
        let mainFrame = raw.first { axValue($0["role"]) == "RootWebArea" }.flatMap { $0["frameId"] as? String }
        var controlCharacters = 0
        var textCharacters = 0
        var lastControlName = ""
        var lastText = ""
        // To tell a button inside a link (one target) from two buttons with the same label (two targets).
        var parentOf: [String: String] = [:]
        for node in raw {
            if let id = node["nodeId"] as? String, let parent = node["parentId"] as? String { parentOf[id] = parent }
        }
        var controlOfNode: [String: Int] = [:]
        for node in raw {
            if (node["ignored"] as? Bool) == true { continue }
            let role = axValue(node["role"]) ?? ""
            let name = collapse(axValue(node["name"]) ?? "")

            if interactiveRoles.contains(role) {
                let value = collapse(axValue(node["value"]) ?? "")
                guard let backend = (node["backendDOMNodeId"] as? NSNumber)?.intValue,
                      !name.isEmpty || fieldRoles.contains(role)
                else { continue }
                let frame = node["frameId"] as? String
                let inFrame = mainFrame != nil && frame != nil && frame != mainFrame
                var enclosing = 0
                var cursor = (node["nodeId"] as? String).flatMap { parentOf[$0] }
                var hops = 0
                while let id = cursor, hops < 60 {
                    if let found = controlOfNode[id] { enclosing = found; break }
                    cursor = parentOf[id]
                    hops += 1
                }
                let control = BrowserNode(
                    index: result.controls.count + 1, role: role, name: name, value: value,
                    backendNodeID: backend, inFrame: inFrame, parentControl: enclosing,
                    context: fieldRoles.contains(role) ? "" : BrowserRules.contextText(lastText, excluding: name)
                )
                if result.controls.count >= maxControls || controlCharacters + control.line.count > controlBudget {
                    result.droppedControls += 1
                    continue
                }
                controlCharacters += control.line.count
                if inFrame { result.framedControls += 1 }
                result.controls.append(control)
                if let id = node["nodeId"] as? String { controlOfNode[id] = control.index }
                lastControlName = name
                continue
            }

            if !name.isEmpty, role == "heading" || role == "StaticText" { lastText = name }
            guard textCharacters < textBudget, !name.isEmpty else { continue }
            if role == "heading" {
                let line = "# \(name.prefix(120))"
                result.texts.append(line)
                textCharacters += line.count
            } else if role == "StaticText", name.count >= 2, name != lastControlName {
                let line = "  \(name.prefix(160))"
                result.texts.append(line)
                textCharacters += line.count
            }
        }
        return result
    }

    /// The text a model reads: controls first, then the capped text, with the page's address and load state on top.
    static func renderRead(_ parse: BrowserAXParse, href: String, title: String, readyState: String, wholePage: Bool = true) -> String {
        let place = title.isEmpty ? href : "\(title) — \(href)"
        let loading = readyState == "complete" ? "" : " (still loading)"
        var lines = ["Page: \(place.isEmpty ? "?" : place)\(loading)"]
        if parse.controls.isEmpty && parse.texts.isEmpty {
            lines.append("(no readable content yet; the page may still be loading: browser wait, then read)")
            return lines.joined(separator: "\n")
        }
        if parse.controls.isEmpty {
            lines.append("Controls: none")
        } else {
            lines.append("Controls:")
            lines += parse.controls.map(\.line)
        }
        if parse.droppedControls > 0 {
            lines.append("(\(parse.droppedControls) more controls not listed: read with find: \"words\" to list the matching ones, or full: true; or act on them by label)")
        }
        if parse.newControls > 0 {
            lines.append("(* = new since your last read)")
        }
        if parse.framedControls > 0 {
            lines.append("(\(parse.framedControls) of these sit inside an iframe; act on them by label or index)")
        }
        if !parse.texts.isEmpty {
            lines.append("Text:")
            lines += parse.texts
        }
        if wholePage, parse.controls.count + parse.texts.count < 4 {
            lines.append("(little readable text: the page may be drawn as an image, such as a map, canvas or editor; browser screenshot shows it)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Resolve

    /// The element an action targets. An index comes from the last `read` of this tab. A label is looked up with
    /// Chrome's name search first; only when that finds nothing is the whole tree read and matched loosely.
    func resolve(label: String?, index: Int?) throws -> BrowserNode {
        guardForeignFrames()
        if let index {
            guard let tabID, let document = try documentIdentity(),
                  let observation = BrowserPageMemory.shared.observation(bridge: bridge, tab: tabID, document: document) else {
                throw Self.staleIndex
            }
            guard let node = observation.nodes.first(where: { $0.index == index }) else {
                throw ComputerUseError.invalidArguments("browser: no element \(index) in the last read; browser read again")
            }
            indexedGeneration = observation.generation
            let verified = try verified(node, index: index)
            guard try documentIdentity() == document else {
                BrowserPageMemory.shared.forgetTab(bridge: bridge, tab: tabID)
                throw Self.staleIndex
            }
            return verified
        }
        guard let label, !label.isEmpty else {
            throw ComputerUseError.invalidArguments("browser: give a label (visible text) or an index from browser read")
        }
        let wanted = Self.normalize(label)
        if let named = try? queryNamed(label), let hit = Self.pickNamed(named, wanted: wanted) {
            return hit
        }
        let raw = try fullTree()
        let nodes = Self.parseAX(raw, controlBudget: Int.max, textBudget: 0, maxControls: .max).controls
        if let hit = try Self.pickFuzzy(nodes, label: label) { return hit }
        let names = nodes.prefix(12).map { "\($0.role) \"\($0.name.prefix(40))\"" }.joined(separator: ", ")
        throw ComputerUseError.invalidArguments(
            "browser: no element labelled '\(label)'. Visible: \(names). Use the exact text, or browser read for indexes"
        )
    }

    /// A page that re-rendered can reuse an element for other content, so a number from an earlier read is
    /// checked against a fingerprint (name, value, and the text that sat before it) before it is used.
    /// Renamed or repurposed controls require a fresh read. Coverage is checked at click time.
    private func verified(_ node: BrowserNode, index: Int) throws -> BrowserNode {
        // Chrome no longer has the node (the page was rebuilt or navigated): it must not be used at its old place.
        guard let live = try? cdp("Accessibility.getPartialAXTree", ["backendNodeId": node.backendNodeID, "fetchRelatives": false]),
              let first = Self.nodes(of: live).first(where: { ($0["ignored"] as? Bool) != true })
        else {
            throw ComputerUseError.invalidArguments(
                "browser: element \(index) \"\(node.name.prefix(40))\" is gone from the page; browser read again"
            )
        }
        let nowName = Self.axValue(first["name"]).map(Self.collapse) ?? ""
        let nowValue = Self.axValue(first["value"]).map(Self.collapse) ?? ""
        switch BrowserRules.fingerprint(node, nowName: nowName, nowValue: nowValue) {
        case .same:
            break
        case .renamed(let now):
            throw ComputerUseError.invalidArguments(
                "browser: element \(index) changed since the last read (it was \"\(node.name.prefix(40))\", now \"\(now.prefix(40))\"); browser read again"
            )
        case .valueChanged(let now):
            throw ComputerUseError.invalidArguments(
                "browser: element \(index) \"\(node.name.prefix(40))\" changed since the last read (now \"\(now.prefix(40))\"); browser read again"
            )
        }
        // The text that sat before it must still be around it; a list rebuilt with other items fails this.
        if !node.context.isEmpty,
           let found = try? callOnNode(node, Self.contextCheckJS, arguments: [node.context.lowercased()]) as? Bool, !found {
            throw ComputerUseError.invalidArguments(
                "browser: element \(index) \"\(node.name.prefix(40))\" now sits among other content than when you read it (was after \"\(node.context.prefix(30))\"); browser read again"
            )
        }
        return node
    }

    /// True when `ctx` (lowercase) is in the text of the element or of any ancestor up to the body.
    private static let contextCheckJS = """
    function(ctx){const norm=(t)=>String(t||'').replace(/\\s+/g,' ').toLowerCase();\
    for(let n=this;n&&n.nodeType===1;n=n.parentElement){if(norm(n.innerText||n.textContent).includes(ctx))return true;}return false;}
    """

    /// Chrome's own name search: fast, and it does not read the whole page.
    private func queryNamed(_ label: String) throws -> [BrowserNode] {
        Self.namedCandidates(try queryNamedRaw(label))
    }

    /// Chrome's name search needs a node to search under: the document.
    private func queryNamedRaw(_ label: String) throws -> [[String: Any]] {
        enableOnce("Accessibility.enable")
        let root = try cdp("Runtime.evaluate", ["expression": "document", "returnByValue": false])
        guard let objectID = (root["result"] as? [String: Any])?["objectId"] as? String else {
            throw ComputerUseError.message("browser: could not reach the page's document; browser wait, then try again")
        }
        let payload = try cdp("Accessibility.queryAXTree", ["objectId": objectID, "accessibleName": label])
        return Self.nodes(of: payload)
    }

    static func namedCandidates(_ raw: [[String: Any]]) -> [BrowserNode] {
        raw.compactMap { node -> BrowserNode? in
            guard (node["ignored"] as? Bool) != true,
                  let role = axValue(node["role"]), interactiveRoles.contains(role),
                  let backend = (node["backendDOMNodeId"] as? NSNumber)?.intValue
            else { return nil }
            return BrowserNode(
                index: 0, role: role, name: collapse(axValue(node["name"]) ?? ""),
                value: collapse(axValue(node["value"]) ?? ""), backendNodeID: backend
            )
        }
    }

    /// The one element whose name equals the label (clickable ones first). Several different elements with
    /// that name give nil: the full read then decides, and lists them with their numbers if they are distinct.
    static func pickNamed(_ nodes: [BrowserNode], wanted: String) -> BrowserNode? {
        let exact = nodes.filter { normalize($0.name) == wanted }
        let clickable = exact.filter { clickableRoles.contains($0.role) }
        let pool = clickable.isEmpty ? exact : clickable
        return Set(pool.map(\.backendNodeID)).count == 1 ? pool.first : nil
    }

    /// `nodes` without those that sit inside another one of them (a button inside a link is one target).
    static func outermost(_ nodes: [BrowserNode], all: [BrowserNode]) -> [BrowserNode] {
        let indexes = Set(nodes.map(\.index))
        let parent = Dictionary(all.map { ($0.index, $0.parentControl) }, uniquingKeysWith: { first, _ in first })
        return nodes.filter { node in
            var cursor = node.parentControl
            var hops = 0
            while cursor != 0, hops < 60 {
                if indexes.contains(cursor) { return false }
                cursor = parent[cursor] ?? 0
                hops += 1
            }
            return true
        }
    }

    /// Loose matching over the full list: a whole-word match when several elements contain the label, and an
    /// error (never a guess) when several distinct ones match.
    static func pickFuzzy(_ nodes: [BrowserNode], label: String) throws -> BrowserNode? {
        let wanted = normalize(label)
        let exact = nodes.filter { normalize($0.name) == wanted }
        // Several different elements with the same label ("Add to cart" on every product) are never guessed
        // between: the first one is rarely the one meant.
        func single(_ matches: [BrowserNode]) throws -> BrowserNode? {
            let clickable = matches.filter { clickableRoles.contains($0.role) }
            let pool = outermost(clickable.isEmpty ? matches : clickable, all: nodes)
            guard pool.count > 1 else { return pool.first }
            let options = pool.prefix(8).map { "\($0.index) \($0.role)" }.joined(separator: ", ")
            throw ComputerUseError.invalidArguments(
                "browser: \(pool.count) elements are labelled '\(label)': \(options). Use index: N; browser read with find: \"\(label)\" shows what each one belongs to"
            )
        }
        if let hit = try single(exact) { return hit }
        guard wanted.count >= 3 else { return nil }
        let partial = nodes.filter { normalize($0.name).contains(wanted) }
        let distinct = Set(partial.map { normalize($0.name) })
        if distinct.count == 1, let hit = try single(partial) {
            return hit
        }
        guard distinct.count > 1 else { return nil }
        let labelWords = words(label)
        let whole = partial.filter { containsWords(words($0.name), labelWords) }
        if Set(whole.map { normalize($0.name) }).count == 1, let hit = whole.first { return hit }
        let options = partial.prefix(8).map { "\($0.index) \($0.role) \"\($0.name.prefix(40))\"" }.joined(separator: ", ")
        throw ComputerUseError.invalidArguments("browser: '\(label)' matches several elements: \(options). Use the exact text or an index")
    }

    // MARK: Act: pointer

    /// The address and target attribute of a link, to tell whether a click would open a new tab.
    func linkTarget(_ node: BrowserNode) -> (href: String, target: String)? {
        guard let values = (try? callOnNode(node, "function(){return [this.href||'', this.target||''];}")) as? [Any],
              values.count == 2
        else {
            return nil
        }
        return (values[0] as? String ?? "", values[1] as? String ?? "")
    }

    func click(_ node: BrowserNode) throws {
        restoreSetup()
        reveal(node)
        let point = try clickPoint(of: node)
        try mouse("mouseMoved", point, buttons: 0, clickCount: 0)
        try mouse("mousePressed", point, buttons: 1, clickCount: 1)
        try mouse("mouseReleased", point, buttons: 0, clickCount: 1)
    }

    func hover(_ node: BrowserNode) throws {
        restoreSetup()
        reveal(node)
        try mouse("mouseMoved", try clickPoint(of: node), buttons: 0, clickCount: 0)
    }

    /// A pointer gesture within one viewport, using live hit testing at both ends.
    func drag(from source: BrowserNode, to destination: BrowserNode) throws {
        restoreSetup()
        func visiblePoint(_ node: BrowserNode) throws -> CGPoint {
            guard let probe = try callOnNode(node, Self.clickProbeJS) as? [Any],
                  probe.first as? String == "ok", probe.count >= 3,
                  let x = BrowserRules.number(probe[1]), let y = BrowserRules.number(probe[2]),
                  x.isFinite, y.isFinite else {
                throw ComputerUseError.stateUnavailable("browser drag needs both controls visible and unobstructed in the same page. Read the tab again.")
            }
            return CGPoint(x: x, y: y)
        }
        let start = try visiblePoint(source)
        let end = try visiblePoint(destination)
        guard hypot(end.x - start.x, end.y - start.y) >= 4 else {
            throw ComputerUseError.invalidArguments("browser drag needs two distinct visible positions")
        }
        try Self.deliverDrag(from: start, to: end, send: mouse)
    }

    static func deliverDrag(
        from start: CGPoint, to end: CGPoint,
        send: (String, CGPoint, Int, Int) throws -> Void
    ) throws {
        let remaining = BrowserCallBudget.remaining()
        guard remaining > 4 else { throw ComputerUseError.stateUnavailable("browser drag ran out of time before pressing") }
        let releaseDeadline = BrowserCallBudget.deadline(after: remaining)
        let movementDeadline = releaseDeadline - 3
        try send("mouseMoved", start, 0, 0)
        var last = start
        do {
            try BrowserCallBudget.withDeadline(movementDeadline) {
                try send("mousePressed", start, 1, 1)
                for step in 1...5 {
                    let progress = Double(step) / 5
                    last = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
                    try send("mouseMoved", last, 1, 0)
                }
            }
        } catch {
            // A missing CDP reply doesn't prove the event was never sent.
            try? BrowserCallBudget.withDeadline(releaseDeadline) {
                try send("mouseReleased", last, 0, 1)
            }
            throw ComputerUseError.stateUnavailable("browser drag was interrupted after starting. Read the tab before retrying.")
        }
        try send("mouseReleased", end, 0, 1)
    }

    /// Where on the element to click: a point of its visible part that really reaches it (`elementFromPoint`
    /// hit-test). Says so when something else lies on top of every probed point (a banner, a dialog, a
    /// stretched link), instead of clicking that and reporting success. Elements in an iframe, and anything
    /// the page script cannot place, use the box centre as before.
    private func clickPoint(of node: BrowserNode) throws -> CGPoint {
        func probe() -> [Any] { ((try? callOnNode(node, Self.clickProbeJS)) as? [Any]) ?? [] }
        var found = probe()
        if (found.first as? String) == "covered" {
            // Often a sticky header: centre the element and look again.
            _ = try? callOnNode(node, "function(){this.scrollIntoView({block:'center',inline:'center',behavior:'instant'});}")
            found = probe()
        }
        let kind = found.first as? String
        if kind == "ok" || kind == "covered", found.count >= 3,
           let x = BrowserRules.number(found[1]), let y = BrowserRules.number(found[2]) {
            if kind == "covered" {
                let what = found.count > 3 ? "\(found[3])".trimmingCharacters(in: .whitespacesAndNewlines) : ""
                throw ComputerUseError.message(BrowserRules.coveredMessage(role: node.role, name: node.name, by: what))
            }
            return CGPoint(x: x, y: y)
        }
        return try center(of: node)
    }

    /// ["ok", x, y]: a probed point of the element reaches it. ["covered", x, y, text]: every probed point
    /// lands on something else (not the element, not inside it, not its label). ["frame"] inside an iframe (its
    /// coordinates are not the page's), ["off"] when nothing of it is in view. Also takes the change baseline,
    /// so the settle after the click can say whether the page changed.
    private static let clickProbeJS = """
    function(){if(window.__gs){__gs.seen=__gs.mut;__gs.href=location.href;__gs.nav=false;}\
    if(window!==window.top)return ['frame'];const r=this.getBoundingClientRect();\
    const x0=Math.max(0,r.left),y0=Math.max(0,r.top),x1=Math.min(innerWidth,r.right),y1=Math.min(innerHeight,r.bottom);\
    if(x1-x0<1||y1-y0<1)return ['off'];const w=x1-x0,h=y1-y0;\
    const pts=[[x0+w/2,y0+h/2],[x0+w*0.25,y0+h/2],[x0+w*0.75,y0+h/2],[x0+w/2,y0+h*0.25],[x0+w/2,y0+h*0.75]];\
    const inside=(a,b)=>{for(let n=b;n;n=n.parentNode||n.host){if(n===a)return true;}return false;};\
    const lab=this.labels?Array.from(this.labels):[];\
    let first=null;\
    for(const p of pts){const x=p[0],y=p[1];let t=document.elementFromPoint(x,y);\
    for(let s;t&&t.shadowRoot&&(s=t.shadowRoot.elementFromPoint(x,y))&&s!==t;)t=s;\
    if(!t)return ['ok',x,y];\
    if(inside(this,t)||inside(t,this)||lab.some((l)=>inside(l,t)))return ['ok',x,y];\
    if(!first)first=[x,y,t];}\
    const t=first[2];const lbl=t.closest&&t.closest('label');\
    if(lbl&&lbl.control&&inside(this,lbl.control))return ['ok',first[0],first[1]];\
    return ['covered',first[0],first[1],String(t.getAttribute&&t.getAttribute('aria-label')||t.innerText||t.tagName||'').replace(/\\s+/g,' ').slice(0,60)];}
    """

    private func reveal(_ node: BrowserNode) {
        _ = try? cdp("DOM.scrollIntoViewIfNeeded", ["backendNodeId": node.backendNodeID])
    }

    private func center(of node: BrowserNode) throws -> CGPoint {
        let box = try cdp("DOM.getBoxModel", ["backendNodeId": node.backendNodeID])
        guard let model = box["model"] as? [String: Any],
              let quad = (model["content"] as? [NSNumber])?.map(\.doubleValue), quad.count >= 8
        else {
            throw ComputerUseError.message("browser: \(node.role) \"\(node.name)\" has no size on the page (hidden, or in another frame); browser read again")
        }
        let x = (quad[0] + quad[2] + quad[4] + quad[6]) / 4
        let y = (quad[1] + quad[3] + quad[5] + quad[7]) / 4
        guard x >= 0, y >= 0 else {
            throw ComputerUseError.message("browser: \(node.role) \"\(node.name)\" is above or left of the page; browser scroll, then try again")
        }
        return CGPoint(x: x, y: y)
    }

    private func mouse(_ type: String, _ point: CGPoint, buttons: Int, clickCount: Int) throws {
        _ = try cdp("Input.dispatchMouseEvent", [
            "type": type, "x": point.x, "y": point.y,
            "button": type == "mouseMoved" ? "none" : "left",
            "buttons": buttons, "clickCount": clickCount,
        ])
    }

    // MARK: Act: keyboard and text

    func focus(_ node: BrowserNode) throws {
        restoreSetup()
        reveal(node)
        if (try? cdp("DOM.focus", ["backendNodeId": node.backendNodeID])) == nil {
            try click(node)
        }
    }

    /// Types into the focused field, or into `node` after focusing it. `replace` selects the old value first, so
    /// the text replaces it; empty text with `replace` clears the field. All but the last character go in as
    /// one insertion; the last is sent as a real key event, so the page's key handlers (autocomplete) fire.
    /// A native <select> takes the text as the option to pick. Reports what the page did afterwards: a change
    /// line, "(field now shows ...)" when the field does not read back as typed, and the visible options of a
    /// combobox.
    func type(_ text: String, replace: Bool, into node: BrowserNode?) throws -> BrowserTypeOutcome {
        restoreSetup()
        if let node, ["combobox", "listbox"].contains(node.role),
           (try? callOnNode(node, "function(){return this.tagName==='SELECT';}")) as? Bool == true {
            return BrowserTypeOutcome(picked: try select(node, option: text))
        }
        markBaseline()
        if let node { try focus(node) }
        if replace, (try evaluate(Self.selectAllFocusedJS)) as? Bool != true {
            // The page script could not select the field's text (a field it cannot see into): select all by key.
            try pressKey("Cmd+A")
        }
        let (head, last) = BrowserRules.splitForTyping(text)
        if !head.isEmpty { _ = try cdp("Input.insertText", ["text": head]) }
        if let last { try sendTypedCharacter(last) }
        var outcome = BrowserTypeOutcome()
        outcome.change = settle()
        outcome.options = comboOptions()
        let actual: String?
        if let node {
            actual = try fieldText(node)
        } else {
            actual = try activeFieldText()
        }
        if let actual, !BrowserRules.fieldMatches(actual: actual, typed: text, replaced: replace) {
            outcome.note = "(field now shows \"\(actual.prefix(80))\"; check it, or type again with replace)"
        }
        return outcome
    }

    /// The last typed character as a real key event (keyDown carrying the text, then keyUp).
    private func sendTypedCharacter(_ character: Character) throws {
        guard let combo = BrowserKeyCombo.forTypedCharacter(character) else {
            _ = try cdp("Input.insertText", ["text": String(character)])
            return
        }
        try send(combo)
    }

    /// After typing into a combobox / autocomplete field: waits up to 200 ms for visible role=option entries and
    /// returns their text (at most 8). Any other field returns at once.
    private func comboOptions() -> [String] {
        // Polled from here (page timers stall in a background tab), at most about 200 ms.
        let start = Date()
        while true {
            let raw = try? cdp("Runtime.evaluate", ["returnByValue": true, "expression": Self.comboOptionsJS])
            guard let value = (raw?["result"] as? [String: Any])?["value"] as? [String: Any],
                  (value["combo"] as? Bool) == true else { return [] }
            let options = (value["options"] as? [Any] ?? []).compactMap { $0 as? String }
            if !options.isEmpty || Date().timeIntervalSince(start) >= 0.2 { return options }
            Thread.sleep(forTimeInterval: 0.04)
        }
    }

    private static let comboOptionsJS = """
    (function(){let el=document.activeElement;while(el&&el.shadowRoot&&el.shadowRoot.activeElement)el=el.shadowRoot.activeElement;\
    if(!el)return {combo:false};const a=(n)=>el.getAttribute(n)||'';\
    const combo=a('role')==='combobox'||a('aria-autocomplete')!==''||a('aria-haspopup')==='listbox'||a('aria-controls')!==''||el.hasAttribute('list');\
    if(!combo)return {combo:false};\
    const read=()=>{const out=[];for(const o of document.querySelectorAll('[role=option]')){let v=true;\
    try{v=o.checkVisibility?o.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}):o.offsetParent!==null;}catch(x){}\
    if(!v)continue;const t=(o.getAttribute('aria-label')||o.innerText||o.textContent||'').replace(/\\s+/g,' ').trim();\
    if(t)out.push(t.slice(0,60));if(out.length>=8)break;}return out;};\
    return {combo:true,options:read()};})()
    """

    /// Presses a key or key combination ("Enter", "Cmd+A", "ctrl+shift+z"): keyDown then keyUp.
    func pressKey(_ raw: String) throws {
        guard let combo = BrowserKeyCombo.parse(raw) else {
            throw ComputerUseError.invalidArguments(
                "browser: key \"\(raw)\" is not known; use Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home, End, PageUp/PageDown, or a letter or digit with Cmd, Ctrl, Alt or Shift (e.g. Cmd+A)"
            )
        }
        restoreSetup()
        try send(combo)
    }

    /// A key press followed by the one change line (Enter often submits or navigates).
    func pressKeyAndWatch(_ raw: String) throws -> BrowserChange {
        guard BrowserKeyCombo.parse(raw) != nil else { try pressKey(raw); return .none }
        restoreSetup()
        markBaseline()
        try pressKey(raw)
        return settle()
    }

    private func send(_ combo: BrowserKeyCombo) throws {
        var down: [String: Any] = [
            "type": "keyDown", "key": combo.key,
            "windowsVirtualKeyCode": combo.virtualKey, "modifiers": combo.modifiers,
        ]
        var up: [String: Any] = [
            "type": "keyUp", "key": combo.key,
            "windowsVirtualKeyCode": combo.virtualKey, "modifiers": combo.modifiers,
        ]
        if !combo.code.isEmpty { down["code"] = combo.code; up["code"] = combo.code }
        if let text = combo.text { down["text"] = text }
        if !combo.commands.isEmpty { down["commands"] = combo.commands }
        _ = try cdp("Input.dispatchKeyEvent", down)
        _ = try cdp("Input.dispatchKeyEvent", up)
    }

    private static let selectAllFocusedJS = """
    (function(){let el=document.activeElement;while(el&&el.shadowRoot&&el.shadowRoot.activeElement)el=el.shadowRoot.activeElement;if(!el)return false;\
    if(el.tagName==='INPUT'||el.tagName==='TEXTAREA'){el.select();return true;}\
    if(el.isContentEditable){const r=document.createRange();r.selectNodeContents(el);\
    const s=window.getSelection();s.removeAllRanges();s.addRange(r);return true;}\
    return false;})()
    """

    private func activeFieldText() throws -> String? {
        try evaluate("(function(){let el=document.activeElement;while(el&&el.shadowRoot&&el.shadowRoot.activeElement)el=el.shadowRoot.activeElement;if(!el)return null;"
            + "if(el.type==='password')return null;"
            + "if(el.tagName==='INPUT'||el.tagName==='TEXTAREA')return String(el.value);"
            + "if(el.isContentEditable)return el.innerText;return null;})()") as? String
    }

    private func fieldText(_ node: BrowserNode) throws -> String? {
        try callOnNode(node, "function(){if(this.type==='password')return null;if(this.tagName==='INPUT'||this.tagName==='TEXTAREA')return String(this.value);"
            + "if(this.isContentEditable)return this.innerText;return null;}") as? String
    }

    // MARK: Act: controls

    /// Ticks or unticks a checkbox, radio or switch. Reads the state first, clicks only when it must change, and
    /// reads it back afterwards.
    func setChecked(_ node: BrowserNode, desired: Bool) throws -> String {
        let word = desired ? "checked" : "unchecked"
        markBaseline()
        let state = try checkedState(node)
        if state == "unknown" {
            throw ComputerUseError.invalidArguments("browser: \(node.role) \"\(node.name)\" does not report checked or unchecked; click it instead")
        }
        if (state == "true") == desired { return "\"\(node.name)\" was already \(word)" }
        if !desired && node.role == "radio" {
            throw ComputerUseError.invalidArguments("browser: a radio button cannot be unchecked; choose another option instead")
        }
        try click(node)
        let after = try checkedState(node)
        guard (after == "true") == desired else {
            throw ComputerUseError.message("browser: clicked \"\(node.name)\" but it still reads \(after); click it by label to retry")
        }
        return "\(node.role) \"\(node.name)\" is now \(word)"
    }

    private func checkedState(_ node: BrowserNode) throws -> String {
        (try callOnNode(node, "function(){if(this.tagName==='INPUT'&&(this.type==='checkbox'||this.type==='radio'))"
            + "return this.checked?'true':'false';"
            + "const a=this.getAttribute('aria-checked');if(a==='true'||a==='false'||a==='mixed')return a;"
            + "const c=this.querySelector&&this.querySelector('input[type=checkbox],input[type=radio]');"
            + "if(c)return c.checked?'true':'false';return 'unknown';}") as? String) ?? "unknown"
    }

    /// Chooses an option by its text (or value). A native <select> is set directly with input and change events;
    /// any other control is opened and the option clicked by its label.
    func select(_ node: BrowserNode, option: String) throws -> String {
        restoreSetup()
        let listing = try callOnNode(node, "function(){if(this.tagName!=='SELECT')return null;"
            + "return JSON.stringify(Array.from(this.options).map(o=>[o.text,o.value]));}")
        guard let json = listing as? String, let rows = BrowserRules.optionRows(json) else {
            try click(node)
            settle()
            // The opened list's own entry first: a link elsewhere on the page with the same text is not it.
            let listRoles: Set<String> = ["option", "menuitem", "menuitemradio", "menuitemcheckbox", "treeitem", "radio"]
            let wanted = Self.normalize(option)
            let entries = ((try? queryNamed(option)) ?? []).filter { listRoles.contains($0.role) && Self.normalize($0.name) == wanted }
            let choice = Set(entries.map(\.backendNodeID)).count == 1 ? entries[0] : try resolve(label: option, index: nil)
            try click(choice)
            let change = settle()
            return "opened \"\(node.name)\" and chose \"\(choice.name)\"; \(change.line)"
        }
        switch BrowserRules.matchOption(option, options: rows) {
        case .found(let position):
            markBaseline()
            let chosen = try callOnNode(node, "function(i){this.focus();this.selectedIndex=i;"
                + "this.dispatchEvent(new Event('input',{bubbles:true}));"
                + "this.dispatchEvent(new Event('change',{bubbles:true}));"
                + "return this.options[this.selectedIndex].text;}", arguments: [position]) as? String
            let change = settle()
            return "chose \"\(chosen ?? rows[position].text)\" in \"\(node.name)\"; \(change.line)"
        case .none:
            let names = rows.prefix(12).map { "\"\($0.text)\"" }.joined(separator: ", ")
            throw ComputerUseError.invalidArguments("browser: \"\(option)\" is not an option of \"\(node.name)\". Options: \(names)")
        case .ambiguous(let positions):
            let names = positions.prefix(8).map { "\"\(rows[$0].text)\"" }.joined(separator: ", ")
            throw ComputerUseError.invalidArguments("browser: \"\(option)\" matches several options: \(names). Use the exact text")
        }
    }

    // MARK: Act: scroll and history

    /// Scrolls the page: up, down, left, right, top or bottom, by `amount` pixels or most of a screen.
    func scrollPage(direction: String, amount: Int?) throws -> String {
        let pixels = Swift.max(0, amount ?? 0)
        let raw = try evaluate("(function(dir,amt){const e=document.scrollingElement||document.documentElement;"
            + "const d=amt>0?amt:Math.round(window.innerHeight*0.8);let x=0,y=0;"
            + "if(dir==='down')y=d;else if(dir==='up')y=-d;else if(dir==='right')x=d;else if(dir==='left')x=-d;"
            + "if(dir==='top')window.scrollTo({top:0,behavior:'instant'});"
            + "else if(dir==='bottom')window.scrollTo({top:e.scrollHeight,behavior:'instant'});"
            + "else window.scrollBy({left:x,top:y,behavior:'instant'});"
            + "return [window.scrollY,Math.max(0,e.scrollHeight-window.innerHeight)];})('\(direction)',\(pixels))")
        guard let values = raw as? [Any], values.count == 2, let top = BrowserRules.number(values[0]),
              let bottom = BrowserRules.number(values[1])
        else {
            throw ComputerUseError.message("browser: the page did not scroll; browser read to check it has content")
        }
        return BrowserRules.scrollSummary(direction: direction, top: top, bottom: bottom)
    }

    /// Scrolls the nearest scrollable box at or around the element (a list, a panel).
    func scrollElement(_ node: BrowserNode, direction: String, amount: Int?) throws -> String {
        let raw = try callOnNode(node, "function(dir,amt){const d=amt>0?amt:Math.round(window.innerHeight*0.8);"
            + "const can=(e)=>{if(!e||e.nodeType!==1)return false;const s=getComputedStyle(e);"
            + "return /(auto|scroll|overlay)/.test(s.overflowY+' '+s.overflowX)&&"
            + "(e.scrollHeight>e.clientHeight+1||e.scrollWidth>e.clientWidth+1);};"
            + "let el=this;while(el&&!can(el))el=el.parentElement;"
            + "if(!el){let best=null;for(const c of this.querySelectorAll('*')){if(can(c)&&(!best||c.clientHeight>best.clientHeight))best=c;}el=best;}"
            + "if(!el)return null;"
            + "if(dir==='top')el.scrollTo({top:0,behavior:'instant'});"
            + "else if(dir==='bottom')el.scrollTo({top:el.scrollHeight,behavior:'instant'});"
            + "else el.scrollBy({left:dir==='right'?d:(dir==='left'?-d:0),top:dir==='down'?d:(dir==='up'?-d:0),behavior:'instant'});"
            + "return [el.scrollTop,el.scrollHeight-el.clientHeight];}", arguments: [direction, Swift.max(0, amount ?? 0)])
        guard let values = raw as? [Any], values.count == 2, let top = BrowserRules.number(values[0]),
              let bottom = BrowserRules.number(values[1])
        else {
            throw ComputerUseError.invalidArguments("browser: \"\(node.name)\" does not scroll; leave out the label to scroll the page")
        }
        return "\"\(node.name)\": " + BrowserRules.scrollSummary(direction: direction, top: top, bottom: bottom)
    }

    /// Back, forward or reload in this tab, waiting for the page to load again.
    func history(_ operation: String) throws -> String {
        if operation == "reload" {
            let before = try location()
            _ = try cdp("Page.reload", ["ignoreCache": false])
            Thread.sleep(forTimeInterval: 0.15)
            waitLoad(changedFrom: before.href, timeout: 20)
            settle()
            return "reloaded \(title(try? location()))"
        }
        enableOnce("Page.enable")
        let payload = try cdp("Page.getNavigationHistory")
        let entries = payload["entries"] as? [[String: Any]] ?? []
        let current = (payload["currentIndex"] as? NSNumber)?.intValue ?? -1
        let forward = operation == "forward"
        guard let target = BrowserRules.historyTarget(current: current, count: entries.count, forward: forward),
              let entryID = (entries[target]["id"] as? NSNumber)?.intValue
        else {
            throw ComputerUseError.invalidArguments("browser: there is no page \(operation) in this tab; use browser go with a URL")
        }
        let before = try location()
        _ = try cdp("Page.navigateToHistoryEntry", ["entryId": entryID])
        waitLoad(changedFrom: before.href, timeout: 20)
        settle()
        return "went \(operation) to \(title(try? location()))"
    }

    /// "Title — address" for a reply line.
    func title(_ place: BrowserLocation?) -> String {
        guard let place else { return "the page" }
        return place.title.isEmpty ? place.href : "\(place.title) — \(place.href)"
    }

    // MARK: Wait

    /// Waits until the document is interactive or complete. With `expect`, also waits for that address (a redirect
    /// is accepted after four seconds). Without it, waits for the address to change from `old`, or for a page that
    /// stays at the same address, a short while.
    @discardableResult
    func waitLoad(changedFrom old: String?, expect: String? = nil, timeout: TimeInterval) -> Bool {
        let start = Date()
        let deadline = start.addingTimeInterval(min(timeout, max(0, BrowserCallBudget.remaining() - 1)))
        while true {
            if let here = try? location(), here.readyState == "interactive" || here.readyState == "complete" {
                let elapsed = Date().timeIntervalSince(start)
                let arrived: Bool
                if let expect {
                    arrived = BrowserRules.sameAddress(here.href, expect) || (elapsed > 4 && here.href != "about:blank")
                } else {
                    arrived = old == nil || here.href != old || elapsed > 1.5
                }
                if arrived { return true }
            }
            if Date() >= deadline { return false }
            do { try BrowserRequestContext.validateCurrent() } catch { return false }
            Thread.sleep(forTimeInterval: 0.12)
        }
    }

    /// After a click on a link that leads elsewhere: when the address moves on within 1.5 s, waits for that page
    /// to load and returns it.
    func followNavigation(from old: String) -> BrowserLocation? {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if let here = try? location(), here.href != old {
                waitLoad(changedFrom: old, timeout: 20)
                settle()
                prime()
                return try? location()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Takes the "before" mark for the change line: the page's mutation counter and address now.
    func markBaseline() {
        _ = try? evaluate("window.__gs?(__gs.seen=__gs.mut,__gs.href=location.href,__gs.nav=false,1):0")
    }

    /// The one wait after an action, event based inside the page (no polling from here): the document is
    /// complete, no request started less than 1.5 s ago is still open, and nothing was added, removed or
    /// toggled in the DOM for 80 ms, at most `cap` ms. Says what happened since `markBaseline` (or the click's
    /// probe): navigated (a new address, or a page load in progress), page changed, or no change.
    /// The page's visible text lines (trimmed, non-empty, at most 400), or nil when it cannot be read.
    func visibleTextLines() -> [String]? {
        let raw = try? cdp("Runtime.evaluate", ["returnByValue": true,
            "expression": "(document.body?document.body.innerText:'').slice(0,20000)"])
        guard let text = (raw?["result"] as? [String: Any])?["value"] as? String else { return nil }
        return Array(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(400))
    }

    @discardableResult
    func settle(cap: Int = 800) -> BrowserChange {
        // Polled from here with quick synchronous reads. A promise that waits inside the page never settled in a
        // background tab (Chrome throttles its timers), so each wait hung until the 15 s command timeout.
        let start = Date()
        var last: [String: Any]?
        while true {
            let payload = try? cdp("Runtime.evaluate", ["returnByValue": true, "expression": Self.settleProbeJS])
            guard let value = (payload?["result"] as? [String: Any])?["value"] as? [String: Any],
                  (value["ok"] as? Bool) == true
            else {
                if payload == nil {
                    // The page script died with its document: a navigation. Let the new page load, then say where.
                    waitLoad(changedFrom: nil, timeout: 8)
                    prime()
                    if let here = try? location() { return .navigated(here.href) }
                }
                return last.map(BrowserRules.change) ?? .none
            }
            last = value
            if (value["quiet"] as? Bool) == true || Date().timeIntervalSince(start) * 1000 >= Double(cap) { break }
            Thread.sleep(forTimeInterval: 0.04)
        }
        guard let value = last else { return .none }
        if (value["nav"] as? Bool) == true {
            // A page unload started but did not finish within the cap: wait for the new page.
            waitLoad(changedFrom: value["seenHref"] as? String, timeout: 20)
            prime()
            if let here = try? location() { return .navigated(here.href) }
        }
        return BrowserRules.change(value)
    }

    /// One synchronous look at the page-side state (no promise, no page timers).
    static let settleProbeJS = """
    (function(){var g=window.__gs;if(!g)return {ok:false};var now=performance.now(),n=0;g.req.forEach(function(t){if(now-t<1500)n++;});\
    var nav=!!g.nav&&document.readyState!=='complete';\
    return {ok:true,mut:g.mut,seen:g.seen,href:location.href,seenHref:g.href||null,nav:nav,pending:n,\
    quiet:document.readyState==='complete'&&now-g.last>=80&&n===0&&!g.nav};})()
    """

    static func settleJS(cap: Int) -> String { settleProbeJS }

    /// Page-side state for the change line and the settle: a DOM mutation counter and time, open requests
    /// (fetch and XMLHttpRequest, with their start times), and an unload flag. Installed in every document of the
    /// agent's tab.
    static let pageStateJS = """
    (function(){if(window.__gs)return;var g=window.__gs={mut:0,seen:0,last:performance.now(),href:null,nav:false,req:new Map()};var id=0;\
    try{new MutationObserver(function(){g.mut++;g.last=performance.now();}).observe(document,{subtree:true,childList:true,characterData:true,\
    attributes:true,attributeFilter:['aria-expanded','aria-hidden','aria-selected','aria-checked','aria-busy','hidden','open','disabled','value','checked','class']});}catch(e){}\
    try{var f=window.fetch;if(typeof f==='function'&&!f.__gsw){var wf=function(){var k=++id;g.req.set(k,performance.now());var p;\
    try{p=f.apply(this,arguments);}catch(e){g.req.delete(k);throw e;}\
    try{var d=function(){g.req.delete(k);};if(p&&typeof p.then==='function')p.then(d,d);else d();}catch(e){g.req.delete(k);}return p;};wf.__gsw=1;window.fetch=wf;}}catch(e){}\
    try{var s=XMLHttpRequest.prototype.send;if(typeof s==='function'&&!s.__gsw){var ws=function(){var k=++id;g.req.set(k,performance.now());\
    try{this.addEventListener('loadend',function(){g.req.delete(k);});}catch(e){}\
    try{return s.apply(this,arguments);}catch(e){g.req.delete(k);throw e;}};ws.__gsw=1;XMLHttpRequest.prototype.send=ws;}}catch(e){}\
    window.addEventListener('beforeunload',function(){g.nav=true;});window.addEventListener('pageshow',function(){g.nav=false;});})()
    """

    /// Waits for the text to appear on the page, or for a labelled element to exist. False when the time runs out.
    func waitFor(text: String?, label: String?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let text, (try? evaluate("!!(document.body&&document.body.innerText.includes(\(BrowserRules.jsLiteral(text))))")) as? Bool == true {
                return true
            }
            if let label, let named = try? queryNamedAny(label), !named.isEmpty {
                return true
            }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func queryNamedAny(_ label: String) throws -> [[String: Any]] {
        try queryNamedRaw(label).filter { ($0["ignored"] as? Bool) != true }
    }

    // MARK: CDP plumbing

    /// Calls a JavaScript function with `this` set to the element. Returns the function's JSON value.
    func callOnNode(_ node: BrowserNode, _ function: String, arguments: [Any] = []) throws -> Any? {
        let resolved = try cdp("DOM.resolveNode", ["backendNodeId": node.backendNodeID])
        guard let object = resolved["object"] as? [String: Any], let objectID = object["objectId"] as? String else {
            throw ComputerUseError.message("browser: \"\(node.name)\" is gone from the page; browser read again")
        }
        let payload = try cdp("Runtime.callFunctionOn", [
            "objectId": objectID,
            "functionDeclaration": function,
            "arguments": arguments.map { ["value": $0] },
            "returnByValue": true,
        ])
        if payload["exceptionDetails"] != nil {
            throw ComputerUseError.message("browser: the page script failed on \"\(node.name)\"; try another control")
        }
        return (payload["result"] as? [String: Any])?["value"]
    }

    /// Runs a page expression and returns its JSON value (nil when it threw).
    func evaluate(_ expression: String) throws -> Any? {
        let payload = try cdp("Runtime.evaluate", ["expression": expression, "returnByValue": true])
        if payload["exceptionDetails"] != nil { return nil }
        return (payload["result"] as? [String: Any])?["value"]
    }

    /// Other Chrome extensions (coupon finders, password helpers) put their own frames into pages, and Chrome
    /// then cuts every outside tool off from the tab ("Cannot access a chrome-extension:// URL of different
    /// extension"). In the agent's own tab such frames are removed the moment they are added, on this document
    /// and on every later one. The user's own tabs are never touched.
    private static let foreignFrameGuardJS = """
    (function(){if(window.__godspeedFrameGuard)return;window.__godspeedFrameGuard=true;\
    const bad=(n)=>n&&n.tagName==='IFRAME'&&/^(chrome|moz)-extension:/.test(n.getAttribute('src')||n.src||'');\
    const sweep=(root)=>{try{if(bad(root)){root.remove();return;}\
    if(root.querySelectorAll){for(const f of root.querySelectorAll('iframe'))if(bad(f))f.remove();\
    for(const e of root.querySelectorAll('*'))if(e.shadowRoot)watch(e.shadowRoot);}\
    if(root.shadowRoot)watch(root.shadowRoot);}catch(e){}};\
    const seen=new WeakSet();\
    function watch(target){if(seen.has(target))return;seen.add(target);\
    new MutationObserver((list)=>{for(const m of list){if(m.type==='attributes'){if(bad(m.target))m.target.remove();}\
    else for(const n of m.addedNodes)if(n.nodeType===1)sweep(n);}})\
    .observe(target,{subtree:true,childList:true,attributes:true,attributeFilter:['src']});sweep(target);}\
    watch(document);})()
    """

    private func guardForeignFrames() {
        let key = domainKey("foreign-frame-guard")
        if BrowserPageMemory.shared.isEnabled(key) { return }
        let setup = Self.foreignFrameGuardJS + "\n;" + Self.pageStateJS
        guard (try? cdp("Page.addScriptToEvaluateOnNewDocument", ["source": setup])) != nil else { return }
        _ = try? evaluate(setup)
        BrowserPageMemory.shared.markEnabled(key)
    }

    /// Enables a CDP domain or runs a one-time setup method once per tab (per OBU session), then remembers it.
    private func enableOnce(_ method: String, _ params: [String: Any] = [:]) {
        let key = domainKey(method)
        if BrowserPageMemory.shared.isEnabled(key) { return }
        // Best effort: a method that refuses is not remembered, so the next call tries again.
        if (try? cdp(method, params)) != nil { BrowserPageMemory.shared.markEnabled(key) }
    }

    private func domainKey(_ method: String) -> String {
        "\(bridge.referenceScope)|\(tabID ?? -1)|\(bridge.referenceGeneration)|\(method)"
    }

    private func forgetDomain(_ method: String) {
        BrowserPageMemory.shared.forget(domainKey(method))
    }

    @discardableResult
    private func cdp(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        if let indexedGeneration, indexedGeneration != bridge.referenceGeneration {
            throw Self.staleIndex
        }
        do {
            return try cdpOnce(method, params)
        } catch let error as BrowserLinkDropped {
            // The new link starts without what was set up on the old one (focus emulation, accessibility,
            // the frame guard): forget that it was done, so it is done again.
            if let tabID { BrowserPageMemory.shared.forgetTab(bridge: bridge, tab: tabID) }
            if indexedGeneration != nil {
                // Do not send any more commands using the old resolution, even if a caller catches this error.
                indexedGeneration = -1
                throw ComputerUseError.message("browser: the tab connection changed; browser read to check what happened before continuing")
            }
            // Chrome dropped the link to the tab, usually because another extension put a frame into the page
            // (the guard above removes it). A command that is harmless twice is sent again once the link is
            // back; a click, key or typed text is not, in case it did arrive.
            guard Self.isRepeatSafe(method, params) else {
                throw ComputerUseError.message(
                    "browser: the link to the tab dropped for a moment while acting (another Chrome extension put a panel into the page). browser read to see whether the step happened, then repeat it if not"
                )
            }
            for wait in [0.3, 0.8, 1.5] {
                Thread.sleep(forTimeInterval: wait)
                do {
                    let result = try cdpOnce(method, params)
                    restoreSetup()
                    return result
                } catch is BrowserLinkDropped {
                    continue
                }
            }
            throw ComputerUseError.message("browser: \(BrowserReply.explain(error.text))")
        }
    }

    /// What every action relies on in the agent's background tab: the page behaves as focused (so clicks and
    /// keys are processed), and other extensions' frames are removed.
    private func restoreSetup() {
        enableOnce("Emulation.setFocusEmulationEnabled", ["enabled": true])
        guardForeignFrames()
    }

    /// Called once a page has loaded. Another extension may put its frame into a page the moment the page
    /// becomes active, which drops the link; this makes that happen now, where it is absorbed, and not in the
    /// middle of the model's first click.
    func prime() {
        restoreSetup()
        // Wait here, not in the page: page timers stall in a background tab.
        Thread.sleep(forTimeInterval: 0.3)
        _ = try? cdp("Runtime.evaluate", ["expression": "1", "returnByValue": true])
    }

    /// Chrome reported the tab as not attached (or detached mid-command).
    private struct BrowserLinkDropped: Error { let text: String }

    private static func linkDropped(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["detached while handling", "debugger unattached", "debugger is not attached", "not attached to the tab",
                "cannot access a chrome-extension"].contains { lower.contains($0) }
    }

    /// Commands that read, move the pointer or scroll into view can be sent twice; presses, keys and text cannot.
    static func isRepeatSafe(_ method: String, _ params: [String: Any]) -> Bool {
        switch method {
        case "Input.insertText", "Input.dispatchKeyEvent", "Page.handleJavaScriptDialog":
            return false
        case "Input.dispatchMouseEvent":
            return (params["type"] as? String) == "mouseMoved"
        case "Runtime.callFunctionOn", "Runtime.evaluate":
            // Page scripts may act (set a select, scroll); only the plain reads GODSPEED sends are repeated.
            let source = (params["functionDeclaration"] as? String) ?? (params["expression"] as? String) ?? ""
            return !["dispatchEvent", "selectedIndex=", ".click(", "scrollBy", "scrollTo", ".select()", ".focus()"].contains { source.contains($0) }
        default:
            return true
        }
    }

    private static let traceLock = NSLock()

    /// `OPEN_COMPUTER_USE_BROWSER_TRACE=1`: one line per Chrome command in ~/.godspeed/browser-trace.log.
    private static func trace(_ line: @autoclosure () -> String) {
        guard BrowserRequestContext.environment["OPEN_COMPUTER_USE_BROWSER_TRACE"] != nil else { return }
        traceLock.lock()
        defer { traceLock.unlock() }
        let path = NSHomeDirectory() + "/.godspeed/browser-trace.log"
        let text = String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + line() + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.godspeed", withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private func cdpOnce(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        Self.trace("\(method) \((params["type"] as? String) ?? "")")
        do {
            return try cdpSend(method, params)
        } catch {
            Self.trace("  FAILED \(method): \(String(describing: error).prefix(120))")
            throw error
        }
    }

    private func cdpSend(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        var arguments = tab
        arguments["method"] = method
        arguments["params"] = params
        let reply: (text: String, isError: Bool)
        do {
            // A label lookup that stalls (the link dropping under it) falls back to the full tree; waiting the
            // full 15 s for it cost 10 s per click.
            let base: TimeInterval = method == "Accessibility.queryAXTree" ? 2.5 : 15
            let remaining = BrowserCallBudget.remaining()
            guard remaining > 0.3 else {
                throw ComputerUseError.message("browser: Chrome is answering slowly, so this step stopped after \(Int(BrowserCallBudget.limit)) s. browser read to see where it got to, then continue")
            }
            reply = try bridge.callTool("cdp", arguments: arguments, timeout: min(base, remaining), referenceGeneration: indexedGeneration)
        } catch {
            if answeredDialog(after: method, failure: String(describing: error)) { throw Self.dialogAnswered }
            throw error
        }
        if reply.isError {
            if Self.linkDropped(reply.text) { throw BrowserLinkDropped(text: reply.text) }
            if answeredDialog(after: method, failure: reply.text) { throw Self.dialogAnswered }
            throw ComputerUseError.message("browser: \(BrowserReply.explain(reply.text))")
        }
        guard let data = reply.text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return [:]
        }
        // OBU passes CDP failures back as a normal reply carrying a JSON-RPC `error`; treat it as a failure.
        let error = (object["error"] as? [String: Any]) ?? ((object["result"] as? [String: Any])?["error"] as? [String: Any])
        if let error {
            let message = (error["message"] as? String) ?? "error"
            if Self.linkDropped(message) { throw BrowserLinkDropped(text: message) }
            throw ComputerUseError.message("browser: \(BrowserReply.explain(message))")
        }
        return (object["result"] as? [String: Any]) ?? object
    }

    private static let dialogAnswered = ComputerUseError.message(
        "browser: the page was showing an alert or confirm box, which blocks everything; it was answered with OK. browser read to see the result"
    )

    /// A command that timed out may be waiting behind a JavaScript alert or confirm. Answers it (OK) and reports
    /// whether one was open; Chrome refuses when none is.
    private func answeredDialog(after method: String, failure: String) -> Bool {
        let lower = failure.lowercased()
        guard method != "Page.handleJavaScriptDialog", lower.contains("timed out") || lower.contains("timeout") || lower.contains("did not answer") else {
            return false
        }
        var arguments = tab
        arguments["method"] = "Page.handleJavaScriptDialog"
        arguments["params"] = ["accept": true]
        guard let reply = try? bridge.callTool("cdp", arguments: arguments, timeout: 6), !reply.isError,
              !reply.text.lowercased().contains("no dialog"), !reply.text.contains("\"error\"") else { return false }
        return true
    }

    /// The first value stored under `key`, searching nested objects a few levels deep (OBU may wrap
    /// the CDP result in an envelope).
    static func find(_ key: String, in object: Any, depth: Int = 4) -> Any? {
        guard depth > 0, let dictionary = object as? [String: Any] else { return nil }
        if let value = dictionary[key] { return value }
        for value in dictionary.values {
            if let found = find(key, in: value, depth: depth - 1) { return found }
        }
        return nil
    }

    static func axValue(_ object: Any?) -> String? {
        guard let dictionary = object as? [String: Any], let value = dictionary["value"] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func containsWords(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            Array(haystack[start..<(start + needle.count)]) == needle
        }
    }
}

/// Pure rules behind the browser actions: no CDP, no process, so they are unit-tested directly.
enum BrowserRules {
    /// The web address a link opens in a new tab when it is clicked (`target="_blank"`), or nil for a link that
    /// stays in its tab. Such a link is opened in the background instead, so Chrome does not bring it forward.
    static func newTabLinkURL(href: String, target: String) -> String? {
        let lower = href.lowercased()
        guard target.trimmingCharacters(in: .whitespaces).lowercased() == "_blank",
              lower.hasPrefix("http://") || lower.hasPrefix("https://")
        else {
            return nil
        }
        return href
    }

    /// The option index a select should take for `wanted`: exact text, then exact value, then one text that
    /// contains it. Several equally good candidates are ambiguous, never a guess.
    static func matchOption(_ wanted: String, options: [(text: String, value: String)]) -> BrowserOptionMatch {
        let want = spaces(wanted.lowercased())
        guard !want.isEmpty else { return .none }
        let texts = options.map { spaces($0.text.lowercased()) }
        let values = options.map { spaces($0.value.lowercased()) }
        let groups = [
            texts.indices.filter { texts[$0] == want },
            values.indices.filter { values[$0] == want },
            texts.indices.filter { texts[$0].contains(want) },
        ]
        for group in groups {
            if group.count == 1 { return .found(group[0]) }
            if group.count > 1 { return .ambiguous(group) }
        }
        return .none
    }

    /// `[[text, value], …]` from the page's JSON listing.
    static func optionRows(_ json: String) -> [(text: String, value: String)]? {
        guard let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]]
        else { return nil }
        return rows.map { row in
            (text: (row.first as? String) ?? "", value: row.count > 1 ? ((row[1] as? String) ?? "") : "")
        }
    }

    /// The change line from the settle script's answer: a new address is a navigation, a moved mutation counter
    /// is a page change, anything else no change. Without a baseline address nothing is called a navigation.
    static func change(_ value: [String: Any]) -> BrowserChange {
        let href = value["href"] as? String ?? ""
        if let before = value["seenHref"] as? String, !before.isEmpty, !href.isEmpty, before != href { return .navigated(href) }
        if let mut = number(value["mut"] ?? 0), let seen = number(value["seen"] ?? 0), mut != seen { return .changed }
        return .none
    }

    /// Identity of a control across reads: its role and name (a re-rendered list keeps these).
    static func controlKeys(_ nodes: [BrowserNode]) -> Set<String> {
        Set(nodes.map { "\($0.role)\u{1}\($0.name)" })
    }

    /// Marks the controls whose role and name were not in the previous read. No previous read, or every control
    /// new (another page), marks nothing.
    static func markNew(_ nodes: [BrowserNode], previousKeys: Set<String>?) -> [BrowserNode] {
        guard let previousKeys, !previousKeys.isEmpty else { return nodes }
        var marked = nodes
        var count = 0
        for position in marked.indices {
            let key = "\(marked[position].role)\u{1}\(marked[position].name)"
            if !previousKeys.contains(key) { marked[position].isNew = true; count += 1 }
        }
        return count == marked.count ? nodes : marked
    }

    /// The text kept as a control's surroundings: collapsed, 40 characters, nothing with digits (counters and
    /// prices change on their own) and nothing that is the control's own name.
    static func contextText(_ text: String, excluding name: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count >= 3, clean != name, !clean.contains(where: \.isNumber) else { return "" }
        return String(clean.prefix(40))
    }

    enum Fingerprint: Equatable {
        case same
        case renamed(String)
        case valueChanged(String)
    }

    /// Compares an element as read with how it looks now. A changed name is a different element. A changed
    /// value counts only for roles whose value is not what the user edits (not fields, sliders or lists).
    static func fingerprint(_ node: BrowserNode, nowName: String, nowValue: String) -> Fingerprint {
        if !nowName.isEmpty, nowName != node.name { return .renamed(nowName) }
        let editable = BrowserPage.fieldRoles.union(["slider", "combobox", "listbox", "checkbox", "radio", "switch"])
        if !editable.contains(node.role), !node.value.isEmpty, !nowValue.isEmpty, nowValue != node.value {
            return .valueChanged(nowValue)
        }
        return .same
    }

    static func coveredMessage(role: String, name: String, by what: String) -> String {
        "browser: \(role) \"\(name.prefix(60))\" is covered by something on top of it"
            + (what.isEmpty ? "" : " (\"\(what.prefix(60))\")")
            + ". Close or move that first (its Accept, Close or X button, or key Escape), then try again"
    }

    /// Whether a link's address can move the tab: false for "#...", javascript: and empty links.
    static func leadsElsewhere(href: String) -> Bool {
        let lower = href.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.isEmpty || lower.hasPrefix("#") || lower.hasPrefix("javascript:") { return false }
        return true
    }

    /// Typed text split for the keyboard: everything but the last character is inserted in one go, the last is
    /// sent as a key event. A text ending in a line break is inserted whole (a newline is not a key to fake).
    static func splitForTyping(_ text: String) -> (head: String, last: Character?) {
        guard let last = text.last, !last.isNewline else { return (text, nil) }
        return (String(text.dropLast()), last)
    }

    /// Whether the field's value reads back as typed. Replacing needs the whole value to equal the text; appending
    /// needs the text to appear in the value. Whitespace is compared loosely.
    static func fieldMatches(actual: String, typed: String, replaced: Bool) -> Bool {
        if replaced { return spaces(actual) == spaces(typed) }
        return spaces(actual).contains(spaces(typed))
    }

    /// Scroll words accepted for `direction`, or nil when the word is not one.
    static func scrollDirection(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "up", "page up", "pageup": return "up"
        case "down", "page down", "pagedown": return "down"
        case "left": return "left"
        case "right": return "right"
        case "top", "start", "home": return "top"
        case "bottom", "end": return "bottom"
        default: return nil
        }
    }

    /// What a scroll reports: the position in words, never a number a model has to decode.
    /// `bottom` is how far the page can scroll in total.
    static func scrollSummary(direction: String, top: Double, bottom: Double) -> String {
        guard bottom > 1 else { return "nothing to scroll: the page fits on screen" }
        if top <= 1 { return "scrolled \(direction); at the top" }
        if top >= bottom - 1 { return "scrolled \(direction); at the bottom" }
        let percent = Swift.min(99, Swift.max(1, Int((top / bottom * 100).rounded())))
        return "scrolled \(direction); \(percent)% of the way down the page"
    }

    /// The history entry to go to: the one before the current entry, or the one after it.
    static func historyTarget(current: Int, count: Int, forward: Bool) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }
        let target = forward ? current + 1 : current - 1
        return (0..<count).contains(target) ? target : nil
    }

    /// A Swift string as a JavaScript string literal, safe for any text.
    static func jsLiteral(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data("[\"\"]".utf8)
        let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }

    /// Same address for waiting purposes: case and a trailing slash are ignored.
    static func sameAddress(_ actual: String, _ expected: String) -> Bool {
        func trim(_ value: String) -> String {
            var text = value.lowercased()
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return trim(actual).hasPrefix(trim(expected))
    }

    static func number(_ value: Any) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        return nil
    }

    private static func spaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum BrowserOptionMatch: Equatable {
    case found(Int)
    case none
    case ambiguous([Int])
}

/// A key combination for CDP: its key names, the modifier bitmask and the mac editing command, if any.
struct BrowserKeyCombo: Equatable, Sendable {
    let key: String
    let code: String
    let virtualKey: Int
    let text: String?
    let modifiers: Int
    let commands: [String]

    /// CDP modifier bits.
    static let alt = 1
    static let control = 2
    static let meta = 4
    static let shift = 8

    private struct NamedKey: Sendable {
        let key: String
        let code: String
        let virtualKey: Int
        let text: String?
    }

    private static let named: [String: NamedKey] = [
        "enter": NamedKey(key: "Enter", code: "Enter", virtualKey: 13, text: "\r"),
        "return": NamedKey(key: "Enter", code: "Enter", virtualKey: 13, text: "\r"),
        "tab": NamedKey(key: "Tab", code: "Tab", virtualKey: 9, text: nil),
        "escape": NamedKey(key: "Escape", code: "Escape", virtualKey: 27, text: nil),
        "esc": NamedKey(key: "Escape", code: "Escape", virtualKey: 27, text: nil),
        "backspace": NamedKey(key: "Backspace", code: "Backspace", virtualKey: 8, text: nil),
        "delete": NamedKey(key: "Delete", code: "Delete", virtualKey: 46, text: nil),
        "space": NamedKey(key: " ", code: "Space", virtualKey: 32, text: " "),
        "arrowup": NamedKey(key: "ArrowUp", code: "ArrowUp", virtualKey: 38, text: nil),
        "up": NamedKey(key: "ArrowUp", code: "ArrowUp", virtualKey: 38, text: nil),
        "arrowdown": NamedKey(key: "ArrowDown", code: "ArrowDown", virtualKey: 40, text: nil),
        "down": NamedKey(key: "ArrowDown", code: "ArrowDown", virtualKey: 40, text: nil),
        "arrowleft": NamedKey(key: "ArrowLeft", code: "ArrowLeft", virtualKey: 37, text: nil),
        "left": NamedKey(key: "ArrowLeft", code: "ArrowLeft", virtualKey: 37, text: nil),
        "arrowright": NamedKey(key: "ArrowRight", code: "ArrowRight", virtualKey: 39, text: nil),
        "right": NamedKey(key: "ArrowRight", code: "ArrowRight", virtualKey: 39, text: nil),
        "pageup": NamedKey(key: "PageUp", code: "PageUp", virtualKey: 33, text: nil),
        "pagedown": NamedKey(key: "PageDown", code: "PageDown", virtualKey: 34, text: nil),
        "home": NamedKey(key: "Home", code: "Home", virtualKey: 36, text: nil),
        "end": NamedKey(key: "End", code: "End", virtualKey: 35, text: nil),
    ]

    /// Mac editing commands that Chrome needs with Cmd (CDP `commands`), so the shortcut works on macOS.
    private static let macEditing: [String: String] = ["a": "selectAll", "c": "copy", "v": "paste", "x": "cut", "z": "undo"]
    private static let macMoves: [String: String] = [
        "arrowleft": "moveToBeginningOfLine", "arrowright": "moveToEndOfLine",
        "arrowup": "moveToBeginningOfDocument", "arrowdown": "moveToEndOfDocument",
    ]

    /// The key event for one typed character: letters, digits and space map to their real keys (capitals with
    /// Shift); anything else carries only its text.
    static func forTypedCharacter(_ character: Character) -> BrowserKeyCombo? {
        if character == " " { return parse("space") }
        if character.isASCII, character.isLetter {
            let lower = String(character).lowercased()
            return parse(character.isUppercase ? "Shift+\(lower)" : lower)
        }
        if character.isASCII, character.isNumber { return parse(String(character)) }
        let text = String(character)
        return BrowserKeyCombo(key: text, code: "", virtualKey: 0, text: text, modifiers: 0, commands: [])
    }

    /// "Enter", "Cmd+A", "ctrl+shift+z", "Shift+a", "cmd+arrowleft". Nil when a part is unknown.
    static func parse(_ raw: String) -> BrowserKeyCombo? {
        let pieces = raw.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let base = pieces.last, !base.isEmpty else { return nil }
        var modifiers = 0
        for piece in pieces.dropLast() {
            switch piece.lowercased() {
            case "cmd", "command", "meta", "super", "win": modifiers |= meta
            case "ctrl", "control": modifiers |= control
            case "alt", "option", "opt": modifiers |= alt
            case "shift": modifiers |= shift
            default: return nil
            }
        }
        let lower = base.lowercased()
        let shifted = modifiers & shift != 0
        let usesShortcut = modifiers & (meta | control | alt) != 0
        let macMeta = modifiers & meta != 0

        if let key = named[lower] {
            let command = macMeta ? macMoves[lower].map { shifted ? $0 + "AndModifySelection" : $0 } : nil
            return BrowserKeyCombo(
                key: key.key, code: key.code, virtualKey: key.virtualKey,
                text: usesShortcut ? nil : key.text, modifiers: modifiers, commands: command.map { [$0] } ?? []
            )
        }
        guard base.count == 1, let character = base.first, character.isASCII else { return nil }
        if character.isLetter {
            let upper = String(character).uppercased()
            let key = shifted ? upper : lower
            var command: String?
            if macMeta {
                if lower == "z" && shifted { command = "redo" } else if !shifted { command = macEditing[lower] }
            }
            return BrowserKeyCombo(
                key: key, code: "Key\(upper)", virtualKey: Int(upper.unicodeScalars.first?.value ?? 0),
                text: usesShortcut ? nil : key, modifiers: modifiers, commands: command.map { [$0] } ?? []
            )
        }
        if ("0"..."9").contains(character) {
            return BrowserKeyCombo(
                key: String(character), code: "Digit\(character)", virtualKey: Int(character.asciiValue ?? 0),
                text: usesShortcut ? nil : String(character), modifiers: modifiers, commands: []
            )
        }
        return nil
    }
}

/// Parsing of OBU's replies (JSON text) and of the errors Chrome returns.
enum BrowserReply {
    static func json(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Every object that has an id and a url or title: a tab listing entry.
    static func tabIDs(in text: String) -> [Int] {
        var ids: [Int] = []
        walk(json(text)) { object in
            if let id = object["id"] as? Int, object["url"] != nil || object["title"] != nil { ids.append(id) }
        }
        return ids
    }

    /// The id of the tab that `open_tab` created ("tab": {"id": …}).
    static func openedTabID(in text: String) -> Int? {
        var found: Int?
        walk(json(text)) { object in
            if found == nil, let tab = object["tab"] as? [String: Any], let id = tab["id"] as? Int { found = id }
        }
        return found
    }

    /// "12 Title — https://…" lines for a tab listing.
    static func tabLines(in text: String, limit: Int) -> [String] {
        var lines: [String] = []
        walk(json(text)) { object in
            guard lines.count < limit, let id = object["id"] as? Int, let url = object["url"] as? String else { return }
            let title = (object["title"] as? String) ?? ""
            lines.append("\(id) \(title.isEmpty ? "" : title + " — ")\(url)")
        }
        return lines
    }

    /// The error text of a failed `Page.navigate`, if any.
    static func navigationError(in text: String) -> String? {
        guard let value = json(text) else { return nil }
        return BrowserPage.find("errorText", in: value) as? String
    }

    /// One short line that says what went wrong and what to do next.
    static func explain(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("no node with given id") || lower.contains("could not find node") || lower.contains("does not belong to the document") {
            return "that element is gone from the page; browser read again, then use the new number"
        }
        if lower.contains("cannot find context") || lower.contains("execution context was destroyed") || lower.contains("navigated") {
            return "the page changed while acting; browser read again"
        }
        if lower.contains("cannot access a chrome-extension") {
            return "another Chrome extension (a coupon finder or a password helper) has put its own panel into this page, and Chrome then blocks outside control of the tab. Tell the user: in Chrome, set that extension's Site access to \"On click\" (Extensions, Details). Then browser open the page again"
        }
        if lower.contains("no tab with") || lower.contains("tab not found") || lower.contains("no such tab") || lower.contains("tab was closed") {
            return "that tab is closed; browser tabs, then browser open the page again or use_tab with a tab_id from that list"
        }
        if lower.contains("debugger") || lower.contains("not attached") || lower.contains("not a session") || lower.contains("detached while handling") {
            return "lost the link to that tab; browser tabs, then browser use_tab with its tab_id"
        }
        if lower.contains("could not compute box model") || lower.contains("no box") {
            return "the element has no size on the page (hidden); read again or pick another control"
        }
        if lower.contains("not allowed") || lower.contains("denied") {
            return "Chrome refused that command on this page; use a click or key instead"
        }
        let line = BatchTool.firstLine(text, limit: 160)
        return line.isEmpty ? "Chrome did not accept the command; browser read, then try again" : line
    }

    private static func walk(_ value: Any?, depth: Int = 0, visit: ([String: Any]) -> Void) {
        guard depth < 6, let value else { return }
        if let object = value as? [String: Any] {
            visit(object)
            for child in object.values { walk(child, depth: depth + 1, visit: visit) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, depth: depth + 1, visit: visit) }
        }
    }
}

/// The document identity Chrome exposes for each frame in the tab's frame tree.
struct BrowserDocumentIdentity: Equatable {
    private let loadersByFrame: [String: String]

    init?(tree: [String: Any]) {
        var loaders: [String: String] = [:]

        func collect(_ tree: [String: Any]) -> Bool {
            guard let frame = tree["frame"] as? [String: Any],
                  let id = frame["id"] as? String, !id.isEmpty,
                  let loader = frame["loaderId"] as? String, !loader.isEmpty,
                  loaders[id] == nil else { return false }
            loaders[id] = loader
            guard let children = tree["childFrames"] else { return true }
            guard let frames = children as? [[String: Any]] else { return false }
            return frames.allSatisfy(collect)
        }

        guard collect(tree) else { return nil }
        loadersByFrame = loaders
    }
}

/// The numbered controls shown to this client, bound to one helper, tab and document.
final class BrowserPageMemory: @unchecked Sendable {
    static var shared: BrowserPageMemory { scoped.current }
    private static let scoped = ScopedStore<BrowserPageMemory>(make: { _ in BrowserPageMemory() })

    struct Observation {
        let nodes: [BrowserNode]
        let document: BrowserDocumentIdentity
        let generation: Int
        var keys: Set<String> { BrowserRules.controlKeys(nodes) }
    }

    private struct Tab: Hashable {
        let scope: UUID
        let id: Int
    }

    private let lock = NSLock()
    private var observations: [Tab: Observation] = [:]
    private var enabled: Set<String> = []

    func store(_ nodes: [BrowserNode], bridge: BrowserBridge, tab: Int, document: BrowserDocumentIdentity, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        observations[Tab(scope: bridge.referenceScope, id: tab)] = Observation(
            nodes: nodes, document: document, generation: generation
        )
    }

    func observation(bridge: BrowserBridge, tab: Int, document: BrowserDocumentIdentity) -> Observation? {
        let generation = bridge.referenceGeneration
        lock.lock()
        defer { lock.unlock() }
        guard let observation = observations[Tab(scope: bridge.referenceScope, id: tab)],
              observation.document == document, observation.generation == generation else { return nil }
        return observation
    }

    func isEnabled(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled.contains(key)
    }

    func markEnabled(_ key: String) {
        lock.lock(); enabled.insert(key); lock.unlock()
    }

    func forget(_ key: String) {
        lock.lock(); enabled.remove(key); lock.unlock()
    }

    func forgetTab(bridge: BrowserBridge, tab: Int) {
        let prefix = "\(bridge.referenceScope)|\(tab)|"
        lock.lock()
        defer { lock.unlock() }
        observations[Tab(scope: bridge.referenceScope, id: tab)] = nil
        enabled = enabled.filter { !$0.hasPrefix(prefix) }
    }
}


/// One browser tool call's whole time: no single step may hold the shared agent (and every other agent)
/// for minutes when Chrome is slow. Set at the start of each browser call.
enum BrowserCallBudget {
    static let limit: TimeInterval = 25
    private static let threadKey = "godspeed.browser-deadline"

    static func deadline(after seconds: TimeInterval = limit) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime + seconds
    }

    static func withDeadline<T>(_ deadline: TimeInterval, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[threadKey]
        dictionary[threadKey] = deadline
        defer {
            if let previous { dictionary[threadKey] = previous }
            else { dictionary.removeObject(forKey: threadKey) }
        }
        return try body()
    }

    static var activeRemaining: TimeInterval? {
        guard let deadline = Thread.current.threadDictionary[threadKey] as? TimeInterval else { return nil }
        return deadline - ProcessInfo.processInfo.systemUptime
    }

    static func remaining() -> TimeInterval {
        activeRemaining ?? limit
    }
}
