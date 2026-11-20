import CryptoKit
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
    var linkURL: String? = nil
    var observedStates: [String] = []
    /// What tells this control apart when it has no label or shares one: its title, icon, image, a stable
    /// attribute or its row ("icon:trash; in:Invoice 12"). Display only; not part of the fingerprint.
    var hint = ""

    /// The line a model reads: "3 textbox Email = sam@x.com"; "3*" when new since the last read.
    var line: String { renderedLine(numbered: true) }

    func renderedLine(numbered: Bool, includeLinkURL: Bool = true) -> String {
        let prefix = numbered ? "\(index)\(isNew ? "*" : "") " : ""
        let valuePart = value.isEmpty ? "" : " = \(value.prefix(80))"
        let statePart = observedStates.isEmpty ? "" : " [\(observedStates.joined(separator: ", "))]"
        let clipped = !name.dropFirst(100).isEmpty || !value.dropFirst(80).isEmpty
        let clippingNote = clipped ? " " + DoneCheck.clippedFieldNote : ""
        let destination = includeLinkURL ? (linkURL.map { " → " + String($0.prefix(240)) } ?? "") : ""
        let shownName = name.isEmpty ? (hint.isEmpty ? "(no label)" : "") : String(name.prefix(100))
        let hintPart = hint.isEmpty ? "" : (shownName.isEmpty ? "(\(hint))" : " (\(hint))")
        return "\(prefix)\(role) \(shownName)\(hintPart)\(statePart)\(clippingNote)\(valuePart)\(destination)"
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
    /// Icon-only controls kept so far (capped by `BrowserPage.maxUnnamedControls`).
    var unnamedControls = 0
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
    /// Most icon-only (unnamed) controls kept per page, and most controls given a hint per read.
    static let maxUnnamedControls = 40
    static let maxHintedControls = 24
    /// Time one read may spend asking Chrome for hints.
    static let hintBudget: TimeInterval = 0.35
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
        try readSnapshot(find: find, full: full).text
    }

    func readSnapshot(find: String?, full: Bool, interactive: Bool = false, diff: Bool = false,
                      includeLinkURLs: Bool = false, keepsDiffBaseline: Bool = true) throws
        -> (text: String, verifiedURL: String?, fullText: String?) {
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
                           textBudget: interactive ? 0 : (full ? BrowserPage.textBudget * 4 : BrowserPage.textBudget),
                           maxControls: full ? BrowserPage.maxElements * 2 : BrowserPage.maxElements,
                           includeLinkURLs: includeLinkURLs)
            : Self.parseAX(raw, controlBudget: .max, textBudget: interactive ? 0 : .max, maxControls: .max,
                           includeLinkURLs: includeLinkURLs)
        var parse = parsed
        addHints(to: &parse)
        let context = try? readContext(texts: parse.texts)
        let place = context?.location ?? (try? location())
        if let context { parse.texts = context.texts }
        var indicesAvailable = false
        var baseline: BrowserPageMemory.Observation?
        if remember, let tabID {
            let memory = BrowserPageMemory.shared
            if let identity, (try? documentIdentity()) == identity, generation == bridge.referenceGeneration {
                baseline = memory.observation(bridge: bridge, tab: tabID, document: identity)
                parse.controls = BrowserRules.markNew(parse.controls, previousKeys: baseline?.keys)
                parse.newControls = parse.controls.filter(\.isNew).count
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
        func render(includeLinkURLs: Bool) -> String {
            Self.renderRead(shown, href: place?.href ?? "?", title: place?.title ?? "",
                            readyState: place?.readyState ?? "complete", wholePage: query.isEmpty,
                            numbered: indicesAvailable, includeLinkURLs: includeLinkURLs)
        }
        var text = render(includeLinkURLs: includeLinkURLs)
        // Destination annotations describe a possible next page, not the text on this page.
        let evidence = includeLinkURLs ? render(includeLinkURLs: false) : nil
        if interactive {
            text += "\n(controls only; read without interactive for page text)"
        }
        if !query.isEmpty {
            text += shown.controls.isEmpty && shown.texts.isEmpty
                ? "\n(nothing on this page mentions \"\(query)\"; read without find, scroll, or try other words)"
                : "\n(only lines mentioning \"\(query)\"; use \(indicesAvailable ? "indexes or labels" : "labels") for actions)"
        }
        let url = indicesAvailable ? place?.href : nil
        if indicesAvailable, let tabID, let identity {
            let mode = keepsDiffBaseline && query.isEmpty && url != nil ? "\(full):\(interactive):\(includeLinkURLs)" : nil
            BrowserPageMemory.shared.store(parse.controls, bridge: bridge, tab: tabID, document: identity,
                                           generation: generation, text: mode == nil ? nil : text, mode: mode)
            if diff, let mode, let baseline, baseline.mode == mode, let previous = baseline.text,
               baseline.nodes.map(\.index) == parse.controls.map(\.index),
               baseline.nodes.map(\.backendNodeID) == parse.controls.map(\.backendNodeID),
               let change = AXStateDiff.diff(previous: previous, current: text, matchIndexes: true),
               let header = text.split(separator: "\n").first {
                let compact = "\(header)\nBrowser changes (read without diff for the full page):\n\(change)"
                if compact.utf8.count < text.utf8.count { return (compact, url, evidence ?? text) }
            }
        }
        return (text, url, evidence)
    }

    /// Labels the controls a model could not otherwise tell apart: those with no name and those that share
    /// their role and name with another (three "Edit" buttons). Unnamed ones first, then duplicates, in page
    /// order, within a small time budget, so a read never slows down noticeably.
    private func addHints(to parse: inout BrowserAXParse) {
        var counts: [String: Int] = [:]
        for control in parse.controls { counts["\(control.role)\u{1}\(control.name)", default: 0] += 1 }
        let candidates = parse.controls.indices.filter { position in
            let control = parse.controls[position]
            guard !control.inFrame, Self.clickableRoles.contains(control.role) || Self.fieldRoles.contains(control.role) else { return false }
            return control.name.isEmpty || counts["\(control.role)\u{1}\(control.name)", default: 0] > 1
        }
        guard !candidates.isEmpty else { return }
        let ordered = candidates.filter { parse.controls[$0].name.isEmpty } + candidates.filter { !parse.controls[$0].name.isEmpty }
        let deadline = Date().addingTimeInterval(Self.hintBudget)
        for position in ordered.prefix(Self.maxHintedControls) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.02 else { break }
            let control = parse.controls[position]
            let value = BrowserCallBudget.withDeadline(BrowserCallBudget.deadline(after: remaining)) {
                try? callOnNode(control, Self.hintJS) as? String
            }
            if let value, !value.isEmpty { parse.controls[position].hint = value }
        }
    }

    /// A control's title, icon, image, stable attribute and row, as "icon:trash; testid:delete; in:Invoice 12".
    /// After agent-browser's control hints (Apache-2.0), extended with title, tooltip and image alt text.
    static let hintJS = #"""
    function(){const tail=(s,sep)=>(s||'').split(sep).pop();
    const use=this.querySelector('svg use');const svg=this.querySelector('svg[id], svg[data-icon]');
    const mark=this.querySelector('svg[class], i[class], span[class*=icon]');
    const img=this.querySelector('img[src]:not([src^="data:"])');
    const icon=use?tail(use.getAttribute('href')||use.getAttribute('xlink:href'),'#'):svg?(svg.id||svg.dataset.icon):
    mark?String(mark.getAttribute('class')||'').split(/\s+/).filter((c)=>/^(lucide|fa|bi|mdi|ri|ti|icon|material)-/i.test(c)||/icon/i.test(c)).slice(0,2).join(' '):'';
    const file=img?tail(img.getAttribute('src').split(/[?#]/)[0],'/').replace(/\.\w+$/,''):'';
    const alt=img&&img.getAttribute('alt')||'';
    const title=this.getAttribute('title')||this.getAttribute('aria-description')||this.getAttribute('data-tooltip')||'';
    const key=['data-testid','data-test','name','id'].find((k)=>/^(?!.*\d{3})[a-z][\w-]*$/i.test(this.getAttribute(k)||''));
    const row=this.closest('tr, li, article, [role=row], [role=listitem], [role=gridcell]');
    const own=(this.innerText||'').trim();
    const near=row?String(row.innerText||'').replace(own,'').replace(/\s+/g,' ').trim():'';
    return [title&&'title:'+title,icon&&'icon:'+icon,alt&&'img:'+alt,!alt&&file&&'img:'+file,
    key&&key.replace(/^data-/,'')+':'+this.getAttribute(key),near&&'in:'+near]
    .filter(Boolean).map((s)=>s.replace(/\s+/g,' ').slice(0,48)).slice(0,3).join('; ');}
    """#

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

    /// Fetch page metadata and filter visible AX text in one evaluation. Reference validation still
    /// brackets the observation with separate frame-tree reads.
    private func readContext(texts: [String]) throws -> (location: BrowserLocation, texts: [String]) {
        if texts.isEmpty { return (try location(), []) }
        let probes = texts.map { String(Self.collapse(String($0.dropFirst(2))).lowercased().prefix(40)) }
        let data = try JSONSerialization.data(withJSONObject: probes)
        let json = String(decoding: data, as: UTF8.self)
        let raw = try evaluate("""
        (() => {
            const probes = \(json);
            let visible = null;
            try { if (probes.length) visible = (\(Self.visibleTextJS))(probes); } catch {}
            return [location.href, document.title, document.readyState, visible];
        })()
        """)
        guard let values = raw as? [Any], values.count == 4,
              let href = values[0] as? String, let title = values[1] as? String,
              let ready = values[2] as? String else {
            throw ComputerUseError.stateUnavailable("browser: page context unavailable")
        }
        let place = BrowserLocation(href: href, title: title, readyState: ready)
        let flags = (values[3] as? [Any])?.map { ($0 as? Bool) ?? true } ?? []
        return (place, Self.keepVisible(texts, flags: flags))
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

    func outline() throws -> String {
        let expression = """
        (() => {
            const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,[role="heading"]'));
            const rows = [];
            for (const node of headings) {
                if (!node.getClientRects().length || node.checkVisibility?.({checkVisibilityCSS:true}) === false) continue;
                const text = (node.innerText || node.getAttribute('aria-label') || '').trim().replace(/\\s+/g, ' ');
                if (!text) continue;
                const level = Number(node.getAttribute('aria-level') || node.tagName.slice(1)) || 2;
                rows.push([Math.max(1, Math.min(6, Math.trunc(level))), text.slice(0, 140)]);
                if (rows.length >= 50) break;
            }
            return rows;
        })()
        """
        guard let rows = try evaluate(expression) as? [[Any]] else {
            throw ComputerUseError.stateUnavailable("browser: the page outline could not be read")
        }
        let headings = rows.compactMap { row -> String? in
            guard row.count == 2, let level = row[0] as? Int, (1...6).contains(level),
                  let text = row[1] as? String else { return nil }
            return String(repeating: "#", count: level) + " " + text
        }
        return headings.isEmpty ? "No visible headings in the main document." : headings.joined(separator: "\n")
    }

    func frameSummary() throws -> String {
        guard let root = try cdp("Page.getFrameTree")["frameTree"] as? [String: Any] else {
            throw ComputerUseError.stateUnavailable("browser: could not read the tab's frame tree")
        }
        var pending: [(node: [String: Any], depth: Int)] = [(root, 0)]
        var lines: [String] = []
        while let entry = pending.popLast(), lines.count < 40 {
            if let frame = entry.node["frame"] as? [String: Any] {
                let address = (frame["url"] as? String).flatMap(BrowserRules.displayableLinkURL)
                let kind = entry.depth == 0 ? "Main document" : "Frame"
                lines.append(String(repeating: "  ", count: min(entry.depth, 8))
                    + kind + ": " + (address.map { String($0.prefix(200)) } ?? "(no web URL)"))
            }
            if let children = entry.node["childFrames"] as? [[String: Any]] {
                pending.append(contentsOf: children.reversed().map { ($0, entry.depth + 1) })
            }
        }
        if !pending.isEmpty { lines.append("(additional frames omitted)") }
        guard !lines.isEmpty else { throw ComputerUseError.stateUnavailable("browser: no frame information returned") }
        return lines.joined(separator: "\n")
    }

    func location() throws -> BrowserLocation {
        guardForeignFrames()
        let raw = try evaluate("[location.href, document.title, document.readyState]")
        let values = (raw as? [Any]) ?? []
        guard values.count == 3, let href = values[0] as? String, !href.isEmpty,
              let title = values[1] as? String, let ready = values[2] as? String else {
            throw ComputerUseError.stateUnavailable("browser: could not read the page address. Read the tab before continuing.")
        }
        return BrowserLocation(href: href, title: title, readyState: ready)
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
        maxControls: Int = BrowserPage.maxElements,
        includeLinkURLs: Bool = false
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
                // An icon-only control (trash, close, menu) has no name but is often the one a task needs. It is
                // kept, up to a cap, and labelled by a hint after the parse (see `addHints`).
                let unnamedClickable = name.isEmpty && clickableRoles.contains(role) && result.unnamedControls < maxUnnamedControls
                guard let backend = (node["backendDOMNodeId"] as? NSNumber)?.intValue,
                      !name.isEmpty || fieldRoles.contains(role) || unnamedClickable
                else { continue }
                if unnamedClickable { result.unnamedControls += 1 }
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
                var control = BrowserNode(
                    index: result.controls.count + 1, role: role, name: name, value: value,
                    backendNodeID: backend, inFrame: inFrame, parentControl: enclosing,
                    context: fieldRoles.contains(role) ? "" : BrowserRules.contextText(lastText, excluding: name)
                )
                if let properties = node["properties"] as? [[String: Any]] {
                    for property in properties {
                        guard let name = property["name"] as? String,
                              let value = (property["value"] as? [String: Any])?["value"] else { continue }
                        switch (name, value) {
                        case ("focused", let focused as Bool) where focused: control.observedStates.append("focused")
                        case ("disabled", let disabled as Bool) where disabled: control.observedStates.append("disabled")
                        case ("selected", let selected as Bool) where selected: control.observedStates.append("selected")
                        case ("expanded", let expanded as Bool): control.observedStates.append(expanded ? "expanded" : "collapsed")
                        case ("checked", let checked as Bool): control.observedStates.append(checked ? "checked" : "unchecked")
                        case ("checked", let state as String):
                            if state == "true" { control.observedStates.append("checked") }
                            if state == "false" { control.observedStates.append("unchecked") }
                            if state == "mixed" { control.observedStates.append("mixed") }
                        case ("url", let url as String) where includeLinkURLs && role == "link":
                            control.linkURL = BrowserRules.displayableLinkURL(url)
                        default: break
                        }
                    }
                }
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
    static func renderRead(_ parse: BrowserAXParse, href: String, title: String, readyState: String, wholePage: Bool = true, numbered: Bool = true, includeLinkURLs: Bool = true) -> String {
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
            lines += parse.controls.map { $0.renderedLine(numbered: numbered, includeLinkURL: includeLinkURLs) }
        }
        if parse.droppedControls > 0 {
            lines.append("(\(parse.droppedControls) more controls not listed: read with find: \"words\" to list the matching ones, or full: true; or act on them by label)")
        }
        if parse.newControls > 0 {
            lines.append("(* = new since your last read)")
        }
        if parse.framedControls > 0 {
            lines.append("(\(parse.framedControls) of these sit inside an iframe; act on them by \(numbered ? "label or index" : "label"))")
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
        // A hint from the last read ("icon:trash", "trash", "in:Invoice 12") names an icon-only control.
        if let tabID, let document = try? documentIdentity(),
           let observation = BrowserPageMemory.shared.observation(bridge: bridge, tab: tabID, document: document) {
            let matches = observation.nodes.filter { Self.hint($0.hint, matches: wanted) }
            if matches.count == 1, let node = matches.first {
                indexedGeneration = observation.generation
                return try verified(node, index: node.index)
            }
        }
        let raw = try fullTree()
        let nodes = Self.parseAX(raw, controlBudget: Int.max, textBudget: 0, maxControls: .max).controls
        if let hit = try Self.pickFuzzy(nodes, label: label) { return hit }
        let names = nodes.prefix(12).map { "\($0.role) \"\($0.name.prefix(40))\"" }.joined(separator: ", ")
        throw ComputerUseError.invalidArguments(
            "browser: no element labelled '\(label)'. Visible: \(names). Use the exact text, or browser read for indexes"
        )
    }

    /// True when `wanted` (normalized) is one of the hint's parts, with or without its "icon:" style prefix.
    static func hint(_ hint: String, matches wanted: String) -> Bool {
        guard !hint.isEmpty, !wanted.isEmpty else { return false }
        for part in hint.components(separatedBy: "; ") {
            let whole = normalize(part)
            if whole == wanted { return true }
            if let colon = part.firstIndex(of: ":"), normalize(String(part[part.index(after: colon)...])) == wanted { return true }
        }
        return false
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
    func resolveExact(label: String?, index: Int?) throws -> BrowserNode {
        if let index { return try resolve(label: nil, index: index) }
        guard let label, !Self.normalize(label).isEmpty else {
            throw ComputerUseError.invalidArguments("Give an exact label or a reference from browser read.")
        }
        let matches = try exactNamedControls(label)
        guard matches.count == 1, let node = matches.first else {
            throw ComputerUseError.stateUnavailable("Expected one control named '\(label)'. Found \(matches.count). Read the tab for a reference.")
        }
        return node
    }

    private func exactNamedControls(_ label: String) throws -> [BrowserNode] {
        let matches = try queryNamed(label).filter { Self.normalize($0.name) == Self.normalize(label) }
        var seen: Set<Int> = []
        return matches.filter { seen.insert($0.backendNodeID).inserted }
    }

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

    enum PointerButton: String {
        case left, right, middle

        var mask: Int {
            switch self {
            case .left: return 1
            case .right: return 2
            case .middle: return 4
            }
        }
    }

    func click(_ node: BrowserNode, button: PointerButton = .left, count: Int = 1, modifiers: Int = 0, placement: ClickPlacement? = nil) throws {
        guard (1...3).contains(count), button == .left || count == 1 else {
            throw ComputerUseError.invalidArguments("Multiple clicks need the left button and a count of 1 to 3.")
        }
        restoreSetup()
        let document = count > 1 ? try documentIdentity() : nil
        if count > 1, document == nil {
            throw ComputerUseError.stateUnavailable("browser: could not bind the double-click to the current document")
        }
        let firstPoint = try clickPoint(of: node, beforeFirstAction: true, placement: placement)
        // The press already carries the verified point. A separate mouse-move can stall a
        // background tab before the click is sent. Explicit hover still delivers movement.
        let remaining = BrowserCallBudget.remaining()
        guard remaining > 2 else { throw ComputerUseError.stateUnavailable("browser click did not send a press because little time remained") }
        let releaseDeadline = BrowserCallBudget.deadline(after: remaining)
        do {
            for beat in 1...count {
                var point = firstPoint
                if beat > 1 {
                    guard try documentIdentity() == document else {
                        throw ComputerUseError.stateUnavailable("browser: the first click changed the document")
                    }
                    point = try clickPoint(of: node, placement: placement)
                }
                guard BrowserCallBudget.remaining() > 2 else {
                    throw ComputerUseError.stateUnavailable("browser click ran out of time before the next press")
                }
                do {
                    try BrowserCallBudget.withDeadline(releaseDeadline - 1.5) {
                        try mouse("mousePressed", point, buttons: button.mask, clickCount: beat, button: button, modifiers: modifiers)
                    }
                } catch {
                    // A missing press reply may still have left the button held. Release once
                    // within the reserved time. A release with an uncertain result is never replayed.
                    try? BrowserCallBudget.withDeadline(releaseDeadline) {
                        try mouse("mouseReleased", point, buttons: 0, clickCount: beat, button: button, modifiers: modifiers)
                    }
                    throw error
                }
                try mouse("mouseReleased", point, buttons: 0, clickCount: beat, button: button, modifiers: modifiers)
            }
        } catch {
            throw ComputerUseError.stateUnavailable("browser: the click may have taken effect. Inspect the tab before retrying.")
        }
    }

    func hover(_ node: BrowserNode) throws {
        restoreSetup()
        reveal(node)
        try mouse("mouseMoved", try clickPoint(of: node), buttons: 0, clickCount: 0)
    }

    /// A pointer gesture within one viewport, using live hit testing at both ends.
    func drag(from source: BrowserNode, to destination: BrowserNode, modifiers: Int = 0) throws {
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
        try Self.deliverDrag(from: start, to: end) { type, point, buttons, count in
            try self.mouse(type, point, buttons: buttons, clickCount: count, modifiers: modifiers)
        }
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

    private func precisePoint(of node: BrowserNode, placement: ClickPlacement) throws -> CGPoint {
        let result = try callOnNode(node, """
        function(fx,fy,dx,dy){
          if(window!==window.top)return ['frame'];
          if(!this.isConnected)return [];
          const r=this.getBoundingClientRect(), ix=Math.min(1,r.width/2), iy=Math.min(1,r.height/2);
          const x=r.left+ix+(r.width-2*ix)*fx+dx, y=r.top+iy+(r.height-2*iy)*fy+dy;
          if(x<r.left||x>=r.right||y<r.top||y>=r.bottom)return ['offset'];
          let hit=document.elementFromPoint(x,y);
          for(let next;hit&&hit.shadowRoot&&(next=hit.shadowRoot.elementFromPoint(x,y))&&next!==hit;)hit=next;
          for(let n=hit;n;n=n.parentNode||n.host){
            if(n===this){
              if(window.__gs){__gs.seen=__gs.mut;__gs.href=location.href;__gs.nav=false;}
              return ['ok',x,y];
            }
          }
          return [];
        }
        """, arguments: [placement.fraction.x, placement.fraction.y, placement.offset.x, placement.offset.y]) as? [Any]
        if result?.first as? String == "frame" {
            throw ComputerUseError.backgroundUnsupported("Precise hit testing is unavailable inside this frame.")
        }
        if result?.first as? String == "offset" {
            throw ComputerUseError.invalidArguments("Click offsets place the point outside the control.")
        }
        guard let result, result.count == 3, result[0] as? String == "ok",
              let x = BrowserRules.number(result[1]), let y = BrowserRules.number(result[2]) else {
            throw ComputerUseError.stateUnavailable("The precise point is out of view or covered. Reveal the control before continuing.")
        }
        return CGPoint(x: x, y: y)
    }

    /// Where on the element to click: a point of its visible part that really reaches it (`elementFromPoint`
    /// hit-test). Says so when something else lies on top of every probed point (a banner, a dialog, a
    /// stretched link). For frames, use the browser's box geometry. In the main document
    /// a missing hit test is a refusal, since an unverified box could target another control.
    private func clickPoint(of node: BrowserNode, beforeFirstAction: Bool = false, placement: ClickPlacement? = nil) throws -> CGPoint {
        if let placement {
            return try precisePoint(of: node, placement: placement)
        }
        func probe() -> [Any] {
            let remaining = BrowserCallBudget.remaining()
            // Resolving the node and hit-testing it are separate Chrome calls.
            // Reserve time for the press and release after the probe.
            // With little time left, probe briefly instead of refusing a click that would still fit.
            guard remaining > 1.5 else { return [] }
            let reserve = remaining > 4 ? 3 : 0.8
            let deadline = BrowserCallBudget.deadline(after: min(8, remaining - reserve))
            return BrowserCallBudget.withDeadline(deadline) {
                ((try? callOnNode(node, Self.clickProbeJS)) as? [Any]) ?? []
            }
        }
        var found = probe()
        if found.isEmpty { found = probe() }
        let delivery = beforeFirstAction ? " Nothing was sent." : ""
        if let kind = found.first as? String, kind == "off" || kind == "covered" {
            // Often a sticky header: centre the element and look again.
            _ = try? callOnNode(node, "function(){this.scrollIntoView({block:'center',inline:'center',behavior:'instant'});}")
            found = probe()
        }
        let kind = found.first as? String
        if kind == "ok" || kind == "covered", found.count >= 3,
           let x = BrowserRules.number(found[1]), let y = BrowserRules.number(found[2]) {
            if kind == "covered" {
                let what = found.count > 3 ? "\(found[3])".trimmingCharacters(in: .whitespacesAndNewlines) : ""
                throw ComputerUseError.message(BrowserRules.coveredMessage(role: node.role, name: node.name, by: what) + delivery)
            }
            return CGPoint(x: x, y: y)
        }
        if kind == "frame" {
            reveal(node)
            return try center(of: node)
        }
        throw ComputerUseError.stateUnavailable("browser: could not confirm an unobstructed click point.\(delivery) Reveal the control and read the tab again.")
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
    if(!t)continue;\
    if(inside(this,t)||inside(t,this)||lab.some((l)=>inside(l,t)))return ['ok',x,y];\
    if(!first)first=[x,y,t];}\
    if(!first)return ['off'];\
    const t=first[2];const lbl=t.closest&&t.closest('label');\
    if(lbl&&lbl.control&&inside(this,lbl.control))return ['ok',first[0],first[1]];\
    return ['covered',first[0],first[1],String(t.getAttribute&&t.getAttribute('aria-label')||t.innerText||t.tagName||'').replace(/\\s+/g,' ').slice(0,60)];}
    """

    func scrollIntoView(_ node: BrowserNode) throws {
        _ = try cdp("DOM.scrollIntoViewIfNeeded", ["backendNodeId": node.backendNodeID], feedback: "scroll")
    }

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

    private func mouse(_ type: String, _ point: CGPoint, buttons: Int, clickCount: Int,
                       button: PointerButton = .left, modifiers: Int = 0) throws {
        _ = try cdp("Input.dispatchMouseEvent", [
            "type": type, "x": point.x, "y": point.y,
            "button": type == "mouseMoved" ? "none" : button.rawValue,
            "buttons": buttons, "clickCount": clickCount, "modifiers": modifiers,
        ])
    }

    // MARK: Act: keyboard and text

    /// Types into the focused field, or into `node` after focusing it. `replace` selects the old value first, so
    /// the text replaces it; empty text with `replace` clears the field. All but the last character go in as
    /// one insertion; the last is sent as a real key event, so the page's key handlers (autocomplete) fire.
    /// A native <select> takes the text as the option to pick. Reports what the page did afterwards: a change
    /// line, "(field now shows ...)" when the field does not read back as typed, and the visible options of a
    /// combobox.
    func type(_ text: String, replace: Bool, into node: BrowserNode?, keyEvents: Bool = true) throws -> BrowserTypeOutcome {
        restoreSetup()
        if let node, ["combobox", "listbox"].contains(node.role),
           (try? callOnNode(node, "function(){return this.tagName==='SELECT';}")) as? Bool == true {
            return BrowserTypeOutcome(picked: try select(node, option: text))
        }
        let watchSuggestions = keyEvents || node == nil || node?.role == "combobox"
        if watchSuggestions { markBaseline() }
        if let node {
            _ = try cdp("DOM.focus", ["backendNodeId": node.backendNodeID])
            guard (try? callOnNode(node, Self.prepareFocusedFieldJS, arguments: [replace])) as? Bool == true else {
                throw ComputerUseError.stateUnavailable("browser: the requested field is not focused and editable, or its text could not be selected. No text was sent.")
            }
        } else {
            let prepared = try? evaluate("""
            (() => {
                let element = document.activeElement;
                while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement;
                return !!element && (\(Self.prepareFocusedFieldJS)).call(element, \(replace));
            })()
            """)
            guard prepared as? Bool == true else {
                throw ComputerUseError.stateUnavailable("browser: no confirmed editable field has focus. Name the field explicitly. No text was sent.")
            }
        }
        let (head, last) = keyEvents ? BrowserRules.splitForTyping(text) : (text, nil)
        let document = !keyEvents && node != nil ? try? documentIdentity() : nil
        var expected = replace ? text : nil
        if !keyEvents, !replace, let node, document != nil {
            expected = (try? callOnNode(node, """
                function (text) {
                  if (!this.matches('input,textarea') || this.type === 'password' ||
                      !Number.isInteger(this.selectionStart) || !Number.isInteger(this.selectionEnd)) return null;
                  return this.value.slice(0,this.selectionStart) + text + this.value.slice(this.selectionEnd);
                }
                """, arguments: [text])) as? String
        }
        do {
            if !head.isEmpty { _ = try cdp("Input.insertText", ["text": head]) }
            if let last { try sendTypedCharacter(last) }
            if replace, text.isEmpty { try pressKey("Backspace") }
        } catch {
            // Chrome can apply an insertion and then time out replying. The exact requested
            // replacement in the same document proves the final field state without resending.
            if let node, let document, let expected, BrowserCallBudget.remaining() > 0.6,
               (try? documentIdentity()) == document,
               (try? fieldText(node)) == expected {
                return BrowserTypeOutcome(note: "field value verified after Chrome did not acknowledge the input")
            }
            throw ComputerUseError.stateUnavailable("browser: typing may have taken effect in part. Read the field before sending any more text.")
        }
        var outcome = BrowserTypeOutcome()
        if watchSuggestions { outcome.change = settle() }

        // A form can rerender and replace its field after accepting the text. A failed
        // read-back in that case cannot tell us that the text needs to be sent again.
        let actual: String?
        do {
            if let node {
                actual = try fieldText(node)
            } else {
                actual = try activeFieldText()
            }
        } catch {
            throw ComputerUseError.stateUnavailable("browser: typing may have taken effect, but the field could not be read back. Read the page before retrying.")
        }
        if let actual, !BrowserRules.fieldMatches(actual: actual, typed: text, replaced: replace) {
            if !keyEvents, replace {
                throw ComputerUseError.stateUnavailable("browser: typing may have taken effect, but the field does not show the requested value. Read it before continuing.")
            }
            outcome.note = "(field now shows \"\(actual.prefix(80))\"; inspect the field before sending more text)"
        }
        if watchSuggestions { outcome.options = comboOptions() }
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

    /// Verify and select within the target's own document or shadow root.
    func copySelectionToPrivateClipboard(cut: Bool) throws {
        let focus = """
        (() => {
          let field = document.activeElement;
          while (field?.shadowRoot?.activeElement) field = field.shadowRoot.activeElement;
          return field;
        })()
        """
        let clipboard = PrivateClipboard.current
        if !cut {
            let text = try evaluate("""
                (() => {
                  const field = \(focus);
                  if (field?.matches('iframe, frame, input[type=password]')) return null;
                  if (Number.isInteger(field?.selectionStart) && Number.isInteger(field?.selectionEnd))
                    return field.value.slice(field.selectionStart, field.selectionEnd);
                  return window.getSelection()?.toString();
                })()
                """) as? String
            guard let text, !text.isEmpty else {
                throw ComputerUseError.invalidArguments("No readable text is selected in the main Chrome document.")
            }
            try clipboard.writeText(text)
            return
        }
        let focused = try cdp("Runtime.evaluate", ["expression": focus, "returnByValue": false])
        guard let object = (focused["result"] as? [String: Any])?["objectId"] as? String else {
            throw ComputerUseError.invalidArguments("Select text in an editable Chrome field first.")
        }
        defer { _ = try? cdp("Runtime.releaseObject", ["objectId": object]) }
        let read = try cdp("Runtime.callFunctionOn", [
            "objectId": object, "returnByValue": true,
            "functionDeclaration": """
                function () {
                  if (!this.matches('input:not([type=password]),textarea') || this.matches(':disabled') || this.readOnly ||
                      !Number.isInteger(this.selectionStart) || this.selectionEnd <= this.selectionStart) return null;
                  return [this.value.slice(this.selectionStart, this.selectionEnd), this.selectionStart, this.selectionEnd];
                }
                """
        ])
        guard let values = (read["result"] as? [String: Any])?["value"] as? [Any], values.count == 3,
              let text = values[0] as? String, !text.isEmpty else {
            throw ComputerUseError.invalidArguments("Select text in an editable Chrome text field first.")
        }
        try clipboard.writeText(text)
        let result = try cdp("Runtime.callFunctionOn", [
            "objectId": object, "returnByValue": true,
            "arguments": values.map { ["value": $0] },
            "functionDeclaration": """
                function (text, start, end) {
                  let field = document.activeElement;
                  while (field?.shadowRoot?.activeElement) field = field.shadowRoot.activeElement;
                  if (field !== this || !this.isConnected || this.type === 'password' || this.readOnly || this.matches(':disabled') ||
                      this.selectionStart !== start || this.selectionEnd !== end || this.value.slice(start,end) !== text) return false;
                  const expected = this.value.slice(0,start) + this.value.slice(end);
                  document.execCommand('delete');
                  return this.isConnected && this.value === expected;
                }
                """
        ])
        guard (result["result"] as? [String: Any])?["value"] as? Bool == true else {
            throw ComputerUseError.stateUnavailable("The private clipboard has the text, but deletion could not be verified. Check the field before retrying.")
        }
    }

    private static let prepareFocusedFieldJS = """
    function(replace) {
        const root = this.getRootNode();
        const focused = () => {
            let element = this;
            let scope = root;
            while (scope && scope.activeElement === element) {
                if (!scope.host) return true;
                element = scope.host;
                scope = element.getRootNode();
            }
            return false;
        };
        if (!focused() || this.disabled || this.readOnly) return false;
        const field = this.tagName === 'TEXTAREA' || (this.tagName === 'INPUT' &&
            !['button','checkbox','color','file','hidden','image','radio','range','reset','submit'].includes(this.type));
        if (!field && !this.isContentEditable) return false;
        if (replace) {
            if (field) {
                this.select();
            } else {
                const range = this.ownerDocument.createRange();
                range.selectNodeContents(this);
                const selection = this.ownerDocument.getSelection();
                if (!selection) return false;
                selection.removeAllRanges();
                selection.addRange(range);
            }
        }
        return focused();
    }
    """

    private func activeFieldText() throws -> String? {
        try evaluate("(function(){let el=document.activeElement;while(el&&el.shadowRoot&&el.shadowRoot.activeElement)el=el.shadowRoot.activeElement;if(!el)return null;"
            + "if(el.type==='password')return null;"
            + "if(el.tagName==='INPUT'||el.tagName==='TEXTAREA')return String(el.value);"
            + "if(el.isContentEditable)return el.innerText;return null;})()") as? String
    }

    func readTargetText(label: String?, index: Int?) throws -> String {
        let node: BrowserNode
        if let index {
            node = try resolve(label: nil, index: index)
        } else if let label, !label.isEmpty {
            let matches = try queryNamedRaw(label).compactMap { item -> BrowserNode? in
                guard (item["ignored"] as? Bool) != true,
                      let role = Self.axValue(item["role"]), role != "StaticText",
                      let name = Self.axValue(item["name"]), Self.normalize(name) == Self.normalize(label),
                      let backend = (item["backendDOMNodeId"] as? NSNumber)?.intValue else { return nil }
                return BrowserNode(index: 0, role: role, name: name, value: "", backendNodeID: backend)
            }
            guard Set(matches.map(\.backendNodeID)).count == 1, let match = matches.first else {
                throw ComputerUseError.stateUnavailable("browser: the text target was missing or ambiguous. Use browser read with find to inspect the page.")
            }
            node = match
        } else {
            throw ComputerUseError.invalidArguments("browser read_text needs a label or a current index.")
        }
        let script = """
        function() {
            if (!this.isConnected || !this.getClientRects().length ||
                this.checkVisibility?.({checkOpacity:true, checkVisibilityCSS:true}) === false ||
                typeof this.innerText !== 'string') return null;
            return this.innerText.trim().slice(0, 2000);
        }
        """
        guard let text = try callOnNode(node, script) as? String else {
            throw ComputerUseError.stateUnavailable("browser: this target did not expose rendered text.")
        }
        return text
    }

    func setFiles(_ files: [String], on node: BrowserNode) throws {
        let paths = try files.map { path -> String in
            let path = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
                throw ComputerUseError.invalidArguments("browser upload needs readable absolute file paths")
            }
            return path
        }
        let expected = try paths.map { path -> UploadFile in
            let url = URL(fileURLWithPath: path)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw ComputerUseError.invalidArguments("Could not inspect a file before uploading. Nothing was sent.")
            }
            return UploadFile(name: url.lastPathComponent, size: size)
        }
        let preflight = "function(){return this.isConnected&&this.tagName==='INPUT'&&this.type==='file'&&!this.matches(':disabled')&&!this.closest('[aria-disabled=true],[inert]')?this.multiple:null;}"
        func readCapacity() -> Result<Any?, Error> {
            let deadline = BrowserCallBudget.deadline(after: min(3, BrowserCallBudget.remaining()))
            return Result { try BrowserCallBudget.withDeadline(deadline) { try callOnNode(node, preflight) } }
        }
        var capacity = readCapacity()
        if case .failure = capacity, BrowserCallBudget.remaining() > 3 { capacity = readCapacity() }
        guard case .success(let value) = capacity else {
            throw ComputerUseError.stateUnavailable("Could not confirm the Chrome file input. Nothing was sent. Read the tab and try again.")
        }
        guard let multiple = value as? Bool else {
            throw ComputerUseError.invalidArguments("Browser upload target is not an enabled file input. Nothing was sent.")
        }
        guard multiple || paths.count == 1 else {
            throw ComputerUseError.invalidArguments("This file input accepts only one file. Nothing was sent.")
        }
        do {
            _ = try cdp("DOM.setFileInputFiles", ["files": paths, "backendNodeId": node.backendNodeID])
            let selected = try callOnNode(node, """
                function() {
                  return this.isConnected && this.type === 'file'
                    ? Array.from(this.files, file => [file.name, file.size]) : null;
                }
                """)
            guard Self.matchesUploadSelection(selected, expected: expected) else {
                throw ComputerUseError.stateUnavailable("Selected file names and sizes could not be verified.")
            }
        } catch {
            throw ComputerUseError.stateUnavailable("browser: the file selection may have taken effect. Check the upload control before retrying.")
        }
    }

    struct UploadFile: Equatable {
        let name: String
        let size: Int
    }

    static func matchesUploadSelection(_ value: Any?, expected: [UploadFile]) -> Bool {
        guard let rows = value as? [[Any]], rows.count == expected.count else { return false }
        return zip(rows, expected).allSatisfy { row, file in
            row.count == 2 && row[0] as? String == file.name && row[1] as? Int == file.size
        }
    }

    func fieldText(_ node: BrowserNode) throws -> String? {
        try callOnNode(node, "function(){if(this.type==='password')return null;if(this.tagName==='INPUT'||this.tagName==='TEXTAREA')return String(this.value);"
            + "if(this.isContentEditable)return this.innerText;return null;}") as? String
    }

    // MARK: Act: controls

    /// Ticks or unticks a checkbox, radio or switch. Reads the state first, clicks only when it must change, and
    /// reads it back afterwards.
    func setChecked(_ node: BrowserNode, desired: Bool) throws -> String {
        let word = desired ? "checked" : "unchecked"
        let state = try checkedState(node)
        if state == "unknown" {
            throw ComputerUseError.invalidArguments("browser: \(node.role) \"\(node.name)\" does not report checked or unchecked; click it instead")
        }
        let expected = desired ? "true" : "false"
        if state == expected { return "\"\(node.name)\" was already \(word)" }
        if !desired && node.role == "radio" {
            throw ComputerUseError.invalidArguments("browser: a radio button cannot be unchecked; choose another option instead")
        }
        try click(node)
        guard let after = try? checkedState(node), after == expected else {
            throw ComputerUseError.stateUnavailable("browser: the click may have taken effect, but the requested checked state was not confirmed. Read the control before retrying.")
        }
        return "\(node.role) \"\(node.name)\" is now \(word)"
    }

    enum ControlCondition: String {
        case visible, enabled, checked, unchecked
    }

    func controlState(_ node: BrowserNode) throws -> String {
        let state = try inspectControl(node)
        var fields = ["Visible: \(state.visible)", "Enabled: \(state.enabled)"]
        if let checked = state.checked { fields.append("Checked: \(checked)") }
        return fields.joined(separator: "\n")
    }

    private func inspectControl(_ node: BrowserNode) throws -> (visible: Bool, enabled: Bool, checked: String?) {
        let inspection = """
        function() {
            if (!this.isConnected) return null;
            const style = this.ownerDocument.defaultView.getComputedStyle(this);
            const visible = this.getClientRects().length > 0 &&
                (this.checkVisibility?.({checkOpacity:true, checkVisibilityCSS:true}) ??
                 (style.visibility !== 'hidden' && style.visibility !== 'collapse' && style.opacity !== '0'));
            const enabled = !this.matches(':disabled') &&
                !this.closest('[aria-disabled="true"], [inert]');
            const input = this.matches('input[type=checkbox], input[type=radio]') ? this :
                this.querySelector('input[type=checkbox], input[type=radio]');
            const aria = this.getAttribute('aria-checked');
            const checked = input ? (input.indeterminate ? 'mixed' : String(input.checked)) :
                (['true','false','mixed'].includes(aria) ? aria : null);
            return {visible, enabled, checked};
        }
        """
        guard let state = try callOnNode(node, inspection) as? [String: Any],
              let visible = state["visible"] as? Bool, let enabled = state["enabled"] as? Bool else {
            throw ComputerUseError.stateUnavailable("browser: the control state could not be read. Refresh the tab before acting.")
        }
        return (visible, enabled, state["checked"] as? String)
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
            guard Set(entries.map(\.backendNodeID)).count == 1, let choice = entries.first else {
                throw ComputerUseError.stateUnavailable("browser: the menu opened, but the option is missing or ambiguous. Read the menu before continuing.")
            }
            try click(choice)
            let change = settle()
            return "clicked option \"\(choice.name)\" in \"\(node.name)\"; \(change.line); confirm the selected value before retrying"
        }
        switch BrowserRules.matchOption(option, options: rows) {
        case .found(let position):
            markBaseline()
            let expected = rows[position]
            let result = try callOnNode(node, "function(i,text,value){const option=this.options?.[i];"
                + "if(!option||!this.isConnected||option.text!==text||option.value!==value)return null;"
                + "if(option.selected&&this.selectedOptions.length===1)return {changed:false,text:option.text};"
                + "if(option.disabled||this.disabled||option.closest('optgroup')?.disabled)return null;"
                + "this.selectedIndex=i;"
                + "this.dispatchEvent(new Event('input',{bubbles:true}));"
                + "this.dispatchEvent(new Event('change',{bubbles:true}));"
                + "return this.isConnected&&this.options[this.selectedIndex]===option?{changed:true,text:option.text}:null;}",
                arguments: [position, expected.text, expected.value]) as? [String: Any]
            guard let chosen = result?["text"] as? String, let changed = result?["changed"] as? Bool else {
                throw ComputerUseError.stateUnavailable("browser: the option may have taken effect, but its selected state could not be confirmed. Read the control before retrying.")
            }
            if !changed { return "\"\(chosen)\" was already selected in \"\(node.name)\"" }
            let change = settle()
            return "chose \"\(chosen)\" in \"\(node.name)\"; \(change.line)"
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
            + "return [window.scrollY,Math.max(0,e.scrollHeight-window.innerHeight)];})('\(direction)',\(pixels))", feedback: "scroll")
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
            + "return [el.scrollTop,el.scrollHeight-el.clientHeight];}", arguments: [direction, Swift.max(0, amount ?? 0)], feedback: "scroll")
        guard let values = raw as? [Any], values.count == 2, let top = BrowserRules.number(values[0]),
              let bottom = BrowserRules.number(values[1])
        else {
            throw ComputerUseError.invalidArguments("browser: \"\(node.name)\" does not scroll; leave out the label to scroll the page")
        }
        return "\"\(node.name)\": " + BrowserRules.scrollSummary(direction: direction, top: top, bottom: bottom)
    }

    func scroll(_ node: BrowserNode?, direction: String, chunks: ScrollChunks) throws -> String {
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw ComputerUseError.invalidArguments("Scroll chunks need up, down, left or right.")
        }
        guard let document = try documentIdentity() else {
            throw ComputerUseError.stateUnavailable("Could not bind the scroll to this document.")
        }
        func validate() throws {
            guard try documentIdentity() == document else {
                throw ComputerUseError.stateUnavailable("The document changed during scroll. Read the tab before continuing.")
            }
        }
        let outcome = try chunks.run(visible: {
            try validate()
            guard let label = chunks.untilVisible else { return false }
            let matches = try queryNamed(label).filter { Self.normalize($0.name) == Self.normalize(label) }
            let unique = Dictionary(grouping: matches, by: \.backendNodeID)
            guard unique.count == 1, let match = matches.first else { return false }
            return try isInViewport(match)
        }, advance: {
            try validate()
            let args: [Any] = [direction, chunks.unit.rawValue, chunks.size]
            let result: Any?
            if let node {
                result = try callOnNode(node, Self.scrollChunkJS, arguments: args, feedback: "scroll")
            } else {
                result = try evaluate("(\(Self.scrollChunkJS)).call(document.scrollingElement,"
                    + "\(BrowserRules.jsLiteral(direction)),\(BrowserRules.jsLiteral(chunks.unit.rawValue)),\(chunks.size))",
                    feedback: "scroll")
            }
            guard let moved = result as? Bool else {
                throw ComputerUseError.backgroundUnsupported("Choose the page or a scrollable control in its current document.")
            }
            return moved
        })
        return try outcome.reply(label: chunks.untilVisible)
    }

    private static let scrollChunkJS = """
    function(direction,unit,count) {
        if (!this?.isConnected) return null;
        const horizontal = direction === 'left' || direction === 'right';
        const canScroll = e => {
            if (e === document.scrollingElement) return true;
            const overflow = getComputedStyle(e)[horizontal ? 'overflowX' : 'overflowY'];
            return /^(auto|scroll|overlay)$/.test(overflow) &&
                (horizontal ? e.scrollWidth > e.clientWidth : e.scrollHeight > e.clientHeight);
        };
        let area = this;
        while (area && !canScroll(area)) area = area.parentElement;
        if (!area) return null;
        const property = horizontal ? 'scrollLeft' : 'scrollTop';
        const before = area[property];
        const size = unit === 'pages' ? (horizontal ? area.clientWidth : area.clientHeight)
            : unit === 'lines' ? count * 40 : count;
        const delta = direction === 'left' || direction === 'up' ? -size : size;
        area.scrollBy({left:horizontal ? delta : 0,top:horizontal ? 0 : delta,behavior:'instant'});
        return area[property] !== before;
    }
    """

    private func isInViewport(_ node: BrowserNode) throws -> Bool {
        guard let result = try callOnNode(node, Self.clickProbeJS) as? [Any] else { return false }
        return (result.first as? String) == "ok"
    }

    /// Back, forward or reload in this tab, waiting for the page to load again.
    func history(_ operation: String) throws -> String {
        if operation == "reload" {
            guard let before = try evaluate("performance.timeOrigin") as? NSNumber else {
                throw ComputerUseError.stateUnavailable("browser: could not identify the current document before reloading.")
            }
            _ = try cdp("Page.reload", ["ignoreCache": false])
            let place = try waitForHistoryResult {
                guard let origin = try self.evaluate("performance.timeOrigin") as? NSNumber else { return false }
                return origin != before
            }
            settle()
            return "reloaded \(title(place))"
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
        _ = try cdp("Page.navigateToHistoryEntry", ["entryId": entryID])
        let place = try waitForHistoryResult {
            let history = try self.cdp("Page.getNavigationHistory")
            guard let entries = history["entries"] as? [[String: Any]],
                  let index = (history["currentIndex"] as? NSNumber)?.intValue,
                  entries.indices.contains(index) else { return false }
            return (entries[index]["id"] as? NSNumber)?.intValue == entryID
        }
        settle()
        return "went \(operation) to \(title(place))"
    }

    private func waitForHistoryResult(_ reachedTarget: () throws -> Bool) throws -> BrowserLocation {
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + min(20, max(0, BrowserCallBudget.remaining()))
        let observed: BrowserLocation? = try BrowserCallBudget.withDeadline(deadline) {
            while deadline - clock.systemUptime > 0.3 {
                try BrowserRequestContext.validateCurrent()
                if (try? reachedTarget()) == true, let place = try? location(),
                   place.readyState == "interactive" || place.readyState == "complete" {
                    return place
                }
                let remaining = deadline - clock.systemUptime - 0.3
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(0.12, remaining))
            }
            return nil
        }
        guard let observed else {
            throw ComputerUseError.stateUnavailable("browser: navigation was sent, but the new history state could not be confirmed. Read the tab before retrying.")
        }
        return observed
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
        let clock = ProcessInfo.processInfo
        let start = clock.systemUptime
        let deadline = start + min(timeout, max(0, BrowserCallBudget.remaining() - 1))
        return BrowserCallBudget.withDeadline(deadline) {
            while deadline - clock.systemUptime > 0.3 {
                do { try BrowserRequestContext.validateCurrent() } catch { return false }
                if let here = try? location(),
                   here.readyState == "interactive" || here.readyState == "complete" {
                    let elapsed = clock.systemUptime - start
                    if let expect {
                        if BrowserRules.sameAddress(here.href, expect)
                            || (elapsed > 4 && here.href != old && BrowserRules.isWebAddress(here.href)) { return true }
                    } else if old == nil || here.href != old || elapsed > 1.5 {
                        return true
                    }
                }
                let remaining = deadline - clock.systemUptime - 0.3
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(0.12, remaining))
            }
            return false
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
        let clock = ProcessInfo.processInfo
        let quietLimit = Double(cap) / 1000
        let start = clock.systemUptime
        // A delayed observation cannot use the full input-command timeout.
        let deadline = start + min(quietLimit + 1, max(0, BrowserCallBudget.remaining()))
        let last: [String: Any]? = BrowserCallBudget.withDeadline(deadline) {
            var observed: [String: Any]?
            while deadline - clock.systemUptime > 0.3 {
                let payload = try? cdp("Runtime.evaluate", ["returnByValue": true, "expression": Self.settleProbeJS])
                guard let value = (payload?["result"] as? [String: Any])?["value"] as? [String: Any],
                      (value["ok"] as? Bool) == true else { break }
                observed = value
                if (value["quiet"] as? Bool) == true || clock.systemUptime - start >= quietLimit { break }
                Thread.sleep(forTimeInterval: 0.04)
            }
            return observed
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
    func waitFor(text: String?, label: String?, urlContains: String? = nil, controlCondition: ControlCondition? = nil, timeout: TimeInterval) -> Bool {
        let clock = ProcessInfo.processInfo
        let deadline = clock.systemUptime + min(timeout, max(0, BrowserCallBudget.remaining()))
        return BrowserCallBudget.withDeadline(deadline) {
            while clock.systemUptime < deadline {
                do { try BrowserRequestContext.validateCurrent() } catch { return false }
                if let urlContains {
                    if let place = try? location(),
                       place.readyState == "interactive" || place.readyState == "complete",
                       place.href.localizedCaseInsensitiveContains(urlContains) { return true }
                } else if let text {
                    let remaining = deadline - clock.systemUptime
                    let milliseconds = Int(min(1.0, max(0, remaining - 0.05)) * 1000)
                    let expression = Self.textWaitExpression(text, milliseconds: milliseconds)
                    if let payload = try? cdp("Runtime.evaluate", [
                        "expression": expression, "awaitPromise": true, "returnByValue": true,
                    ]), let matched = (payload["result"] as? [String: Any])?["value"] as? Bool {
                        if matched { return true }
                        if milliseconds > 0 { continue }
                    }
                    // Older helpers may not await a promise. Navigation can also interrupt the observer.
                    if (try? evaluate("!!(document.body&&document.body.innerText.includes(\(BrowserRules.jsLiteral(text))))")) as? Bool == true {
                        return true
                    }
                } else if let label {
                    if let controlCondition {
                        let matches = ((try? queryNamed(label)) ?? []).filter { Self.normalize($0.name) == Self.normalize(label) }
                        if Set(matches.map(\.backendNodeID)).count == 1, let node = matches.first,
                           let state = try? inspectControl(node) {
                            switch controlCondition {
                            case .visible: if state.visible { return true }
                            case .enabled: if state.enabled { return true }
                            case .checked: if state.checked == "true" { return true }
                            case .unchecked: if state.checked == "false" { return true }
                            }
                        }
                    } else if let named = try? queryNamedAny(label), !named.isEmpty {
                        return true
                    }
                }
                Thread.sleep(forTimeInterval: min(0.25, max(0, deadline - clock.systemUptime)))
            }
            return false
        }
    }

    static func textWaitExpression(_ text: String, milliseconds: Int) -> String {
        """
        new Promise(resolve => {
            const needle = \(BrowserRules.jsLiteral(text));
            const matches = () => !!document.body && document.body.innerText.includes(needle);
            if (matches() || \(milliseconds) <= 0) { resolve(matches()); return; }
            let observer, timer, probe;
            const finish = result => {
                observer.disconnect();
                clearTimeout(timer);
                clearInterval(probe);
                resolve(result);
            };
            const check = () => { if (matches()) finish(true); };
            observer = new MutationObserver(check);
            observer.observe(document, {subtree: true, childList: true, characterData: true, attributes: true});
            timer = setTimeout(() => finish(matches()), \(milliseconds));
            probe = setInterval(check, 200);
        })
        """
    }

    private func queryNamedAny(_ label: String) throws -> [[String: Any]] {
        try queryNamedRaw(label).filter { ($0["ignored"] as? Bool) != true }
    }

    // MARK: CDP plumbing

    /// Calls a JavaScript function with `this` set to the element. Returns the function's JSON value.
    func callOnNode(_ node: BrowserNode, _ function: String, arguments: [Any] = [], feedback: String? = nil) throws -> Any? {
        let resolved = try cdp("DOM.resolveNode", ["backendNodeId": node.backendNodeID])
        guard let object = resolved["object"] as? [String: Any], let objectID = object["objectId"] as? String else {
            throw ComputerUseError.message("browser: \"\(node.name)\" is gone from the page; browser read again")
        }
        let payload = try cdp("Runtime.callFunctionOn", [
            "objectId": objectID,
            "functionDeclaration": function,
            "arguments": arguments.map { ["value": $0] },
            "returnByValue": true,
        ], feedback: feedback)
        if payload["exceptionDetails"] != nil {
            throw ComputerUseError.message("browser: the page script failed on \"\(node.name)\"; try another control")
        }
        return (payload["result"] as? [String: Any])?["value"]
    }

    /// Runs a page expression and returns its JSON value (nil when it threw).
    func evaluate(_ expression: String, feedback: String? = nil) throws -> Any? {
        let payload = try cdp("Runtime.evaluate", ["expression": expression, "returnByValue": true], feedback: feedback)
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
    private func cdp(_ method: String, _ params: [String: Any] = [:], feedback: String? = nil) throws -> [String: Any] {
        if let indexedGeneration, indexedGeneration != bridge.referenceGeneration {
            throw Self.staleIndex
        }
        do {
            return try cdpOnce(method, params, feedback: feedback)
        } catch let error as BrowserLinkDropped {
            // The new link starts without what was set up on the old one (focus emulation, accessibility,
            // the frame guard): forget that it was done, so it is done again.
            if let tabID { BrowserPageMemory.shared.forgetTab(bridge: bridge, tab: tabID) }
            if indexedGeneration != nil {
                // Do not send any more commands using the old resolution, even if a caller catches this error.
                indexedGeneration = -1
                throw ComputerUseError.message("browser: the tab connection changed; browser read to check what happened before continuing")
            }
            // Retry only operations with known replay semantics.
            guard Self.isRepeatSafe(method, params) else {
                throw ComputerUseError.message(
                    "browser: the tab connection dropped and the command may have taken effect. Read the tab before deciding whether to repeat it."
                )
            }
            for wait in [0.3, 0.8, 1.5] {
                try BrowserRequestContext.validateCurrent()
                guard BrowserCallBudget.remaining() > wait + 0.3 else { break }
                Thread.sleep(forTimeInterval: wait)
                do {
                    let result = try cdpOnce(method, params, feedback: feedback)
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
        // Probe immediately. A dropped link uses the bounded observation retry path.
        _ = try? cdp("Runtime.evaluate", ["expression": "1", "returnByValue": true])
    }

    /// Chrome reported the tab as not attached (or detached mid-command).
    private struct BrowserLinkDropped: Error { let text: String }

    private static func linkDropped(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["detached while handling", "debugger unattached", "debugger is not attached", "not attached to the tab",
                "cannot access a chrome-extension"].contains { lower.contains($0) }
    }

    /// Replay only known observations. A command with an uncertain delivery may already have changed the page.
    static func isRepeatSafe(_ method: String, _ params: [String: Any]) -> Bool {
        switch method {
        case "Accessibility.getFullAXTree", "Accessibility.getPartialAXTree", "Accessibility.queryAXTree",
             "DOM.getBoxModel", "DOM.resolveNode", "Page.captureScreenshot", "Page.getFrameTree",
             "Page.getNavigationHistory":
            return true
        case "Input.dispatchMouseEvent":
            return (params["type"] as? String) == "mouseMoved"
                && (params["buttons"] as? Int ?? 0) == 0
                && (params["button"] as? String ?? "none") == "none"
        case "Runtime.evaluate":
            guard let expression = params["expression"] as? String else { return false }
            return expression == "1" || expression == "performance.timeOrigin"
                || expression == "[location.href, document.title]"
                || expression == "[location.href, document.title, document.readyState]"
        default:
            return false
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

    private func cdpOnce(_ method: String, _ params: [String: Any], feedback: String?) throws -> [String: Any] {
        Self.trace("\(method) \((params["type"] as? String) ?? "")")
        do {
            return try cdpSend(method, params, feedback: feedback)
        } catch {
            Self.trace("  FAILED \(method): \(String(describing: error).prefix(120))")
            throw error
        }
    }

    private func cdpSend(_ method: String, _ params: [String: Any], feedback: String?) throws -> [String: Any] {
        var arguments = tab
        arguments["method"] = method
        arguments["params"] = params
        arguments["visual_feedback"] = feedback
        // A slow label search can fall back to a full tree read. A timeout is never consent to a dialog.
        let isQuery = method == "Accessibility.queryAXTree"
        let transportWait = min(isQuery ? 3 : 15, BrowserCallBudget.remaining())
        guard transportWait > 0.6 else {
            throw ComputerUseError.message("browser: time budget reached. Inspect the tab and any open prompt before retrying.")
        }
        // Let Chrome report a command timeout while the transport is still available for
        // verification or a full-tree fallback. A lost transport makes old refs unusable.
        let commandWait = min(isQuery ? 2 : 10, transportWait - 0.5)
        arguments["timeout_ms"] = Int(commandWait * 1_000)
        let reply = try bridge.callTool("cdp", arguments: arguments, timeout: transportWait, referenceGeneration: indexedGeneration)
        if reply.isError {
            if Self.linkDropped(reply.text) { throw BrowserLinkDropped(text: reply.text) }
            throw ComputerUseError.message("browser: \(BrowserReply.explain(reply.text))")
        }
        guard let data = reply.text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw ComputerUseError.stateUnavailable(
                "browser: the helper returned an unreadable reply. Inspect the tab before repeating the command."
            )
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

    static func displayableLinkURL(_ address: String) -> String? {
        guard isWebAddress(address), let url = URLComponents(string: address),
              url.user == nil, url.password == nil, !address.contains(where: \.isNewline) else { return nil }
        return address
    }

    static func isWebAddress(_ address: String) -> Bool {
        guard let url = URLComponents(string: address), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// Match the origin and the requested path boundary. Paths and query values are case-sensitive.
    static func sameAddress(_ actual: String, _ expected: String) -> Bool {
        if actual == expected, !expected.isEmpty { return true }
        guard isWebAddress(actual), isWebAddress(expected),
              let here = URLComponents(string: actual), let target = URLComponents(string: expected),
              let scheme = here.scheme?.lowercased(), scheme == target.scheme?.lowercased(),
              here.host?.lowercased() == target.host?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        guard (here.port ?? defaultPort) == (target.port ?? defaultPort) else { return false }
        if let query = target.percentEncodedQuery, here.percentEncodedQuery != query { return false }
        if let fragment = target.percentEncodedFragment, here.percentEncodedFragment != fragment { return false }
        let path = target.percentEncodedPath
        let prefix = path.hasSuffix("/") ? String(path.dropLast()) : path
        return here.percentEncodedPath == prefix || here.percentEncodedPath.hasPrefix(prefix + "/")
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

    /// Accept only the OBU session listing envelope when using absence as evidence of a closed tab.
    static func sessionTabIDs(in text: String) -> [Int]? {
        guard let envelope = json(text) as? [String: Any], envelope["error"] == nil,
              let tabs = envelope["result"] as? [[String: Any]] else { return nil }
        let ids = tabs.compactMap { $0["id"] as? Int }
        return ids.count == tabs.count ? ids : nil
    }

    static func completedTab(in text: String, id: Int, expectedURL: String) -> Bool {
        guard let envelope = json(text) as? [String: Any], envelope["error"] == nil,
              let tabs = envelope["result"] as? [[String: Any]],
              let tab = tabs.first(where: { $0["id"] as? Int == id }),
              tab["status"] as? String == "complete",
              let url = tab["url"] as? String else { return false }
        return BrowserRules.sameAddress(url, expectedURL)
    }

    static func acceptedInitialNavigation(in text: String) -> Bool {
        guard let envelope = json(text) as? [String: Any], envelope["error"] == nil,
              let result = envelope["result"] as? [String: Any],
              let tab = result["tab"] as? [String: Any] else { return false }
        return tab["initialNavigationAccepted"] as? Bool == true
    }

    /// Reads the exact create response for ownership. Navigation data cannot confer ownership.
    static func createdTabID(in text: String) -> Int? {
        guard let envelope = json(text) as? [String: Any], envelope["error"] == nil,
              let result = envelope["result"] as? [String: Any],
              let tab = result["tab"] as? [String: Any], let id = tab["id"] as? Int, id > 0 else { return nil }
        return id
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
        let text: String?
        let mode: String?
        var keys: Set<String> { BrowserRules.controlKeys(nodes) }
    }

    private struct Tab: Hashable {
        let scope: UUID
        let id: Int
    }

    private let lock = NSLock()
    private var observations: [Tab: Observation] = [:]
    private var snapshots: [Tab: (generation: Int, url: String, digest: SHA256.Digest)] = [:]
    private var enabled: Set<String> = []

    func store(_ nodes: [BrowserNode], bridge: BrowserBridge, tab: Int, document: BrowserDocumentIdentity, generation: Int,
               text: String? = nil, mode: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        observations[Tab(scope: bridge.referenceScope, id: tab)] = Observation(
            nodes: nodes, document: document, generation: generation, text: text, mode: mode
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

    /// Retain only a digest of the last delivered image for this client and tab.
    func rememberScreenshot(_ image: Data, bridge: BrowserBridge, tab: Int, generation: Int, url: String) -> Bool {
        let digest = SHA256.hash(data: image)
        let key = Tab(scope: bridge.referenceScope, id: tab)
        lock.lock()
        defer { lock.unlock() }
        let before = snapshots[key]
        snapshots[key] = (generation, url, digest)
        return before?.generation == generation && before?.url == url && before?.digest == digest
    }

    func forgetTab(bridge: BrowserBridge, tab: Int) {
        let prefix = "\(bridge.referenceScope)|\(tab)|"
        lock.lock()
        defer { lock.unlock() }
        let key = Tab(scope: bridge.referenceScope, id: tab)
        observations[key] = nil
        snapshots[key] = nil
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
