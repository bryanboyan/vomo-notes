import Testing
@testable import Vomo

@Suite("MarkdownParser")
struct MarkdownParserTests {

    // MARK: - Frontmatter Extraction

    @Test("Extracts YAML frontmatter")
    func extractFrontmatter() {
        let input = """
        ---
        title: Test Note
        tags: [book, review]
        ---
        # Hello World
        Some content here.
        """
        let (fm, body) = MarkdownParser.extractFrontmatter(input)
        #expect(fm != nil)
        #expect(fm!.contains("title: Test Note"))
        #expect(fm!.contains("tags: [book, review]"))
        #expect(body.contains("# Hello World"))
        #expect(!body.contains("---"))
    }

    @Test("Returns nil frontmatter when none exists")
    func noFrontmatter() {
        let input = "# Just a heading\nSome text."
        let (fm, body) = MarkdownParser.extractFrontmatter(input)
        #expect(fm == nil)
        #expect(body.contains("# Just a heading"))
    }

    @Test("Handles empty frontmatter")
    func emptyFrontmatter() {
        let input = "---\n---\n# Content"
        let (fm, body) = MarkdownParser.extractFrontmatter(input)
        #expect(fm == nil) // empty → nil
        #expect(body.contains("# Content"))
    }

    @Test("Handles unclosed frontmatter (no closing ---)")
    func unclosedFrontmatter() {
        let input = "---\ntitle: Broken\n# Content without closing"
        let (fm, body) = MarkdownParser.extractFrontmatter(input)
        #expect(fm == nil) // unclosed → treat as no frontmatter
        #expect(body == input)
    }

    @Test("Does not treat --- in body as frontmatter")
    func midBodyDashes() {
        let input = "# Title\n\nSome text\n---\nMore text"
        let (fm, body) = MarkdownParser.extractFrontmatter(input)
        #expect(fm == nil)
        #expect(body == input)
    }

    // MARK: - Wiki Link Conversion

    @Test("Converts simple wiki link")
    func simpleWikiLink() {
        let result = MarkdownParser.preprocess("See [[My Note]] for details.")
        #expect(result.contains("[My Note](obsidian://open/My%20Note)"))
        #expect(!result.contains("[["))
    }

    @Test("Converts aliased wiki link")
    func aliasedWikiLink() {
        let result = MarkdownParser.preprocess("Check [[Real Note|Display Text]] here.")
        #expect(result.contains("[Display Text](obsidian://open/Real%20Note)"))
    }

    @Test("Converts multiple wiki links in one line")
    func multipleWikiLinks() {
        let result = MarkdownParser.preprocess("Links: [[Note A]] and [[Note B]]")
        #expect(result.contains("[Note A](obsidian://open/Note%20A)"))
        #expect(result.contains("[Note B](obsidian://open/Note%20B)"))
    }

    // MARK: - Tag Conversion

    @Test("Converts standalone tag")
    func standaloneTag() {
        let result = MarkdownParser.preprocess("This is #important stuff")
        #expect(result.contains("[#important](obsidian://tag/important)"))
    }

    @Test("Does not convert headings as tags")
    func headingsNotTags() {
        let result = MarkdownParser.preprocess("## Heading Two")
        #expect(!result.contains("obsidian://tag/"))
        #expect(result.contains("## Heading Two"))
    }

    @Test("Does not convert tags inside code blocks")
    func tagsInCodeBlock() {
        let input = "Before\n```\n#not-a-tag\n```\nAfter #real-tag"
        let result = MarkdownParser.preprocess(input)
        #expect(!result.contains("[#not-a-tag]"))
        #expect(result.contains("[#real-tag](obsidian://tag/real-tag)"))
    }

    @Test("Converts tag with slashes")
    func tagWithSlash() {
        let result = MarkdownParser.preprocess("Nested #project/active here")
        #expect(result.contains("[#project/active](obsidian://tag/project/active)"))
    }

    // MARK: - Frontmatter stripping in preprocess

    @Test("Preprocess strips frontmatter")
    func preprocessStripsFrontmatter() {
        let input = "---\ntitle: Test\n---\n# Hello"
        let result = MarkdownParser.preprocess(input)
        #expect(!result.contains("title: Test"))
        #expect(result.contains("# Hello"))
    }

    // MARK: - preprocessWithFrontmatter

    @Test("preprocessWithFrontmatter returns both parts")
    func preprocessWithFrontmatter() {
        let input = "---\ntags: [a, b]\n---\nSee [[Note]] with #tag"
        let parsed = MarkdownParser.preprocessWithFrontmatter(input)
        #expect(parsed.frontmatter != nil)
        #expect(parsed.frontmatter!.contains("tags: [a, b]"))
        #expect(parsed.content.contains("[Note](obsidian://open/Note)"))
        #expect(parsed.content.contains("[#tag](obsidian://tag/tag)"))
    }

