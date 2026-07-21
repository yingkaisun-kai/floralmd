// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation

/// Markdown extensions recognized by FloralMD's Edit and Read back-ends.
///
/// The app layer maps UserDefaults onto this value, while FloralMDCore keeps
/// parsing and rendering independent of persistence. A missing feature always
/// falls back to literal Markdown source; `.all` preserves the historical
/// behavior for API clients that do not pass an explicit set.
public struct MarkdownFeatures: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let highlight = MarkdownFeatures(rawValue: 1 << 0)
    public static let inlineComment = MarkdownFeatures(rawValue: 1 << 1)
    public static let callout = MarkdownFeatures(rawValue: 1 << 2)
    public static let wikilink = MarkdownFeatures(rawValue: 1 << 3)
    public static let footnote = MarkdownFeatures(rawValue: 1 << 4)
    public static let math = MarkdownFeatures(rawValue: 1 << 5)
    public static let frontMatter = MarkdownFeatures(rawValue: 1 << 6)
    public static let tag = MarkdownFeatures(rawValue: 1 << 7)
    public static let blockID = MarkdownFeatures(rawValue: 1 << 8)
    public static let imageDimensions = MarkdownFeatures(rawValue: 1 << 9)
    public static let wikilinkEmbed = MarkdownFeatures(rawValue: 1 << 10)
    public static let collapsibleCallout = MarkdownFeatures(rawValue: 1 << 11)
    public static let multiBlockComment = MarkdownFeatures(rawValue: 1 << 12)
    public static let obsidianCallouts = MarkdownFeatures(rawValue: 1 << 13)

    public static let all: MarkdownFeatures = [
        .highlight, .inlineComment, .callout, .wikilink, .footnote, .math,
        .frontMatter, .tag, .blockID, .imageDimensions, .wikilinkEmbed,
        .collapsibleCallout, .multiBlockComment, .obsidianCallouts,
    ]
}
