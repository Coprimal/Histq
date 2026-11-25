// Markdown (a comment or description body from a host that sends no HTML of its own) to an HTML body fragment for the
// app's locked-down page (`HostedHTMLView`). The text is untrusted, so the HTML is built here, not by swift-markdown's
// `HTMLFormatter` (which passes raw HTML, text and URLs through): every text, code and attribute value is escaped, raw
// HTML shows as inert text, a link keeps its anchor only for an http, https or mailto destination, and an image only
// for an https source (else its alt text shows). Tables, strikethrough and task lists are GFM's; a bare URL is not
// linked (swift-markdown attaches no autolink extension), `<https://...>` is. swift-markdown builds its tree with one
// recursion per nesting level and overflows a thread's stack at a few hundred levels (nested quotes, emphasis, images,
// indented lists), so a document that nests deeper than `maxDepth` shows as its escaped source instead. A fenced
// suggested change (info string `suggestion` or `suggestion:-N+M`, GitHub's and GitLab's) shows as a small diff: the
// lines it replaces in red when the caller knows them, its new lines in green, all escaped text.
import cmark_gfm
import cmark_gfm_extensions
import Foundation
import Markdown

public enum MarkdownHTML {
    /// `markdown` as an HTML body fragment (no document, style or script).
    public static func html(_ markdown: String) -> String { html(markdown, mentionsAt: nil) }

    /// `markdown` as an HTML body fragment (no document, style or script). `mentionsAt`: a web root
    /// (`https://gitlab.com`) under which each `@username` of the text (not in code or a link) links to that user's
    /// page, as GitLab's own page does; nil links none (another host's bodies). `origin`: the host's
    /// `https://host[:port]`, against which a link to a root-relative path (`/group/project/-/…`, GitLab's system
    /// notes) resolves; nil keeps such a link as its text. `suggestionsFrom`: the text each suggestion block replaces
    /// (its old lines), in the document's order (GitLab's `from_content`); a block without one shows its new lines
    /// only.
    public static func html(
        _ markdown: String, mentionsAt mentionRoot: String?, origin: String? = nil, suggestionsFrom: [String?] = []
    ) -> String {
        if nestsDeeper(markdown, than: maxDepth) { return "<p class=\"plain\">\(escape(markdown))</p>\n" }
        var renderer = Renderer(mentionRoot: mentionRoot, origin: origin, suggestionsFrom: suggestionsFrom)
        renderer.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return renderer.result
    }

    /// A suggested change of a comment's body: the lines it adds, and how many lines above and below the comment's
    /// own it replaces (GitLab's `-N+M`; GitHub's plain `suggestion` replaces the comment's lines: 0 and 0).
    public struct Suggestion: Sendable, Equatable {
        public var above: Int
        public var below: Int
        public var lines: [String]
    }

    /// The suggested changes of `markdown`, in order: its fenced code blocks whose info string is `suggestion` or
    /// `suggestion:-N+M` (none for a document nesting deeper than `maxDepth`).
    public static func suggestions(in markdown: String) -> [Suggestion] {
        guard markdown.contains("suggestion"), !nestsDeeper(markdown, than: maxDepth) else { return [] }
        var finder = SuggestionFinder()
        finder.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return finder.found
    }

    /// `markdown` without its suggestion blocks (their fences and lines, as `suggestions(in:)` finds them), for a
    /// plain-text view that draws them apart.
    public static func removingSuggestions(_ markdown: String) -> String {
        guard markdown.contains("suggestion"), !nestsDeeper(markdown, than: maxDepth) else { return markdown }
        var finder = SuggestionFinder()
        finder.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        guard !finder.sourceLines.isEmpty else { return markdown }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.indices.filter { index in !finder.sourceLines.contains { $0.contains(index + 1) } }
            .map { String(lines[$0]) }.joined(separator: "\n")
    }