    // MARK: - Dataview block handling

    @Test("Dataview block replaced with placeholder")
    func dataviewBlock() {
        let input = "Before\n```dataview\nTABLE rating FROM #books\n```\nAfter"
        let result = MarkdownParser.preprocess(input)
        #expect(result.contains("**Dataview Query**"))
        #expect(result.contains("view in Obsidian"))
        #expect(result.contains("`TABLE rating FROM #books`"))
        #expect(!result.contains("```dataview"))
    }

    @Test("DataviewJS block replaced with placeholder")
    func dataviewJSBlock() {
        let input = "Text\n```dataviewjs\ndv.list(dv.pages())\n```\nMore"
        let result = MarkdownParser.preprocess(input)
        #expect(result.contains("**DataviewJS Query**"))
        #expect(!result.contains("```dataviewjs"))
    }

    @Test("Regular code blocks not affected by dataview handler")
    func regularCodeBlock() {
        let input = "```python\nprint('hello')\n```"
        let result = MarkdownParser.preprocess(input)
        #expect(result.contains("```python"))
    }

    // MARK: - Extract helpers

    @Test("extractWikiLinks returns link targets")
    func extractWikiLinks() {
        let links = MarkdownParser.extractWikiLinks(from: "See [[A]], [[B|Alias]], and [[C]]")
        #expect(links.count == 3)
        #expect(links.contains("A"))
        #expect(links.contains("B"))
        #expect(links.contains("C"))
    }

    @Test("extractTags returns tag names")
    func extractTags() {
        let tags = MarkdownParser.extractTags(from: "Has #foo and #bar/baz tags")
        #expect(tags.count == 2)
        #expect(tags.contains("foo"))
        #expect(tags.contains("bar/baz"))
    }

    // MARK: - extractDataviewBlocks (segment-based rendering)

    @Test("extractDataviewBlocks splits markdown and dataview")
    func extractDataviewBlocksBasic() {
        let input = "# Title\nSome text\n```dataview\nTABLE rating FROM \"Books\"\n```\nMore text"
        let segments = MarkdownParser.extractDataviewBlocks(input)
        #expect(segments.count == 3)
        if case .markdown(let text) = segments[0] {
            #expect(text.contains("Title"))
        } else { #expect(Bool(false), "Expected markdown segment") }
        if case .dataviewQuery(let query) = segments[1] {
            #expect(query == "TABLE rating FROM \"Books\"")
        } else { #expect(Bool(false), "Expected dataview query segment") }
        if case .markdown(let text) = segments[2] {
            #expect(text.contains("More text"))
        } else { #expect(Bool(false), "Expected markdown segment") }
    }

    @Test("extractDataviewBlocks handles dataviewjs as separate type")
    func extractDataviewBlocksJS() {
        let input = "Before\n```dataviewjs\ndv.list(dv.pages())\n```\nAfter"
        let segments = MarkdownParser.extractDataviewBlocks(input)
        #expect(segments.count == 3)
        if case .dataviewJS(let code) = segments[1] {
            #expect(code.contains("dv.list"))
        } else { #expect(Bool(false), "Expected dataviewJS segment") }
    }

    @Test("extractDataviewBlocks returns single segment for plain markdown")
    func extractDataviewBlocksNoDataview() {
        let input = "# Just Markdown\nNo dataview here\n```python\nprint('hi')\n```"
        let segments = MarkdownParser.extractDataviewBlocks(input)
        #expect(segments.count == 1)
        if case .markdown = segments[0] {
            // pass
        } else { #expect(Bool(false), "Expected single markdown segment") }
    }

    @Test("extractDataviewBlocks strips frontmatter")
    func extractDataviewBlocksStripsFrontmatter() {
        let input = "---\ntitle: Test\n---\n# Hello\n```dataview\nLIST\n```"
        let segments = MarkdownParser.extractDataviewBlocks(input)
        // Should not contain frontmatter in any segment
        for segment in segments {
            if case .markdown(let text) = segment {
                #expect(!text.contains("title: Test"))
            }
        }
        // Should have dataview query
        let hasDataview = segments.contains { segment in
            if case .dataviewQuery = segment { return true }
            return false
        }
        #expect(hasDataview)
    }

    @Test("extractDataviewBlocks processes wiki links in markdown segments")
    func extractDataviewBlocksProcessesLinks() {
        let input = "See [[My Note]]\n```dataview\nLIST\n```"
        let segments = MarkdownParser.extractDataviewBlocks(input)
        if case .markdown(let text) = segments[0] {
            #expect(text.contains("[My Note](obsidian://open/My%20Note)"))
            #expect(!text.contains("[["))
        } else { #expect(Bool(false), "Expected markdown segment") }
    }
}
