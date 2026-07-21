// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit

// MARK: - Internal Link Following
//
// `[[wikilinks]]` and regular `[](dest)` links share one navigation core:
//   - `#heading`            → scroll to a heading in the current document,
//   - `path` / `path#head`  → resolve a file under the opened file's directory
//                             (a direct child, else a recursive search), open
//                             it, and scroll to the heading if one was named,
//   - external URL (scheme) → open in the default app (regular links only).
//
// Resolution needs only the opened file (its directory), not a vault folder.

/// Implemented by the owning document so a freshly opened document can be
/// scrolled to a heading after a cross-file link is followed.
@MainActor
public protocol HeadingNavigable: AnyObject {
    func navigateToHeading(_ heading: String)
}

extension EditorTextView {

    // MARK: Hit testing

    /// Whether a laid-out source character is visible link text. Edit mode
    /// keeps custom attributes instead of AppKit's `.link`, so NSTextView does
    /// not provide its usual pointing-hand cursor for us.
    func hasNavigableLink(atCharacterIndex index: Int) -> Bool {
        guard let storage = textStorage, index >= 0, index < storage.length else { return false }
        return storage.attribute(.editorWikiTarget, at: index, effectiveRange: nil) != nil
            || storage.attribute(.editorLinkURL, at: index, effectiveRange: nil) != nil
    }

    /// The wikilink target under a mouse event, or nil if the click doesn't land
    /// on wikilink display text.
    func wikiTarget(at event: NSEvent) -> String? {
        guard let storage = textStorage, let i = clickCharIndex(at: event) else { return nil }
        return storage.attribute(.editorWikiTarget, at: i, effectiveRange: nil) as? String
    }

    // MARK: Following

    /// Follows a `[[wikilink]]` target (`path#heading`, no scheme, `.md` implied).
    public func followWikiLink(_ target: String) {
        let (path, heading) = Self.splitHeading(target)
        if path.isEmpty {
            if let heading { scrollToWikiAnchor(heading) } else { NSSound.beep() }
            return
        }
        openLinkedFile(path: path, heading: heading)
    }

