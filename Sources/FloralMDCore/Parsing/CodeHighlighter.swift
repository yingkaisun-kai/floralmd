// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation

/// Shared facade for fenced-code highlighting in Edit and Read mode.
public enum CodeHighlighter {
    /// CotEditor-aligned theme scopes. Lightweight call-site detection maps to
    /// `command`; richer backends can map their native scopes directly.
    public enum TokenType: Equatable, Sendable {
        case keyword, command, type, attribute, variable, value
        case number, string, comment
    }

    public struct Token: Equatable, Sendable {
        public let range: NSRange
        public let type: TokenType

        public init(range: NSRange, type: TokenType) {
            self.range = range
            self.type = type
        }
    }

    private static let backendLock = NSLock()
    nonisolated(unsafe) private static var activeBackend: any CodeSyntaxBackend =
        BuiltinSyntaxBackend(store: .shared)

    /// Installs a process-wide backend behind the stable token model.
    public static func installBackend(_ backend: any CodeSyntaxBackend) {
        backendLock.withLock { activeBackend = backend }
    }

    public static func tokenize(_ code: String, language: String?) -> [Token] {
        let rawLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveLanguage = rawLanguage.isEmpty
            ? SyntaxDefinitionStore.shared.defaultLanguage
            : rawLanguage
        let backend = backendLock.withLock { activeBackend }
        return validatedTokens(
            backend.tokenize(code, language: effectiveLanguage),
            codeLength: (code as NSString).length)
    }

    /// Keeps an extension backend from making Edit and Read mode disagree:
    /// both consumers receive one ordered, non-overlapping UTF-16 token stream.
    static func validatedTokens(_ tokens: [Token], codeLength: Int) -> [Token] {
        let candidates = tokens
            .filter {
                $0.range.location >= 0 && $0.range.length > 0
                    && $0.range.upperBound <= codeLength
            }
            .sorted { lhs, rhs in
                lhs.range.location == rhs.range.location
                    ? lhs.range.length > rhs.range.length
                    : lhs.range.location < rhs.range.location
            }
        var upperBound = 0
        return candidates.compactMap { token in
            guard token.range.location >= upperBound else { return nil }
            upperBound = token.range.upperBound
            return token
        }
    }
}
