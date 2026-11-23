// Markdown (a comment or description body from a host that sends no HTML of its own) to an HTML body fragment for the
// app's locked-down page (`HostedHTMLView`). The text is untrusted, so the HTML is built here, not by swift-markdown's
// `HTMLFormatter` (which passes raw HTML, text and URLs through): every text, code and attribute value is escaped, raw
// HTML shows as inert text, a link keeps its anchor only for an http, https or mailto destination, and an image only
// for an https source (else its alt text shows). Tables, strikethrough and task lists are GFM's; a bare URL is not
// linked (swift-markdown attaches no autolink extension), `<https://...>` is. swift-markdown builds its tree with one
// recursion per nesting level and overflows a thread's stack at a few hundred levels (nested quotes, emphasis, images,
// indented lists), so a document that nests deeper than `maxDepth` shows as its escaped source instead.
import cmark_gfm
import cmark_gfm_extensions
import Foundation
import Markdown

public enum MarkdownHTML {
    /// `markdown` as an HTML body fragment (no document, style or script).
    public static func html(_ markdown: String) -> String { html(markdown, mentionsAt: nil) }

    /// `markdown` as an HTML body fragment (no document, style or script). `mentionsAt`: a web root
    /// (`https://gitlab.com`) under which each `@username` of the text (not in code or a link) links to that user's
    /// page, as GitLab's own page does; nil links none (another host's bodies).
    public static func html(_ markdown: String, mentionsAt mentionRoot: String?) -> String {
        if nestsDeeper(markdown, than: maxDepth) { return "<p class=\"plain\">\(escape(markdown))</p>\n" }
        var renderer = Renderer(mentionRoot: mentionRoot)
        renderer.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return renderer.result
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
        var result = ""

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
            // The info string's first word, as a class only when it is a plain language name.
            let language = codeBlock.language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let isName = !language.isEmpty && language.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_+-".unicodeScalars.contains($0))
            }
            result += isName ? "<pre><code class=\"language-\(language)\">" : "<pre><code>"
            result += escape(codeBlock.code)
            result += "</code></pre>\n"
        }

        mutating func visitLink(_ link: Link) {
            guard let href = allowedURL(link.destination, schemes: ["http", "https", "mailto"]) else {
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