    /// `info`'s first word as a suggestion's lines above and below: `suggestion` is 0 and 0, `suggestion:-N+M` N and
    /// M (decimal digits only, each up to 4 of them); nil for any other info string.
    static func suggestionRange(_ info: String?) -> (above: Int, below: Int)? {
        guard let word = info?.split(whereSeparator: \.isWhitespace).first.map(String.init) else { return nil }
        if word == "suggestion" { return (0, 0) }
        guard word.hasPrefix("suggestion:-") else { return nil }
        let parts = word.dropFirst("suggestion:-".count).split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ (1...4).contains($0.count) && $0.allSatisfy(\.isASCII)
            && $0.allSatisfy(\.isNumber) }), let above = Int(parts[0]), let below = Int(parts[1])
        else { return nil }
        return (above, below)
    }

    /// A code block's or a host's text as lines, without the empty one after a final line break.
    static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private struct SuggestionFinder: MarkupWalker {
        var found: [Suggestion] = []
        /// Each block's source lines (1-based, its fences included).
        var sourceLines: [ClosedRange<Int>] = []

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = suggestionRange(codeBlock.language) else { return }
            found.append(Suggestion(above: range.above, below: range.below, lines: lines(codeBlock.code)))
            if let source = codeBlock.range, source.lowerBound.line <= source.upperBound.line {
                sourceLines.append(source.lowerBound.line...source.upperBound.line)
            }
        }
    }

    /// The deepest node a rendered document may have. Measured in a Debug build on a test worker thread: every nesting
    /// shape renders at 300, nested quotes overflow the stack by 500.
    static let maxDepth = 100

    /// Whether the document cmark parses from `markdown`, with swift-markdown's options and extensions, has a node
    /// deeper than `limit`. cmark parses any depth, and the tree is walked here without recursion.
    static func nestsDeeper(_ markdown: String, than limit: Int) -> Bool {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return true }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return true }
        defer { cmark_node_free(root) }
        var node = root
        var depth = 0
        while true {
            if let child = cmark_node_first_child(node) {
                depth += 1
                if depth > limit { return true }
                node = child
            } else {
                while node != root, cmark_node_next(node) == nil {
                    node = cmark_node_parent(node)
                    depth -= 1
                }
                if node == root { return false }
                node = cmark_node_next(node)
            }
        }
    }

    /// Escapes text for an HTML text node or a quoted attribute value.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// `destination` as a browser reads it (tabs and line breaks removed, C0 controls and spaces trimmed) when its
    /// scheme is one of `schemes` (lowercase), else nil: a relative URL or any other scheme is refused.
    static func allowedURL(_ destination: String?, schemes: Set<String>) -> String? {
        guard let destination else { return nil }
        let url = String(String.UnicodeScalarView(destination.unicodeScalars.filter { !"\t\n\r".unicodeScalars.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"..."\u{20}"))
        guard let colon = url.firstIndex(of: ":"), schemes.contains(url[..<colon].lowercased()) else { return nil }
        return url
    }

    /// `text` escaped, each `@username` in it a link to `root`/username (`class="mention"`). A mention starts the text
    /// or follows a character that cannot be in a username or an email's local part, so `a@b.com` stays text; a
    /// username is GitLab's letters, digits, `_`, `.` and `-`, without the trailing `.` or `-` that end a sentence;
    /// `@all` and `@here` stay text.
    static func linkingMentions(_ text: String, root: String) -> String {
        let characters = Array(text)
        func inName(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
        }
        var result = ""
        var plain = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let starts = character == "@" && (index == 0 || !(inName(characters[index - 1])
                || "@/+".contains(characters[index - 1])))
            if starts {
                var end = index + 1
                while end < characters.count, inName(characters[end]) { end += 1 }
                while end > index + 1, ".-".contains(characters[end - 1]) { end -= 1 }
                let name = String(characters[(index + 1)..<end])
                // `@all` and `@here` notify everyone and are nobody's page.
                if end > index + 1, !["all", "here"].contains(name.lowercased()) {
                    result += escape(plain)
                    plain = ""
                    result += "<a class=\"mention\" href=\"\(escape(root))/\(escape(name))\">@\(escape(name))</a>"
                    index = end
                    continue
                }
            }
            plain.append(character)
            index += 1
        }
        return result + escape(plain)
    }

    private struct Renderer: MarkupWalker {
        let mentionRoot: String?
        let origin: String?
        let suggestionsFrom: [String?]
        var result = ""
        /// The suggestion blocks rendered so far, the next one's index in `suggestionsFrom`.
        var suggestionIndex = 0

        mutating func visitText(_ text: Text) {
            guard let mentionRoot, !Self.isInLink(text) else { return result += escape(text.string) }
            result += linkingMentions(text.string, root: mentionRoot)
        }

        /// Whether `markup` is inside a link: its text stays the link's.
        private static func isInLink(_ markup: Markup) -> Bool {
            var node = markup.parent
            while let current = node {
                if current is Link { return true }
                node = current.parent
            }
            return false
        }
        mutating func visitSoftBreak(_ softBreak: SoftBreak) { result += "\n" }
        mutating func visitLineBreak(_ lineBreak: LineBreak) { result += "<br>\n" }
        mutating func visitInlineCode(_ inlineCode: InlineCode) { result += "<code>\(escape(inlineCode.code))</code>" }
        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) { result += escape(inlineHTML.rawHTML) }
        mutating func visitHTMLBlock(_ html: HTMLBlock) { result += "<p class=\"plain\">\(escape(html.rawHTML))</p>\n" }
        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) { result += "<hr>\n" }

        mutating func visitEmphasis(_ emphasis: Emphasis) { wrap("em", emphasis) }
        mutating func visitStrong(_ strong: Strong) { wrap("strong", strong) }
        mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap("del", strikethrough) }
        mutating func visitBlockQuote(_ blockQuote: BlockQuote) { wrap("blockquote", blockQuote) }
        mutating func visitUnorderedList(_ unorderedList: UnorderedList) { wrap("ul", unorderedList) }
        mutating func visitTableHead(_ tableHead: Table.Head) { result += "<thead><tr>"; descendInto(tableHead); result += "</tr></thead>\n" }
        mutating func visitTableBody(_ tableBody: Table.Body) { wrap("tbody", tableBody) }
        mutating func visitTableRow(_ tableRow: Table.Row) { wrap("tr", tableRow) }

        mutating func visitHeading(_ heading: Heading) { wrap("h\(min(max(heading.level, 1), 6))", heading) }

        mutating func visitParagraph(_ paragraph: Paragraph) {
            // A list item's lone paragraph goes without `<p>` (swift-markdown keeps no tight/loose flag), so a tight
            // list is not spaced out by the paragraph margin.
            if let item = paragraph.parent as? ListItem, item.childCount == 1 {
                descendInto(paragraph)
            } else {
                wrap("p", paragraph)
            }
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) {
            result += orderedList.startIndex == 1 ? "<ol>" : "<ol start=\"\(orderedList.startIndex)\">"
            descendInto(orderedList)
            result += "</ol>\n"
        }

        mutating func visitListItem(_ listItem: ListItem) {
            result += "<li>"
            if let checkbox = listItem.checkbox {
                result += checkbox == .checked ? "<input type=\"checkbox\" disabled checked> " : "<input type=\"checkbox\" disabled> "
            }
            descendInto(listItem)
            result += "</li>\n"
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            if suggestionRange(codeBlock.language) != nil { return suggestion(codeBlock) }
            // The info string's first word, as a class only when it is a plain language name.
            let language = codeBlock.language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let isName = !language.isEmpty && language.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_+-".unicodeScalars.contains($0))
            }
            result += isName ? "<pre><code class=\"language-\(language)\">" : "<pre><code>"
            result += escape(codeBlock.code)
            result += "</code></pre>\n"
        }

        /// A suggested change as a small diff, GitHub's "Suggested change" box: a title, then each line it replaces
        /// (`suggestionsFrom`, when known) and each new line, one escaped `div` per line; fixed class names only.
        private mutating func suggestion(_ codeBlock: CodeBlock) {
            let old = suggestionIndex < suggestionsFrom.count ? suggestionsFrom[suggestionIndex] : nil
            suggestionIndex += 1
            result += "<div class=\"suggestion\"><div class=\"suggestion-head\">Suggested change</div>"
            for line in old.map(lines) ?? [] { result += "<div class=\"del\">\(escape(line))</div>" }
            for line in lines(codeBlock.code) { result += "<div class=\"add\">\(escape(line))</div>" }
            result += "</div>\n"
        }

        mutating func visitLink(_ link: Link) {
            // A root-relative path (one `/`, not `//host`) joins the origin; the result is checked as any link is.
            var destination = link.destination
            if let origin, let path = destination, path.hasPrefix("/"), !path.hasPrefix("//") {
                destination = origin + path
            }
            guard let href = allowedURL(destination, schemes: ["http", "https", "mailto"]) else {
                descendInto(link)
                return
            }
            result += "<a href=\"\(escape(href))\""
            if let title = link.title, !title.isEmpty { result += " title=\"\(escape(title))\"" }
            result += ">"
            descendInto(link)
            result += "</a>"
        }

        mutating func visitImage(_ image: Image) {
            guard let src = allowedURL(image.source, schemes: ["https"]) else {
                result += escape(image.plainText)
                return
            }
            result += "<img src=\"\(escape(src))\" alt=\"\(escape(image.plainText))\""
            if let title = image.title, !title.isEmpty { result += " title=\"\(escape(title))\"" }
            result += ">"
        }

        mutating func visitTable(_ table: Table) { wrap("table", table) }

        mutating func visitTableCell(_ tableCell: Table.Cell) {
            // Table spans are on in swift-markdown's parser: a covered cell has a zero span and is not drawn.
            guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }
            let tag = tableCell.parent is Table.Head ? "th" : "td"
            result += "<\(tag)"
            let alignments = tableCell.table?.columnAlignments ?? []
            if tableCell.indexInParent < alignments.count, let alignment = alignments[tableCell.indexInParent] {
                switch alignment {
                case .left: result += " align=\"left\""
                case .center: result += " align=\"center\""
                case .right: result += " align=\"right\""
                }
            }
            if tableCell.colspan > 1 { result += " colspan=\"\(tableCell.colspan)\"" }
            if tableCell.rowspan > 1 { result += " rowspan=\"\(tableCell.rowspan)\"" }
            result += ">"
            descendInto(tableCell)
            result += "</\(tag)>"
        }

        private mutating func wrap(_ tag: String, _ markup: Markup) {
            result += "<\(tag)>"
            descendInto(markup)
            result += "</\(tag)>"
            if markup is BlockMarkup { result += "\n" }
        }
    }
}

private extension Table.Cell {
    /// The table the cell is in (head row or body row).
    var table: Table? {
        var node = parent
        while let current = node, !(current is Table) { node = current.parent }
        return node as? Table
    }
}