    /// Follows a regular markdown link destination: an external URL opens in the
    /// default app; `#heading` scrolls in-document; a local `path#heading`
    /// resolves a file and opens it (scrolling to the heading if named).
    public func followLinkDestination(_ destination: String) {
        let dest = destination.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: dest), let scheme = url.scheme, scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }
        // A markdown link destination is URL-encoded (e.g. `%20` for a space),
        // so decode both the path and the heading anchor.
        let (rawPath, rawHeading) = Self.splitHeading(dest)
        let path = rawPath.removingPercentEncoding ?? rawPath
        let heading = rawHeading.map { $0.removingPercentEncoding ?? $0 }
        if path.isEmpty {
            if let heading { scrollToWikiAnchor(heading) } else { NSSound.beep() }
            return
        }
        openLinkedFile(path: path, heading: heading)
    }

    /// Resolves `path` to a file and opens it, scrolling the opened document to
    /// `heading` when one is named (cross-file, via `HeadingNavigable`).
    private func openLinkedFile(path: String, heading: String?) {
        guard let fileURL = resolveLinkedFile(path) else { NSSound.beep(); return }
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in
            guard let heading else { return }
            // Re-find the document by URL on the main actor (the NSDocument
            // isn't Sendable, so we don't capture it across the boundary). By
            // now its content has loaded (showWindows → loadContent).
            Task { @MainActor in
                let doc = NSDocumentController.shared.document(for: fileURL)
                (doc as? HeadingNavigable)?.navigateToHeading(heading)
            }
        }
    }

    // MARK: Heading navigation

    /// Scrolls to the first heading block whose text matches `heading`
    /// (case-insensitive). Beeps if there is no such heading.
    public func scrollToHeading(_ heading: String) {
        guard let location = sourceLocation(forWikiAnchor: heading, blockIDs: false) else {
            NSSound.beep()
            return
        }
        navigateToSourceLocation(location)
    }

    /// Navigates a wikilink fragment: `heading` selects a heading while
    /// `^block-id` selects the block carrying that trailing metadata token.
    public func scrollToWikiAnchor(_ anchor: String) {
        guard let location = sourceLocation(forWikiAnchor: anchor, blockIDs: true) else {
            NSSound.beep()
            return
        }
        navigateToSourceLocation(location)
    }

    /// Original source line for a page-local wikilink target, used by Read
    /// mode to scroll its own web surface instead of the hidden editor.
    public func sourceLine(forPageLocalWikiTarget target: String) -> Int? {
        let (path, anchor) = Self.splitHeading(target)
        guard path.isEmpty, let anchor,
              let location = sourceLocation(forWikiAnchor: anchor, blockIDs: true) else { return nil }
        let prefix = (rawSource as NSString).substring(to: location)
        return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func navigateToSourceLocation(_ location: Int) {
        let target = NSRange(location: location, length: 0)
        setSelectedRange(target)
        scrollRangeToVisible(target)
    }

    private func sourceLocation(forWikiAnchor anchor: String, blockIDs: Bool) -> Int? {
        if blockIDs, anchor.hasPrefix("^") {
            guard markdownFeatures.contains(.blockID) else { return nil }
            let wanted = String(anchor.dropFirst()).lowercased()
            for block in blocks {
                let spans = SyntaxHighlighter.parse(block.content, features: markdownFeatures)
                if spans.contains(where: {
                    if case .blockID(let id) = $0.kind { return id.lowercased() == wanted }
                    return false
                }) {
                    return block.range.location
                }
            }
            return nil
        }

        let want = anchor.lowercased()
        return blocks.first(where: {
            guard case .heading = $0.kind else { return false }
            return Self.headingText($0.content).lowercased() == want
        })?.range.location
    }

    /// Visible heading text for either ATX (`# Title`) or setext
    /// (`Title\n---`) source. Closing ATX markers are omitted as Markdown
    /// presentation syntax, matching what the live preview displays.
    static func headingText(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        if lines.count > 1,
           let underline = lines.last?.trimmingCharacters(in: .whitespaces),
           !underline.isEmpty,
           underline.allSatisfy({ $0 == "=" }) || underline.allSatisfy({ $0 == "-" }) {
            return lines.dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var s = Substring(source)
        while s.first == "#" { s = s.dropFirst() }
        var title = s.trimmingCharacters(in: .whitespaces)
        if let closing = title.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
            title.removeSubrange(closing)
        } else if title.allSatisfy({ $0 == "#" }) {
            title = ""
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Splits `path#heading` (or `#heading`, or `path`) into a path and the
    /// deepest heading component (so `Note#H1#H2` targets `H2`). A nil heading
    /// means none was named.
    static func splitHeading(_ s: String) -> (path: String, heading: String?) {
        let ns = s as NSString
        let hash = ns.range(of: "#")
        guard hash.location != NSNotFound else {
            return (s.trimmingCharacters(in: .whitespaces), nil)
        }
        let path = ns.substring(to: hash.location).trimmingCharacters(in: .whitespaces)
        let rest = ns.substring(from: hash.upperBound)
        let heading = rest.split(separator: "#").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return (path, heading)
    }

    // MARK: File resolution

    /// Resolves a link `path` to a file URL. Absolute / `~` / `file:` paths load
    /// directly; otherwise it resolves under the opened file's directory — a
    /// direct child first, else a recursive search by filename — appending `.md`
    /// when the path has no extension (Obsidian-style wikilinks omit it).
    func resolveLinkedFile(_ path: String) -> URL? {
        if let url = URL(string: path), url.scheme == "file" { return url }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

        guard let docDir = document?.fileURL?.deletingLastPathComponent() else { return nil }
        let fm = FileManager.default
        let rel = (path as NSString).pathExtension.isEmpty ? path + ".md" : path

        let direct = docDir.appendingPathComponent(rel)
        if fm.fileExists(atPath: direct.path) { return direct }

        // Recursive search by the link's filename (Obsidian resolves by name).
        let wantName = (rel as NSString).lastPathComponent.lowercased()
        if let walker = fm.enumerator(at: docDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent.lowercased() == wantName {
                return url
            }
        }
        return nil
    }
}
