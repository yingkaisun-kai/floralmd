// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation

/// Pluggable tokenizer used by fenced-code rendering in both Edit and Read mode.
/// Implementations return UTF-16 ranges relative to `code` and must not mutate it.
public protocol CodeSyntaxBackend: Sendable {
    func tokenize(_ code: String, language: String) -> [CodeHighlighter.Token]
}
