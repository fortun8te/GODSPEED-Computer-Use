import Foundation

enum BrowserFormattedPaste {
    static func directPayload(_ arguments: [String: Any]) throws -> (format: String, text: String)? {
        guard arguments["format"] != nil || arguments["text"] != nil else { return nil }
        guard let format = (arguments["format"] ?? "text") as? String,
              ["text", "markdown", "html"].contains(format),
              let text = arguments["text"] as? String, !text.isEmpty,
              text.utf8.count <= PrivateClipboard.maxTextBytes else {
            throw ComputerUseError.invalidArguments("Paste requires format text, markdown or html and nonempty text up to 1 MiB.")
        }
        return (format, text)
    }

    static func markdownHTML(_ text: String) throws -> String {
        let parsed = try AttributedString(markdown: text)
        var output = ""
        var open: [(tag: String, id: Int)] = []
        for run in parsed.runs {
            let characters = String(parsed[run.range].characters)
            var html = escape(characters).replacingOccurrences(of: "\n", with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { html = "<code>\(html)</code>" }
            if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
            if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
            if intent.contains(.strikethrough) { html = "<s>\(html)</s>" }
            if let link = run.link {
                html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>"
            }
            let path: [(tag: String, id: Int)] = (run.presentationIntent?.components ?? []).reversed().compactMap {
                let tag: String
                switch $0.kind {
                case .header(let level): tag = "h\(min(6, max(1, level)))"
                case .codeBlock: tag = "pre"
                case .orderedList: tag = "ol"
                case .unorderedList: tag = "ul"
                case .listItem: tag = "li"
                case .blockQuote: tag = "blockquote"
                case .paragraph: tag = "p"
                default: return nil
                }
                return (tag, $0.identity)
            }
            let next = path.isEmpty ? [("p", -1)] : path
            let common = zip(open, next).prefix(while: { $0.0 == $0.1 }).count
            for block in open.dropFirst(common).reversed() { output += "</\(block.tag)>" }
            for block in next.dropFirst(common) { output += "<\(block.tag)>" }
            output += html
            open = next
        }
        for block in open.reversed() { output += "</\(block.tag)>" }
        return output
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // Rebuild only inert formatting and ordinary links. Never insert the supplied HTML itself.
    static let insertScript = #"""
    function(html) {
        const editor = this;
        if (!editor.isConnected || !editor.isContentEditable ||
            editor.closest('[contenteditable="plaintext-only"]')) return 'not_editable';
        const doc = editor.ownerDocument;
        const template = doc.createElement('template');
        template.innerHTML = html;
        const allowed = new Set('A B BLOCKQUOTE BR CODE DIV EM H1 H2 H3 H4 H5 H6 HR I LI OL P PRE S STRIKE STRONG TABLE TBODY TD TH THEAD TR U UL'.split(' '));
        const blocked = new Set('SCRIPT STYLE IFRAME OBJECT EMBED SVG MATH TEMPLATE NOSCRIPT'.split(' '));
        function clean(node, parent, depth) {
            if (depth > 64) return;
            if (node.nodeType === 3) {
                parent.append(doc.createTextNode(node.data));
                return;
            }
            if (node.nodeType !== 1 || blocked.has(node.tagName)) return;
            let destination = parent;
            if (allowed.has(node.tagName)) {
                destination = doc.createElement(node.tagName);
                if (node.tagName === 'A') {
                    const href = node.getAttribute('href')?.trim();
                    if (href && /^(https?:|mailto:)/i.test(href)) destination.setAttribute('href', href);
                }
                parent.append(destination);
            }
            for (const child of node.childNodes) clean(child, destination, depth + 1);
        }
        const safe = doc.createElement('div');
        for (const child of template.content.childNodes) clean(child, safe, 0);
        if (!safe.hasChildNodes()) return 'empty';
        editor.focus({preventScroll: true});
        const selection = editor.getRootNode().getSelection?.() ?? doc.getSelection();
        if (!selection || !editor.contains(selection.anchorNode) || !editor.contains(selection.focusNode))
            return 'no_selection';
        const before = editor.innerHTML;
        const accepted = doc.execCommand('insertHTML', false, safe.innerHTML);
        return accepted && editor.isConnected && editor.innerHTML !== before ? 'changed' : 'unknown';
    }
    """#
}

extension BrowserPage {
    func pasteFormattedHTML(_ html: String, into node: BrowserNode) throws -> ToolCallResult {
        let result: String?
        do {
            result = try callOnNode(node, BrowserFormattedPaste.insertScript, arguments: [html]) as? String
        } catch {
            throw ComputerUseError.stateUnavailable("Formatted paste may have taken effect. Read the editor before retrying.")
        }
        switch result {
        case "changed":
            return .text("Inserted formatted content in the Chrome editor. The editor changed.", deliveryState: .acknowledged)
        case "not_editable", "no_selection", "empty":
            throw ComputerUseError.notSent("Formatted paste requires usable content and a selection or caret in a rich-text editor.")
        default:
            throw ComputerUseError.stateUnavailable("Chrome did not confirm formatted paste. Read the editor before retrying.")
        }
    }
}
