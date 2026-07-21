import Foundation

/// Pure helpers for turning a file-system image into ordinary Markdown source.
/// Image bytes remain ordinary files; the editor inserts only `![alt](path)`.
public enum ImageReference {
    public struct DisplaySize: Equatable, Sendable {
        public let altText: String
        public let width: Int?
        public let height: Int?
    }

    public enum PathStyle: String, CaseIterable, Sendable {
        case absolute
        case relative
    }

    public static func destination(
        documentURL: URL?,
        imageURL: URL,
        style: PathStyle
    ) -> String? {
        switch style {
        case .absolute:
            return encodePath(imageURL.standardizedFileURL.path)
        case .relative:
            guard let documentURL else { return nil }
            return relativeDestination(documentURL: documentURL, imageURL: imageURL)
        }
    }

    /// Returns a percent-encoded path from the Markdown file's directory to the
    /// selected image. `/` remains readable while characters that are special
    /// inside a Markdown destination (` `, `#`, parentheses, and so on) are
    /// encoded.
    public static func relativeDestination(documentURL: URL, imageURL: URL) -> String {
        let base = documentURL.deletingLastPathComponent().standardizedFileURL.pathComponents
        let target = imageURL.standardizedFileURL.pathComponents

        var common = 0
        while common < min(base.count, target.count), base[common] == target[common] {
            common += 1
        }

        let parents = Array(repeating: "..", count: base.count - common)
        let descendants = Array(target.dropFirst(common))
        let relative = (parents + descendants).joined(separator: "/")
        return encodePath(relative.isEmpty ? imageURL.lastPathComponent : relative)
    }

    public static func markdown(altText: String, destination: String) -> String {
        "![\(escapedAltText(altText))](\(destination))"
    }

    /// Obsidian stores image dimensions in the Markdown image label:
    /// `![alt|640](path)` or `![alt|640x480](path)`. A width alone preserves
    /// the image's aspect ratio. This deliberately supports the regular
    /// Markdown-link form, not vault-relative `![[...]]` embeds.
    public static func displaySize(in altText: String) -> DisplaySize {
        let ns = altText as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let match = obsidianSizeSuffix.firstMatch(in: altText, range: whole),
              match.range.location != NSNotFound else {
            return DisplaySize(altText: altText, width: nil, height: nil)
        }
        let width = Int(ns.substring(with: match.range(at: 2)))
        let heightRange = match.range(at: 3)
        let height = heightRange.location == NSNotFound
            ? nil : Int(ns.substring(with: heightRange))
        let labelRange = match.range(at: 1)
        let label = labelRange.location == NSNotFound ? "" : ns.substring(with: labelRange)
        return DisplaySize(altText: label, width: width, height: height)
    }

    /// Adds or replaces the Obsidian-compatible width suffix while preserving
    /// the rest of the Markdown image verbatim.
    public static func markdownBySettingWidth(_ markdown: String, width: Int) -> String? {
        let spans = SyntaxHighlighter.parse(markdown)
        guard let image = spans.first(where: {
            if case .image = $0.kind { return $0.fullRange == NSRange(location: 0, length: (markdown as NSString).length) }
            return false
        }) else { return nil }

        let ns = markdown as NSString
        let rawAlt = ns.substring(with: image.contentRange)
        let parsed = displaySize(in: rawAlt)
        let sizedAlt = parsed.altText.isEmpty ? "\(width)" : "\(parsed.altText)|\(width)"
        return ns.replacingCharacters(in: image.contentRange, with: sizedAlt)
    }

    public static func escapedAltText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// The clipboard name field starts with this editable prefix. Keeping the
    /// prefix is convenient, but it is ordinary text that the user may delete.
    public static func timestampPrefix(
        for date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_"
        return formatter.string(from: date)
    }

    public static func sanitizedImageBaseName(_ proposedName: String) -> String {
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".png") {
            name.removeLast(4)
        }
        let disallowed = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
        name = name.unicodeScalars.map { disallowed.contains($0) ? "-" : String($0) }.joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return "image" }
        return String(name.prefix(180))
    }

    /// Resolves a user-entered asset directory while keeping it underneath the
    /// Markdown file's directory. Invalid absolute or parent paths fall back to
    /// the lightweight default rather than escaping into an asset hierarchy.
    public static func normalizedAssetFolder(_ proposedFolder: String) -> String {
        let trimmed = proposedFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~") else { return "assets" }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != ".." }) else { return "assets" }
        let useful = components.filter { $0 != "." }
        return useful.isEmpty ? "assets" : useful.joined(separator: "/")
    }

    private static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private static let obsidianSizeSuffix = try! NSRegularExpression(
        // Group 1 is the semantic alt text. An all-numeric label is the
        // official no-alt shorthand (`![250](...)`). Otherwise a pipe is
        // required, so ordinary labels ending in digits remain ordinary alt.
        pattern: #"^(?:(.*)\|)?([1-9][0-9]*)(?:x([1-9][0-9]*))?$"#
    )
}
