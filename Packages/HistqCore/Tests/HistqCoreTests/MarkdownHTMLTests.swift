// Security tests for the Markdown to HTML renderer (task 6.1): raw HTML, code and text come out escaped, a link keeps
// its anchor only for http, https or mailto (whatever the case, entities or control characters in the scheme), an image
// only for https, every attribute value is escaped, a code block's class only takes a plain language name, and a
// document nested deeper than the limit shows as its escaped source.
import HistqCore
import Testing

struct MarkdownHTMLTests {
    @Test func rawHTMLBlockIsEscapedText() {
        let html = MarkdownHTML.html("<script>alert(1)</script>\n")
        #expect(!html.contains("<script"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test func inlineHTMLIsEscapedText() {
        let html = MarkdownHTML.html("Hi <script>alert(1)</script> <img src=x onerror=alert(1)>")
        #expect(!html.contains("<script"))
        #expect(!html.contains("<img"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test func escapedEntitiesStayEscaped() {
        let html = MarkdownHTML.html("&lt;script&gt;alert(1)&lt;/script&gt;")
        #expect(!html.contains("<script"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test(arguments: [
        "[x](javascript:alert(1))", "[x]( JaVaScRiPt:alert(1))", "[x](data:text/html,<b>x</b>)",
        "[x](vbscript:msgbox(1))", "<javascript:alert(1)>", "[x](&#106;avascript:alert(1))",
        "[x](jav&#9;ascript:alert(1))", "[x](/relative/path)",
    ])
    func unsafeLinkHasNoAnchor(_ markdown: String) {
        let html = MarkdownHTML.html(markdown)
        #expect(!html.contains("<a"))
        #expect(!html.contains("href="))
        #expect(!html.contains("<script"))
    }

    @Test func safeLinksKeepTheirAnchor() {
        #expect(MarkdownHTML.html("[x](HTTPS://a.b/c)").contains("<a href=\"HTTPS://a.b/c\">x</a>"))
        #expect(MarkdownHTML.html("<https://a.b/c>").contains("<a href=\"https://a.b/c\">"))
        #expect(MarkdownHTML.html("[m](mailto:a@b.c)").contains("<a href=\"mailto:a@b.c\">m</a>"))
    }

    @Test func linkAttributesAreEscaped() {
        let html = MarkdownHTML.html("[x](https://a.b/?q=\"><script> \"t'\\\"\")")
        #expect(html.contains("href=\"https://a.b/?q=&quot;&gt;&lt;script&gt;\""))
        #expect(html.contains("title=\"t&#39;&quot;\""))
        #expect(!html.contains("<script"))
    }

    @Test func insecureImageShowsItsAltText() {
        let html = MarkdownHTML.html("![a <b>](http://insecure/x.png)")
        #expect(!html.contains("<img"))
        #expect(html.contains("a &lt;b&gt;"))
    }

    @Test func httpsImageHasEscapedAttributes() {
        let html = MarkdownHTML.html("![a\"b](<https://ok/x.png?\"q> \"t<\")")
        #expect(html.contains("<img src=\"https://ok/x.png?&quot;q\" alt=\"a&quot;b\" title=\"t&lt;\">"))
    }

    @Test func gfmTableRendersWithAlignment() {
        let html = MarkdownHTML.html("| a | b |\n|:-:|--:|\n| <i>1</i> | 2 |\n")
        #expect(html.contains("<table><thead><tr><th align=\"center\">a</th><th align=\"right\">b</th></tr></thead>"))
        #expect(html.contains("<tbody><tr><td align=\"center\">&lt;i&gt;1&lt;/i&gt;</td><td align=\"right\">2</td></tr></tbody>"))
    }

    @Test func codeIsEscaped() {
        let html = MarkdownHTML.html("```swift\nlet a = \"<b>\"\n```\n\nand `<b>&`")
        #expect(html.contains("<pre><code class=\"language-swift\">let a = &quot;&lt;b&gt;&quot;\n</code></pre>"))
        #expect(html.contains("<code>&lt;b&gt;&amp;</code>"))
    }

    @Test func unsafeLanguageGetsNoClass() {
        let html = MarkdownHTML.html("```js\" onload=\"x\nx\n```")
        #expect(html.contains("<pre><code>x\n</code></pre>"))
        #expect(!html.contains("class="))
        #expect(!html.contains("onload=\""))
    }

    @Test func blocksAndInlines() {
        let html = MarkdownHTML.html("# T\n\n*e* **s** ~~d~~ \"q\" --x\n\n> q\n\n3. a\n4. b\n\n- [x] done\n- [ ] todo\n\n---\n")
        #expect(html.contains("<h1>T</h1>"))
        #expect(html.contains("<p><em>e</em> <strong>s</strong> <del>d</del> &quot;q&quot; --x</p>"))
        #expect(html.contains("<blockquote><p>q</p>\n</blockquote>"))
        #expect(html.contains("<ol start=\"3\"><li>a</li>\n<li>b</li>\n</ol>"))
        #expect(html.contains("<li><input type=\"checkbox\" disabled checked> done</li>"))
        #expect(html.contains("<li><input type=\"checkbox\" disabled> todo</li>"))
        #expect(html.contains("<hr>"))
    }

    /// Markdown nesting `depth` levels of each shape (one to three nodes per level).
    private static let nested: [String: @Sendable (Int) -> String] = [
        "quote": { String(repeating: "> ", count: $0) + "x" },
        "em": { String(repeating: "*a ", count: $0) + "x" + String(repeating: " a*", count: $0) },
        "strong": { String(repeating: "**a ", count: $0) + "x" + String(repeating: " a**", count: $0) },
        "del": { String(repeating: "~~a ", count: $0) + "x" + String(repeating: " a~~", count: $0) },
        "img": { String(repeating: "![", count: $0) + "x" + String(repeating: "](https://u)", count: $0) },
        "list": { (0..<$0).map { String(repeating: "  ", count: $0) + "- a" }.joined(separator: "\n") },
    ]

    @Test(arguments: ["quote", "em", "strong", "del", "img", "list"])
    func deepNestingFallsBackToEscapedSource(_ shape: String) throws {
        let make = try #require(Self.nested[shape])
        let deep = MarkdownHTML.html(make(120))
        #expect(deep.hasPrefix("<p class=\"plain\">"))
        for tag in ["<blockquote", "<em", "<strong", "<del", "<img", "<ul"] { #expect(!deep.contains(tag)) }
        let shallow = MarkdownHTML.html(make(20))
        #expect(!shallow.hasPrefix("<p class=\"plain\">"))
    }

    // GitLab's mentions (opt-in): each `@username` of the text links to the user's page; emails, code, links and other
    // hosts' bodies stay as they are.
    @Test func mentionsLinkOnlyWhenAsked() {
        let root = "https://gitlab.com"
        #expect(MarkdownHTML.html("assigned to @thi_coprimal", mentionsAt: root)
            == "<p>assigned to <a class=\"mention\" href=\"https://gitlab.com/thi_coprimal\">@thi_coprimal</a></p>\n")
        #expect(MarkdownHTML.html("assigned to @thi_coprimal") == "<p>assigned to @thi_coprimal</p>\n")
    }

    @Test func mentionDropsTrailingPunctuation() {
        let html = MarkdownHTML.html("Thanks @a.b-c. And (@x)!", mentionsAt: "https://gitlab.com")
        #expect(html.contains("<a class=\"mention\" href=\"https://gitlab.com/a.b-c\">@a.b-c</a>. And"))
        #expect(html.contains("(<a class=\"mention\" href=\"https://gitlab.com/x\">@x</a>)!"))
    }

    @Test(arguments: ["mail a@b.com", "`@code`", "[@linked](https://example.com)", "a lone @ sign", "@@double",
                      "ping @all", "@Here too"])
    func noMentionWhereThereIsNone(_ markdown: String) {
        let html = MarkdownHTML.html(markdown, mentionsAt: "https://gitlab.com")
        #expect(!html.contains("class=\"mention\""))
    }

    @Test func mentionRootAndNameAreEscaped() {
        let html = MarkdownHTML.html("say @x", mentionsAt: "https://h\"x")
        #expect(html == "<p>say <a class=\"mention\" href=\"https://h&quot;x/x\">@x</a></p>\n")
    }

    // A root-relative link (GitLab's system notes) joins the host's origin and never names another host; `//host` and
    // relative paths stay text; without an origin nothing changes.
    @Test(arguments: [
        ("[x](/a/b?c=1)", "https://git.example.com/a/b?c=1"), ("[x](/\\evil.com)", "https://git.example.com/\\evil.com"),
        ("[x](/@evil.com/p)", "https://git.example.com/@evil.com/p"), ("[x](/%2F/evil)", "https://git.example.com/%2F/evil"),
    ])
    func rootRelativeLinksJoinTheOrigin(_ markdown: String, _ href: String) {
        let html = MarkdownHTML.html(markdown, mentionsAt: nil, origin: "https://git.example.com")
        #expect(html == "<p><a href=\"\(href)\">x</a></p>\n")
    }

    @Test func otherRelativeLinksStayText() {
        let origin = "https://git.example.com"
        #expect(MarkdownHTML.html("[x](//evil.com/p)", mentionsAt: nil, origin: origin) == "<p>x</p>\n")
        #expect(MarkdownHTML.html("[x](a/b)", mentionsAt: nil, origin: origin) == "<p>x</p>\n")
        #expect(MarkdownHTML.html("[x](/a/b)") == "<p>x</p>\n")
    }
}
