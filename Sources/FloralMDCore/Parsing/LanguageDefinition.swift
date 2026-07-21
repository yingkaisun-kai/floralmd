// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation

/// Dependency-free JSON schema for the built-in code-syntax scanner.
struct LanguageDefinition: Codable, Equatable, Sendable {
    let name: String
    let displayName: String?
    let aliases: [String]
    let lineComment: String?
    let blockComment: [String]?
    let strings: [String]
    let keywords: [String]
    let commands: [String]
    let types: [String]
    let attributes: [String]
    let variables: [String]
    let values: [String]

    enum CodingKeys: String, CodingKey {
        case name, displayName, aliases, lineComment, blockComment, strings
        case keywords, commands, types, attributes, variables, values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try container.decode(String.self, forKey: .name)
        guard let normalizedName = Self.normalizedIdentifier(rawName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container,
                debugDescription: "name must be a non-empty fence identifier")
        }
        name = normalizedName

        let rawDisplayName = try container.decodeIfPresent(String.self, forKey: .displayName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = rawDisplayName?.isEmpty == false ? rawDisplayName : nil

        let rawAliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        aliases = try rawAliases.map { alias in
            guard let normalized = Self.normalizedIdentifier(alias) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .aliases, in: container,
                    debugDescription: "aliases must be non-empty fence identifiers")
            }
            return normalized
        }

        lineComment = try container.decodeIfPresent(String.self, forKey: .lineComment)
        blockComment = try container.decodeIfPresent([String].self, forKey: .blockComment)
        strings = try container.decodeIfPresent([String].self, forKey: .strings) ?? ["\"", "'"]
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        commands = try container.decodeIfPresent([String].self, forKey: .commands) ?? []
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
        attributes = try container.decodeIfPresent([String].self, forKey: .attributes) ?? []
        variables = try container.decodeIfPresent([String].self, forKey: .variables) ?? []
        values = try container.decodeIfPresent([String].self, forKey: .values) ?? []

        guard lineComment?.isEmpty != true else {
            throw DecodingError.dataCorruptedError(
                forKey: .lineComment, in: container,
                debugDescription: "lineComment must be non-empty when present")
        }
        if let blockComment,
           blockComment.count != 2 || blockComment.contains(where: \.isEmpty) {
            throw DecodingError.dataCorruptedError(
                forKey: .blockComment, in: container,
                debugDescription: "blockComment must contain exactly two non-empty delimiters")
        }
        guard strings.allSatisfy({ $0.utf16.count == 1 && $0 != "\n" && $0 != "\r" }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .strings, in: container,
                debugDescription: "strings entries must be single UTF-16 delimiters")
        }
        let wordLists = [keywords, commands, types, attributes, variables, values]
        guard wordLists.allSatisfy({ $0.count <= 4_096 })
                && wordLists.joined().allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keywords, in: container,
                debugDescription: "word lists exceed the supported size or contain invalid entries")
        }
    }

    init(name: String, displayName: String? = nil, aliases: [String] = [],
         lineComment: String? = nil, blockComment: [String]? = nil,
         strings: [String] = ["\"", "'"], keywords: [String] = [],
         commands: [String] = [], types: [String] = [], attributes: [String] = [],
         variables: [String] = [], values: [String] = []) {
        self.name = name.lowercased()
        self.displayName = displayName
        self.aliases = aliases.map { $0.lowercased() }
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.strings = strings
        self.keywords = keywords
        self.commands = commands
        self.types = types
        self.attributes = attributes
        self.variables = variables
        self.values = values
    }

    var label: String { displayName ?? name.capitalized }

    private static func normalizedIdentifier(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "._+-#"))
        guard normalized.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return normalized
    }

    static let cFamilyFallback = LanguageDefinition(
        name: "", displayName: "", lineComment: "//", blockComment: ["/*", "*/"],
        keywords: [
            "func", "function", "fn", "def", "let", "var", "val", "const", "static",
            "final", "class", "struct", "enum", "interface", "protocol", "trait",
            "impl", "extends", "implements", "namespace", "package", "module", "mod",
            "import", "export", "from", "use", "using", "include", "require",
            "public", "private", "protected", "internal", "fileprivate", "open",
            "if", "else", "elif", "for", "while", "do", "switch", "case", "default",
            "break", "continue", "return", "yield", "goto", "match", "when", "where",
            "try", "catch", "except", "finally", "throw", "throws", "raise", "rescue",
            "guard", "defer", "async", "await", "go", "chan", "select", "with", "as",
            "is", "in", "of", "new", "delete", "typeof", "instanceof", "sizeof",
            "virtual", "override", "abstract", "extension", "init", "self", "this",
            "super", "and", "or", "not", "lambda", "pass", "global", "nonlocal",
            "mut", "pub", "dyn", "type", "object", "end", "begin", "then", "elsif",
            "unless", "until",
        ],
        types: [
            "void", "int", "long", "short", "char", "float", "double", "bool",
            "boolean", "string", "unsigned", "signed", "auto", "typedef", "template",
        ],
        values: ["nil", "null", "none", "undefined", "true", "false"])
}
