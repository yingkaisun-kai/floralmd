// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import Foundation
@testable import FloralMDCore

@Suite("CodeHighlighter")
struct CodeHighlighterTests {

    private func tokens(_ code: String, _ lang: String?) -> [(text: String, type: CodeHighlighter.TokenType)] {
        let ns = code as NSString
        return CodeHighlighter.tokenize(code, language: lang).map {
            (ns.substring(with: $0.range), $0.type)
        }
    }

    @Test("Recognizes keywords, functions, numbers, strings, comments")
    func swiftTokens() {
        let t = tokens("// hi\nfunc greet() { let n = 42; return \"x\" }", "swift")
        #expect(t.contains { $0.text == "// hi" && $0.type == .comment })
        #expect(t.contains { $0.text == "func" && $0.type == .keyword })
        #expect(t.contains { $0.text == "greet" && $0.type == .function })
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
}
