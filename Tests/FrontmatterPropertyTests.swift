import Testing
@testable import Vomo

@Suite("Frontmatter Property Parsing")
struct FrontmatterPropertyTests {

    @Test("Parses simple key-value string")
    func simpleString() {
        let props = FrontmatterProperty.parse("title: My Note")
        #expect(props.count == 1)
        #expect(props[0].key == "title")
        if case .string(let s) = props[0].value {
            #expect(s == "My Note")
        } else {
            Issue.record("Expected string value")
        }
    }

    @Test("Parses boolean values")
    func boolValues() {
        let props = FrontmatterProperty.parse("published: true\ndraft: false")
        #expect(props.count == 2)
        if case .bool(let b) = props[0].value {
            #expect(b == true)
        } else {
            Issue.record("Expected bool")
        }
        if case .bool(let b) = props[1].value {
            #expect(b == false)
        } else {
            Issue.record("Expected bool")
        }
    }

    @Test("Parses date values")
    func dateValues() {
        let props = FrontmatterProperty.parse("created: 2026-03-22")
        #expect(props.count == 1)
        if case .date(let d) = props[0].value {
            #expect(d == "2026-03-22")
        } else {
            Issue.record("Expected date")
        }
    }

    @Test("Parses number values")
    func numberValues() {
        let props = FrontmatterProperty.parse("rating: 8.5")
        #expect(props.count == 1)
        if case .number(let n) = props[0].value {
            #expect(n == "8.5")
        } else {
            Issue.record("Expected number")
        }
    }

    @Test("Parses inline array tags")
    func inlineArrayTags() {
        let props = FrontmatterProperty.parse("tags: [book, sci-fi, review]")
        #expect(props.count == 1)
        if case .tags(let tags) = props[0].value {
            #expect(tags == ["book", "sci-fi", "review"])
        } else {
            Issue.record("Expected tags, got \(props[0].value)")
        }
    }

    @Test("Parses multiline list tags")
    func multilineListTags() {
        let yaml = """
        tags:
        - book
        - fiction
        - favorite
        """
        let props = FrontmatterProperty.parse(yaml)
        #expect(props.count == 1)
        if case .tags(let tags) = props[0].value {
            #expect(tags == ["book", "fiction", "favorite"])
        } else {
            Issue.record("Expected tags")
        }
    }

    @Test("Parses wiki link value")
    func wikiLink() {
        let props = FrontmatterProperty.parse("related: [[Other Note]]")
        #expect(props.count == 1)
        if case .link(let name) = props[0].value {
            #expect(name == "Other Note")
        } else {
            Issue.record("Expected link")
        }
    }

    @Test("Parses aliases as list")
    func aliases() {
        let props = FrontmatterProperty.parse("aliases: [Foo, Bar Baz]")
        #expect(props.count == 1)
        if case .list(let items) = props[0].value {
            #expect(items == ["Foo", "Bar Baz"])
        } else {
            Issue.record("Expected list")
        }
    }

    @Test("Parses mixed property types")
    func mixedTypes() {
        let yaml = """
        title: Test Note
        date: 2026-03-22
        tags: [a, b]
        published: true
        rating: 9
        """
        let props = FrontmatterProperty.parse(yaml)
        #expect(props.count == 5)
        #expect(props[0].key == "title")
        #expect(props[1].key == "date")
        #expect(props[2].key == "tags")
        #expect(props[3].key == "published")
        #expect(props[4].key == "rating")
    }

    @Test("Handles quoted string values")
    func quotedStrings() {
        let props = FrontmatterProperty.parse("title: \"My Quoted Title\"")
        if case .string(let s) = props[0].value {
            #expect(s == "My Quoted Title")
        } else {
            Issue.record("Expected string")
        }
    }

    @Test("Handles empty YAML")
    func emptyYaml() {
        let props = FrontmatterProperty.parse("")
        #expect(props.isEmpty)
    }
}
