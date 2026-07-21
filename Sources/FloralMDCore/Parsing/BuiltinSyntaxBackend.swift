// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation

/// Lightweight O(n) scanner driven by declarative language definitions.
struct BuiltinSyntaxBackend: CodeSyntaxBackend {
    let store: SyntaxDefinitionStore

    func tokenize(_ code: String, language: String) -> [CodeHighlighter.Token] {
        switch store.resolve(language) {
        case .plain: return []
        case .definition(let definition): return Self.scan(code, definition)
        case .unknown: return Self.scan(code, .cFamilyFallback)
        }
    }

    static func scan(_ code: String, _ definition: LanguageDefinition) -> [CodeHighlighter.Token] {
        let source = code as NSString
        let length = source.length
        guard length > 0 else { return [] }

        let lineComment = definition.lineComment.map { Array($0.utf16) }
        let blockOpen = definition.blockComment.flatMap { $0.count == 2 ? Array($0[0].utf16) : nil }
        let blockClose = definition.blockComment.flatMap { $0.count == 2 ? Array($0[1].utf16) : nil }
        let stringDelimiters = Set(definition.strings.compactMap { $0.utf16.first })

        var wordType: [String: CodeHighlighter.TokenType] = [:]
        for word in definition.keywords { wordType[word] = .keyword }
        for word in definition.types { wordType[word] = .type }
        for word in definition.commands { wordType[word] = .command }
        for word in definition.attributes { wordType[word] = .attribute }
        for word in definition.variables { wordType[word] = .variable }
        for word in definition.values { wordType[word] = .value }

        func matches(_ literal: [unichar], at index: Int) -> Bool {
            guard index + literal.count <= length else { return false }
            return literal.indices.allSatisfy {
                source.character(at: index + $0) == literal[$0]
            }
        }
        func isIdentifierStart(_ character: unichar) -> Bool {
            (character >= 65 && character <= 90)
                || (character >= 97 && character <= 122) || character == 95
        }
        func isIdentifier(_ character: unichar) -> Bool {
            isIdentifierStart(character) || (character >= 48 && character <= 57)
        }

        var tokens: [CodeHighlighter.Token] = []
        var index = 0
        while index < length {
            let character = source.character(at: index)
            if let marker = lineComment, !marker.isEmpty, matches(marker, at: index) {
                let start = index
                while index < length && source.character(at: index) != 0x0A { index += 1 }
                tokens.append(.init(range: NSRange(location: start, length: index - start), type: .comment))
                continue
            }
            if let open = blockOpen, let close = blockClose, matches(open, at: index) {
                let start = index
                index += open.count
                while index < length && !matches(close, at: index) { index += 1 }
                index = min(length, index + close.count)
                tokens.append(.init(range: NSRange(location: start, length: index - start), type: .comment))
                continue
            }
            if stringDelimiters.contains(character) {
                let delimiter = character
                let start = index
                index += 1
                while index < length {
                    let current = source.character(at: index)
                    if current == 0x5C { index = min(length, index + 2); continue }
                    if current == delimiter { index += 1; break }
                    if current == 0x0A { break }
                    index += 1
                }
                tokens.append(.init(range: NSRange(location: start, length: index - start), type: .string))
                continue
            }
            if character >= 48 && character <= 57 {
                let start = index
                index += 1
                while index < length {
                    let current = source.character(at: index)
                    if isIdentifier(current) || current == 0x2E { index += 1 } else { break }
                }
                tokens.append(.init(range: NSRange(location: start, length: index - start), type: .number))
                continue
            }
            if isIdentifierStart(character) {
                let start = index
                index += 1
                while index < length && isIdentifier(source.character(at: index)) { index += 1 }
                let range = NSRange(location: start, length: index - start)
                let word = source.substring(with: range)
                if let type = wordType[word] {
                    tokens.append(.init(range: range, type: type))
                } else if let first = word.unicodeScalars.first, first.properties.isUppercase {
                    tokens.append(.init(range: range, type: .type))
                } else {
                    var lookahead = index
                    while lookahead < length && source.character(at: lookahead) == 0x20 { lookahead += 1 }
                    if lookahead < length && source.character(at: lookahead) == 0x28 {
                        tokens.append(.init(range: range, type: .command))
                    }
                }
                continue
            }
            index += 1
        }
        return tokens
    }
}
