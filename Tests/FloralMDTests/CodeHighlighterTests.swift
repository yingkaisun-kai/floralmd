// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import Foundation
@testable import FloralMDCore

@Suite("CodeHighlighter", .serialized)
struct CodeHighlighterTests {

    private func tokens(_ code: String, _ lang: String?) -> [(text: String, type: CodeHighlighter.TokenType)] {
        let ns = code as NSString
        return CodeHighlighter.tokenize(code, language: lang).map {
            (ns.substring(with: $0.range), $0.type)
        }
    }

    @Test("Recognizes keywords, commands, numbers, strings, comments")
    func swiftTokens() {
        let t = tokens("// hi\nfunc greet() { let n = 42; return \"x\" }", "swift")
        #expect(t.contains { $0.text == "// hi" && $0.type == .comment })
        #expect(t.contains { $0.text == "func" && $0.type == .keyword })
        #expect(t.contains { $0.text == "greet" && $0.type == .command })
        #expect(t.contains { $0.text == "let" && $0.type == .keyword })
        #expect(t.contains { $0.text == "42" && $0.type == .number })
        #expect(t.contains { $0.text == "\"x\"" && $0.type == .string })
    }

    @Test("# starts a comment in hash-comment languages only")
    func hashComment() {
        #expect(tokens("# note", "python").contains { $0.type == .comment })
        #expect(!tokens("# note", "swift").contains { $0.type == .comment })
    }

    @Test("Capitalized identifier is typed as a type")
    func typeToken() {
        #expect(tokens("let x: String = y", "swift").contains { $0.text == "String" && $0.type == .type })
    }

    @Test("Plain-text fence aliases disable syntax highlighting")
    func plainTextLanguages() {
        let prose = "先验证 Habitat/SDA 能不能构造 target + distractor"
        for language in ["text", "txt", "plain", "plaintext", " TEXT "] {
            #expect(tokens(prose, language).isEmpty)
        }
    }

    @Test("Block comments span across lines")
    func blockComment() {
        let t = tokens("a /* multi\nline */ b", "c")
        #expect(t.contains { $0.text == "/* multi\nline */" && $0.type == .comment })
    }

    @Test("Definition word lists map to CotEditor-aligned scopes")
    func alignedScopes() {
        let definition = LanguageDefinition(
            name: "toy", keywords: ["kw"], commands: ["cmd"], types: ["Typ"],
            attributes: ["attr"], variables: ["variable"], values: ["value"])
        let source = "kw cmd Typ attr variable value" as NSString
        let tokens = BuiltinSyntaxBackend.scan(source as String, definition)
        let scoped = Dictionary(uniqueKeysWithValues: tokens.map {
            (source.substring(with: $0.range), $0.type)
        })
        #expect(scoped["kw"] == .keyword)
        #expect(scoped["cmd"] == .command)
        #expect(scoped["Typ"] == .type)
        #expect(scoped["attr"] == .attribute)
        #expect(scoped["variable"] == .variable)
        #expect(scoped["value"] == .value)
    }

    @Test("Unknown tagged fences retain the generic fallback")
    func unknownLanguageFallback() {
        let t = tokens("func call() { return 1 }", "future-language")
        #expect(t.contains { $0.text == "func" && $0.type == .keyword })
        #expect(t.contains { $0.text == "call" && $0.type == .command })
        #expect(t.contains { $0.text == "1" && $0.type == .number })
    }

    @Test("Untagged fences use the safe plain-text default")
    func untaggedDefault() {
        let store = SyntaxDefinitionStore.shared
        let saved = store.defaultLanguage
        defer { store.defaultLanguage = saved }
        store.defaultLanguage = "plain"
        #expect(tokens("func call()", nil).isEmpty)
    }

    @Test("Read-mode HTML uses the expanded shared token scopes")
    func htmlScopes() {
        let html = HTMLRenderer.highlightCode("func call() { return true }", language: "swift")
        #expect(html.contains("class=\"tok-keyword\">func</span>"))
        #expect(html.contains("class=\"tok-command\">call</span>"))
        #expect(html.contains("class=\"tok-value\">true</span>"))
    }

    @Test("Backend token ranges are bounded, ordered, and non-overlapping")
    func backendRangeBoundary() {
        let tokens: [CodeHighlighter.Token] = [
            .init(range: NSRange(location: 4, length: 2), type: .value),
            .init(range: NSRange(location: 0, length: 4), type: .keyword),
            .init(range: NSRange(location: 1, length: 1), type: .command),
            .init(range: NSRange(location: 6, length: 0), type: .comment),
            .init(range: NSRange(location: 7, length: 2), type: .string),
        ]
        #expect(CodeHighlighter.validatedTokens(tokens, codeLength: 8) == [
            .init(range: NSRange(location: 0, length: 4), type: .keyword),
            .init(range: NSRange(location: 4, length: 2), type: .value),
        ])
    }
}

@Suite("SyntaxDefinitionStore", .serialized)
struct SyntaxDefinitionStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-SyntaxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Bundled definitions and aliases load")
    func bundledDefinitions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyntaxDefinitionStore(userDirectory: directory)
        guard case .definition(let definition) = store.resolve("py") else {
            Issue.record("py did not resolve to a bundled definition")
            return
        }
        #expect(definition.name == "python")
        #expect(store.availableLanguages().first?.id == "plain")
        #expect(store.loadIssues.isEmpty)
    }

    @Test("User definition overrides the same bundled canonical name")
    func userOverride() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"name":"swift","displayName":"Custom Swift","lineComment":"#","keywords":["custom"]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("swift.json"))

        let store = SyntaxDefinitionStore(userDirectory: directory)
        guard case .definition(let definition) = store.resolve("swift") else {
            Issue.record("swift did not resolve")
            return
        }
        #expect(definition.displayName == "Custom Swift")
        #expect(definition.lineComment == "#")
        #expect(store.isUserDefinition("swift"))
    }

    @Test("User aliases cannot replace another language's canonical id")
    func canonicalNamesWin() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"name":"toy","aliases":["swift"],"lineComment":"#"}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("toy.json"))

        let store = SyntaxDefinitionStore(userDirectory: directory)
        guard case .definition(let definition) = store.resolve("swift") else {
            Issue.record("swift did not resolve")
            return
        }
        #expect(definition.name == "swift")
    }

    @Test("Invalid and oversized user definitions fail closed with diagnostics")
    func invalidDefinitions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("invalid.json"))
        try Data(repeating: 0x20, count: 512 * 1_024 + 1)
            .write(to: directory.appendingPathComponent("large.json"))
        let target = directory.appendingPathComponent("outside.txt")
        try Data("{\"name\":\"linked\"}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.json"),
            withDestinationURL: target)

        let store = SyntaxDefinitionStore(userDirectory: directory)
        #expect(store.loadIssues.map(\.reason).contains(.invalidDefinition))
        #expect(store.loadIssues.map(\.reason).contains(.fileTooLarge))
        #expect(store.loadIssues.map(\.reason).contains(.notRegularFile))
        #expect(store.resolve("invalid") == .unknown)
    }
}
