// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation
import Markdown

// MARK: - Custom Parsers
//
// Regex / scan-based passes for inline constructs that swift-markdown does not
// model. Each appends to the span list built by the AST walker (see parse()):
//
//   - parseHighlight        ==text==
//   - parseDisplayMath       $$\u{2026}$$ (block pre-merged by BlockParser)
//   - parseMath              $\u{2026}$ (Pandoc-style disambiguation)
//   - parseLineBreak         trailing backslash hard break
//   - parseIndentedListItem  4+ space list items swift-markdown treats as code

extension SyntaxHighlighter {

    private static let footnoteDefRegex =
        try! NSRegularExpression(pattern: #"^\[\^([^\]\s]+)\]:"#)
    private static let footnoteRefRegex =
        try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)

    /// Parses footnotes (not supported by swift-markdown):
    ///   - `[^id]:` at the start of a block → a `.footnoteDefinition` marker.
    ///   - `[^id]` elsewhere → a `.footnoteReference`.
    static func parseFootnotes(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        // Definition marker at the very start of the block: `[^id]:`.
        if let m = footnoteDefRegex.firstMatch(in: text, range: whole) {
            let marker = m.range(at: 0)   // includes the trailing ":"
            spans.append(Span(
                kind: .footnoteDefinition(id: ns.substring(with: m.range(at: 1))),
                fullRange: marker,
                contentRange: m.range(at: 1),
                delimiterRanges: [marker]))
        }

        // References `[^id]` anywhere — except the definition marker (followed by
        // ":") and anything overlapping a code span or the definition above.
        for m in footnoteRefRegex.matches(in: text, range: whole) {
            let full = m.range(at: 0)
            if full.upperBound < ns.length && ns.character(at: full.upperBound) == 0x3A { continue }
            let overlaps = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock, .footnoteDefinition: break
                default: return false
                }
                return existing.fullRange.location <= full.location
                    && existing.fullRange.upperBound >= full.upperBound
            }
            guard !overlaps else { continue }
            spans.append(Span(
                kind: .footnoteReference(id: ns.substring(with: m.range(at: 1))),
                fullRange: full,
                contentRange: m.range(at: 1),                                   // the id
                delimiterRanges: [NSRange(location: full.location, length: 2),  // "[^"
                                  NSRange(location: full.upperBound - 1, length: 1)]))  // "]"
        }
    }

    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=\s))#([\p{L}\p{M}\p{N}_/-]*[\p{L}\p{M}_/-][\p{L}\p{M}\p{N}_/-]*)"#
    )

    /// Parses Obsidian tags at a line/whitespace boundary. Tags may be nested
    /// with `/`, may contain Unicode letters, and must contain at least one
    /// non-digit so `#123` remains literal and `# heading` remains an ATX marker.
    static func parseTags(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for match in tagRegex.matches(in: text, range: whole) {
            let full = match.range(at: 0)
            let enclosedByOpaqueSyntax = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock, .math, .link, .image, .wikilink, .comment:
                    return existing.fullRange.location <= full.location
                        && existing.fullRange.upperBound >= full.upperBound
                default:
                    return false
                }
            }
            guard !enclosedByOpaqueSyntax else { continue }
            spans.append(Span(
                kind: .tag(name: ns.substring(with: match.range(at: 1))),
                fullRange: full,
                contentRange: full,
                delimiterRanges: []
            ))
        }
    }

    private static let blockIDRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)(\^[\p{L}\p{M}\p{N}-]+)[ \t]*$"#
    )

    /// Parses a trailing Obsidian block ID. The token is source metadata: it is
    /// dimmed while editing and hidden in rendered Edit/Read presentations.
    static func parseBlockID(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let match = blockIDRegex.firstMatch(in: text, range: whole) else { return }
        let token = match.range(at: 1)
        let enclosedByOpaqueSyntax = spans.contains { existing in
            switch existing.kind {
            case .code, .codeBlock, .math, .link, .image, .wikilink, .comment:
                return existing.fullRange.location <= token.location
                    && existing.fullRange.upperBound >= token.upperBound
            default:
                return false
            }
        }
        guard !enclosedByOpaqueSyntax else { return }
        spans.append(Span(
            kind: .blockID(id: ns.substring(with: NSRange(
                location: token.location + 1,
                length: token.length - 1
            ))),
            fullRange: token,
            contentRange: NSRange(location: token.location, length: 0),
            delimiterRanges: [token]
        ))
    }

    private static let commentRegex =
        try! NSRegularExpression(pattern: "%%([\\s\\S]*?)%%", options: [])

    /// Parses Obsidian-style `%%comment%%` spans (not supported by
    /// swift-markdown). Matches across newlines within a block; skips `%%`
    /// inside code spans / code blocks.
    static func parseComments(
        _ text: String, into spans: inout [Span], features: MarkdownFeatures = .all
    ) {
        let ns = text as NSString
        for m in commentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let full = m.range(at: 0)
            let multiline = ns.substring(with: full).contains("\n")
            guard (multiline && features.contains(.multiBlockComment))
                    || (!multiline && features.contains(.inlineComment)) else { continue }
            let overlaps = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock: break
                default: return false
                }
                return existing.fullRange.location <= full.location
                    && existing.fullRange.upperBound >= full.upperBound
            }
            guard !overlaps else { continue }
            spans.append(Span(
                kind: .comment,
                fullRange: full,
                contentRange: m.range(at: 1),
                delimiterRanges: [NSRange(location: full.location, length: 2),
                                  NSRange(location: full.upperBound - 2, length: 2)]))
        }
    }

    private static let htmlCommentRegex =
        try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")

    /// Parses HTML `<!-- comment -->` spans into the same `.comment` kind as
    /// `%%…%%` (dimmed in edit mode, hidden in reading view; inner spans are
    /// dropped by the opaque-range pass). Skips comments inside code / math.
    static func parseHTMLComments(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        for m in htmlCommentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let full = m.range(at: 0)
            let overlaps = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock, .math: break
                default: return false
                }
                return existing.fullRange.location <= full.location
                    && existing.fullRange.upperBound >= full.upperBound
            }
            guard !overlaps else { continue }
            spans.append(Span(
                kind: .comment,
                fullRange: full,
                contentRange: NSRange(location: full.location + 4, length: full.length - 7),
                delimiterRanges: [NSRange(location: full.location, length: 4),
                                  NSRange(location: full.upperBound - 3, length: 3)]))
        }
    }

    private static let wikiLinkRegex =
        try! NSRegularExpression(pattern: #"(!)?\[\[([^\[\]\n]+?)\]\]"#)
    private static let embeddedImageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"
    ]

    /// Parses Obsidian-style `[[target]]`, `[[target#heading]]`, and
    /// `[[target|alias]]` internal links. The span's `contentRange` is the
    /// visible display text (the alias when present, else the target); the
    /// `[[`, an optional `target|`, and the `]]` are delimiter ranges hidden
    /// when rendered. Skips `[[` inside code spans / code blocks.
    static func parseWikiLinks(_ text: String, into spans: inout [Span],
                               features: MarkdownFeatures = .all) {
        let ns = text as NSString
        for m in wikiLinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let full = m.range(at: 0)
            let bang = m.range(at: 1)
            let inner = m.range(at: 2)
            let innerNS = ns.substring(with: inner) as NSString
            guard innerNS.length > 0 else { continue }
            let overlaps = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock: break
                default: return false
                }
                return existing.fullRange.location <= full.location
                    && existing.fullRange.upperBound >= full.upperBound
            }
            guard !overlaps else { continue }

            let isEmbed = bang.location != NSNotFound
            if isEmbed {
                // Phase 2 classifies image and non-image embeds. Until that
                // semantic span is appended, do not let `![[...]]` degrade into
                // a clickable wikilink or consume the leading exclamation mark.
                guard features.contains(.wikilinkEmbed) else { continue }
            } else {
                guard features.contains(.wikilink) else { continue }
            }

            // Split target | alias on the first "|".
            let pipe = innerNS.range(of: "|")
            let targetRel = pipe.location == NSNotFound
                ? NSRange(location: 0, length: innerNS.length)
                : NSRange(location: 0, length: pipe.location)
            var displayRel = pipe.location == NSNotFound
                ? targetRel
                : NSRange(location: pipe.upperBound, length: innerNS.length - pipe.upperBound)
            if displayRel.length == 0 { displayRel = targetRel }   // "[[Note|]]" → show target

            let target = innerNS.substring(with: targetRel).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty || pipe.location != NSNotFound else { continue }

            let content = NSRange(location: inner.location + displayRel.location, length: displayRel.length)
            let leading = NSRange(location: full.location, length: content.location - full.location)
            let trailing = NSRange(location: content.upperBound, length: full.upperBound - content.upperBound)
            if isEmbed {
                let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
                if embeddedImageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                    let dimensions = features.contains(.imageDimensions)
                        ? parseEmbeddedImageDimensions(innerNS, pipe: pipe) : (nil, nil)
                    spans.append(Span(
                        kind: .image(destination: target, width: dimensions.0, height: dimensions.1),
                        fullRange: full,
                        contentRange: content,
                        delimiterRanges: [leading, trailing]))
                } else {
                    spans.append(Span(
                        kind: .embed(target: target, kind: .classify(target: target)),
                        fullRange: full,
                        contentRange: content,
                        delimiterRanges: [leading, trailing]))
                }
                continue
            }
            spans.append(Span(
                kind: .wikilink(target: target),
                fullRange: full,
                contentRange: content,
                delimiterRanges: [leading, trailing]))
        }
    }

    private static func parseEmbeddedImageDimensions(
        _ inner: NSString, pipe: NSRange
    ) -> (Int?, Int?) {
        guard pipe.location != NSNotFound, pipe.upperBound < inner.length else { return (nil, nil) }
        let raw = inner.substring(from: pipe.upperBound).trimmingCharacters(in: .whitespaces)
        let pieces = raw.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard let width = Int(pieces[0]), width > 0 else { return (nil, nil) }
        if pieces.count == 1 { return (width, nil) }
        guard pieces.count == 2, let height = Int(pieces[1]), height > 0 else { return (nil, nil) }
        return (width, height)
    }

    /// Parses ==highlight== spans using regex (not supported by swift-markdown).
    /// GFM-style flanking: the content must not begin or end with whitespace
    /// (`== spaced ==` stays literal), matching how cmark treats `**`/`~~`.
    static func parseHighlight(_ text: String, into spans: inout [Span]) {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "==(?!\\s)(.+?)(?<!\\s)==", options: []) else { return }
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            // Skip if overlapping with a code span
            let overlaps = spans.contains { existing in
                existing.kind == .code &&
                existing.fullRange.location <= full.location &&
                existing.fullRange.upperBound >= full.upperBound
            }
            guard !overlaps else { continue }
            let openDelim = NSRange(location: full.location, length: 2)
            let closeDelim = NSRange(location: full.upperBound - 2, length: 2)
            spans.append(Span(
                kind: .highlight,
                fullRange: full,
                contentRange: content,
                delimiterRanges: [openDelim, closeDelim]
            ))
        }
    }

    /// Scans for `$$…$$` display math runs. A run can own its whole block
    /// (`BlockParser` merges a multi-line `$$ … $$` into one block, so content
    /// may span newlines) or sit inline within a prose line (`text $$x$$ more`).
    ///
    /// Tightness (space/tab, NOT newline) guards against prose false positives
    /// like "pay $$5 and $$6": a `$$` delimiter must abut non-space on the inner
    /// side — mirrors the Pandoc rule in `parseMath`. Newlines are allowed so a
    /// block-merged `$$\n … \n$$` still matches. Runs before `parseMath`, which
    /// skips ranges inside a `.math(display: true)` span.
    static func parseDisplayMath(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let n = ns.length
        let dollar: unichar = 0x24, backslash: unichar = 0x5C

        // Same-line whitespace only; newlines are legal inside a display block.
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == backslash { i += 2; continue }   // skip escaped char
            // Opening `$$`, abutting a non-space on its inner side.
            guard c == dollar, i + 1 < n, ns.character(at: i + 1) == dollar else { i += 1; continue }
            let afterOpen = i + 2
            guard afterOpen < n, !isSpace(ns.character(at: afterOpen)) else { i += 1; continue }

            // Find the closing `$$`, abutting a non-space on its inner side.
            var j = afterOpen
            var closeLoc = -1
            while j + 1 < n {
                let cj = ns.character(at: j)
                if cj == backslash { j += 2; continue }
                if cj == dollar && ns.character(at: j + 1) == dollar {
                    if !isSpace(ns.character(at: j - 1)) { closeLoc = j; break }
                    j += 2; continue      // `$$` preceded by space isn't a valid close
                }
                j += 1
            }
            guard closeLoc > afterOpen else { i += 2; continue }  // no close / empty content

            let full = NSRange(location: i, length: closeLoc + 2 - i)
            // `$$…$$` inside inline or fenced code is literal source, not math.
            // The AST spans are already present when this custom parser runs.
            let inCode = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock:
                    return existing.fullRange.location <= full.location
                        && existing.fullRange.upperBound >= full.upperBound
                default:
                    return false
                }
            }
            if !inCode {
                spans.append(Span(
                    kind: .math(display: true),
                    fullRange: full,
                    contentRange: NSRange(location: afterOpen, length: closeLoc - afterOpen),
                    delimiterRanges: [NSRange(location: i, length: 2),
                                      NSRange(location: closeLoc, length: 2)]
                ))
            }
            i = closeLoc + 2
        }
    }

    /// Scans for inline `$…$` math. Uses Pandoc-style disambiguation so prose
    /// like "it cost $5 to $10" is left alone:
    ///   - the opening `$` is immediately followed by a non-space, non-`$` char,
    ///   - the closing `$` is immediately preceded by a non-space char and is
    ///     not followed by a digit,
    ///   - `\$` is a literal escape, `$$` is skipped (display math, later phase),
    ///   - inline math never spans a newline.
    static func parseMath(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let n = ns.length
        let dollar: unichar = 0x24, backslash: unichar = 0x5C, newline: unichar = 0x0A

        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == backslash { i += 2; continue }   // skip escaped char
            if c != dollar { i += 1; continue }
            // Skip display `$$` (handled per-block in a later phase).
            if i + 1 < n && ns.character(at: i + 1) == dollar { i += 2; continue }
            // Opening `$`: must be followed by a non-space, non-`$` character.
            guard i + 1 < n else { break }
            let next = ns.character(at: i + 1)
            if isSpace(next) || next == dollar || next == newline { i += 1; continue }

            // Find the closing `$`.
            var j = i + 1
            var close = -1
            while j < n {
                let cj = ns.character(at: j)
                if cj == backslash { j += 2; continue }
                if cj == newline { break }           // inline math stays on one line
                if cj == dollar {
                    let prev = ns.character(at: j - 1)
                    let isDouble = j + 1 < n && ns.character(at: j + 1) == dollar
                    let nextIsDigit = j + 1 < n && isDigit(ns.character(at: j + 1))
                    if !isDouble && !isSpace(prev) && !nextIsDigit { close = j; break }
                }
                j += 1
            }

            guard close > i + 1 else { i += 1; continue }

            let full = NSRange(location: i, length: close - i + 1)
            // Don't match inside code spans or a display-math block.
            let overlaps = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock, .math(display: true):
                    return existing.fullRange.location <= full.location
                        && existing.fullRange.upperBound >= full.upperBound
                default:
                    return false
                }
            }
            if !overlaps {
                spans.append(Span(
                    kind: .math(display: false),
                    fullRange: full,
                    contentRange: NSRange(location: i + 1, length: close - i - 1),
                    delimiterRanges: [NSRange(location: i, length: 1),
                                      NSRange(location: close, length: 1)]
                ))
            }
            i = close + 1
        }
    }

    /// The set of ASCII-punctuation characters CommonMark allows a backslash to
    /// escape (§2.4). A `\` before any other character is a literal backslash.
    private static let escapableChars: Set<unichar> = {
        let punct = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        return Set((punct as NSString).description.utf16)
    }()

    /// Parses CommonMark backslash escapes: a `\` followed by an escapable
    /// punctuation char. The backslash becomes the span's hidden/dimmed
    /// delimiter; the escaped char renders literally (swift-markdown already
    /// strips the escape from the AST text, so no inline span double-styles it).
    /// Skips escapes inside code / math / a trailing-`\` line break so those keep
    /// their raw source (e.g. `\,` inside `$…$` stays a LaTeX command).
    static func parseEscapes(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let n = ns.length
        let backslash: unichar = 0x5C
        var i = 0
        while i < n - 1 {
            guard ns.character(at: i) == backslash,
                  escapableChars.contains(ns.character(at: i + 1)) else { i += 1; continue }
            let full = NSRange(location: i, length: 2)
            let overlaps = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock, .math, .lineBreak:
                    return existing.fullRange.location <= full.location
                        && existing.fullRange.upperBound >= full.upperBound
                default:
                    return false
                }
            }
            if !overlaps {
                spans.append(Span(
                    kind: .escape,
                    fullRange: full,
                    contentRange: NSRange(location: i + 1, length: 1),
                    delimiterRanges: [NSRange(location: i, length: 1)]))
            }
            // Consume both chars so `\\` is one escape (and the 2nd `\` can't
            // start another escape or be read as a trailing line break).
            i += 2
        }
    }

    /// Whitelisted HTML formatting tags rendered (not just colored). The inner
    /// content keeps its own markdown styling. Built from `htmlFormatTags` so the
    /// Edit and Read whitelists share one source of truth.
    /// Known ceiling: the open tag's attr swallow `(?:\s[^>]*)?` breaks on a `>`
    /// inside a quoted attribute of a whitelist pair open tag — the pair then
    /// falls back to two colored `.htmlTag` tokens (acceptable).
    private static let htmlPairRegex: NSRegularExpression = {
        let names = htmlFormatTags.sorted().joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "<(\(names))(?:\\s[^>]*)?>(.*?)</\\1\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    /// Any single inline HTML tag per GFM §6.10: an open tag (group 1 = name,
    /// full attribute grammar — names may contain hyphens, attribute values may
    /// be double-quoted, single-quoted, or unquoted, and quoted values may
    /// contain `>`), or a closing tag (group 2 = name; no attributes allowed).
    private static let htmlTagRegex = try! NSRegularExpression(pattern:
        #"<(?:([A-Za-z][A-Za-z0-9-]*)(?:\s+[a-zA-Z_:][a-zA-Z0-9:._-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?|/([A-Za-z][A-Za-z0-9-]*)\s*)>"#)

    /// §6.10 processing instructions `<?…?>`, declarations `<!NAME …>`, and
    /// CDATA `<![CDATA[…]]>` — shown as dimmed source. HTML comments are handled
    /// (more laxly than spec — interior `--` allowed, deliberate divergence) by
    /// parseHTMLComments, which runs first.
    private static let htmlOtherRegex = try! NSRegularExpression(
        pattern: #"<\?[\s\S]*?\?>|<![A-Z]+\s+[^>]*>|<!\[CDATA\[[\s\S]*?\]\]>"#)

    // `<img>` attribute extractors — double-, single-, and unquoted values
    // (§6.10). Exactly one of groups 1–3 participates per match. Shared with the
    // read-mode renderer so both back-ends accept the same tags.
    static let imgSrcRegex = try! NSRegularExpression(
        pattern: #"\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: [.caseInsensitive])
    static let imgAltRegex = try! NSRegularExpression(
        pattern: #"\salt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: [.caseInsensitive])
    static let imgWidthRegex = try! NSRegularExpression(
        pattern: #"\swidth\s*=\s*(?:"(\d+)"|'(\d+)'|(\d+))"#, options: [.caseInsensitive])
    static let imgHeightRegex = try! NSRegularExpression(
        pattern: #"\sheight\s*=\s*(?:"(\d+)"|'(\d+)'|(\d+))"#, options: [.caseInsensitive])

    /// The matched value range: whichever of groups 1–3 participated.
    static func attrValueRange(_ m: NSTextCheckingResult) -> NSRange {
        for i in 1...3 where m.range(at: i).location != NSNotFound { return m.range(at: i) }
        return m.range(at: 0)
    }

    /// Parses inline HTML tags. Two tiers:
    ///   - a whitelisted pair (`<u>…</u>`, `<kbd>`, `<mark>`, `<sub>`, `<sup>`)
    ///     becomes a `.htmlFormat` span whose tags hide and whose content takes a
    ///     rendered attribute;
    ///   - any other recognized tag becomes a `.htmlTag` span shown as colored
    ///     source (the open/close tags of a pair are not re-emitted).
    /// Skips tags inside code / math, and a `\<`-escaped `<` (escapes run first).
    static func parseHTMLTags(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        // True if `r` sits inside a code/math span, or its `<` is an escaped `\<`.
        func guarded(_ r: NSRange) -> Bool {
            for span in spans {
                switch span.kind {
                case .code, .codeBlock, .math:
                    if span.fullRange.location <= r.location
                        && span.fullRange.upperBound >= r.upperBound { return true }
                case .escape:
                    // The escape covers `\` + the escaped char; reject if it
                    // covers this tag's opening `<`.
                    if span.fullRange.location <= r.location
                        && span.fullRange.upperBound > r.location { return true }
                default:
                    break
                }
            }
            return false
        }

        // Pass 1: whitelist pairs render. Remember each pair's tag ranges so the
        // generic pass doesn't re-emit them (inner tags are still colored).
        var pairTagRanges: [NSRange] = []
        for m in htmlPairRegex.matches(in: text, range: whole) {
            let full = m.range(at: 0)
            guard !guarded(full) else { continue }
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let content = m.range(at: 2)
            let openTag = NSRange(location: full.location, length: content.location - full.location)
            let closeTag = NSRange(location: content.upperBound, length: full.upperBound - content.upperBound)
            spans.append(Span(kind: .htmlFormat(tag: name), fullRange: full,
                              contentRange: content, delimiterRanges: [openTag, closeTag]))
            pairTagRanges.append(openTag)
            pairTagRanges.append(closeTag)
        }

        // Pass 2: any other recognized tag → colored source.
        for m in htmlTagRegex.matches(in: text, range: whole) {
            let full = m.range(at: 0)
            guard !guarded(full) else { continue }
            if pairTagRanges.contains(where: {
                $0.location <= full.location && $0.upperBound >= full.upperBound
            }) { continue }
            // Group 1 = open-tag name, group 2 = closing-tag name.
            let nameR = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)

            // `<img src="…">` renders as an inline image (like `![](…)`),
            // optionally at declared pixel dimensions. Without a src the tag
            // stays colored source.
            if ns.substring(with: nameR).lowercased() == "img",
               let srcM = imgSrcRegex.firstMatch(in: text, range: full) {
                func intAttr(_ regex: NSRegularExpression) -> Int? {
                    regex.firstMatch(in: text, range: full)
                        .map { ns.substring(with: attrValueRange($0)) }.flatMap(Int.init)
                }
                spans.append(Span(
                    kind: .image(destination: ns.substring(with: attrValueRange(srcM)),
                                 width: intAttr(imgWidthRegex),
                                 height: intAttr(imgHeightRegex)),
                    fullRange: full,
                    contentRange: attrValueRange(srcM),
                    delimiterRanges: []))
                continue
            }
            let pre = NSRange(location: full.location, length: nameR.location - full.location)
            let post = NSRange(location: nameR.upperBound, length: full.upperBound - nameR.upperBound)
            spans.append(Span(kind: .htmlTag, fullRange: full, contentRange: nameR,
                              delimiterRanges: [pre, post]))
        }

        // Pass 3: PI / declaration / CDATA → dimmed source. Zero-length content +
        // full-range delimiter ⇒ the whole token dims (like a comment); tokens
        // inside a real <!-- comment --> are dropped by the opaque-range pass.
        for m in htmlOtherRegex.matches(in: text, range: whole) {
            let full = m.range(at: 0)
            guard !guarded(full) else { continue }
            spans.append(Span(kind: .htmlTag, fullRange: full,
                              contentRange: NSRange(location: full.location, length: 0),
                              delimiterRanges: [full]))
        }
    }

    // GFM autolinks extension. Group 1 is the allowed preceding character
    // (start of text, whitespace, or `*`/`_`/`~`/`(`); group 2 the candidate:
    // a scheme/www URL run or an email. Trailing punctuation, unbalanced `)`,
    // and `&entity;` suffixes are trimmed in code afterwards, then the domain
    // is validated (≥1 dot, no `_` in the last two labels).
    private static let autolinkRegex = try! NSRegularExpression(
        pattern: #"(^|[\s*_~(])((?:https?://|www\.)[^\s<]+|[A-Za-z0-9._+-]+@[A-Za-z0-9._-]+)"#,
        options: [.caseInsensitive])

    /// Parses bare `www.…`/`http(s)://…`/`user@host` autolinks per the GFM
    /// autolinks extension (swift-markdown doesn't attach cmark's). Emits
    /// `.link` spans with no delimiters (the whole match is content). Skips
    /// candidates inside code, math, comments, wikilinks, real links/images,
    /// and HTML tags. Must run after every other pass.
    static func parseAutolinks(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString

        func isTrimPunct(_ c: unichar) -> Bool {
            // ? ! . , : * _ ~ ' "
            switch c {
            case 0x3F, 0x21, 0x2E, 0x2C, 0x3A, 0x2A, 0x5F, 0x7E, 0x27, 0x22: return true
            default: return false
            }
        }
        func isAlnum(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
        }

        // GFM trailing trim: strip punctuation, a `)` only while the match's
        // parens are unbalanced, and a trailing `&entity;`.
        func trimmedEnd(from start: Int, to initialEnd: Int) -> Int {
            var end = initialEnd
            loop: while end > start {
                let c = ns.character(at: end - 1)
                if isTrimPunct(c) { end -= 1; continue }
                if c == 0x29 {   // ")"
                    var opens = 0, closes = 0
                    for i in start..<end {
                        let ch = ns.character(at: i)
                        if ch == 0x28 { opens += 1 } else if ch == 0x29 { closes += 1 }
                    }
                    if closes > opens { end -= 1; continue }
                    break
                }
                if c == 0x3B {   // ";" — strip a `&word;` entity-like suffix
                    var i = end - 2
                    while i >= start, isAlnum(ns.character(at: i)) { i -= 1 }
                    if i >= start, ns.character(at: i) == 0x26, i < end - 2 {  // "&" + 1+ alnum + ";"
                        end = i
                        continue loop
                    }
                    break
                }
                break
            }
            return end
        }

        /// GFM valid domain: `.`-separated labels of alphanumerics/`-`/`_`,
        /// at least two labels, no `_` in the last two.
        func isValidDomain(_ domain: Substring) -> Bool {
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2 else { return false }
            for label in labels {
                guard !label.isEmpty,
                      label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
                else { return false }
            }
            return !labels.suffix(2).contains { $0.contains("_") }
        }

        for m in autolinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let candidate = m.range(at: 2)
            let end = trimmedEnd(from: candidate.location, to: candidate.upperBound)
            guard end > candidate.location else { continue }
            let full = NSRange(location: candidate.location, length: end - candidate.location)
            let match = ns.substring(with: full)

            let destination: String
            if match.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil {
                let afterScheme = match[match.range(of: "://")!.upperBound...]
                guard isValidDomain(afterScheme.prefix {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
                }) else { continue }
                destination = match
            } else if match.lowercased().hasPrefix("www.") {
                guard isValidDomain(match.prefix(while: {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
                })) else { continue }
                destination = "http://" + match
            } else {
                // Email: needs text before the `@`, a valid domain after it,
                // and the last character can't be `-` or `_`.
                guard let at = match.firstIndex(of: "@"), at != match.startIndex,
                      isValidDomain(match[match.index(after: at)...]),
                      match.last != "-", match.last != "_"
                else { continue }
                destination = "mailto:" + match
            }

            let overlapsExisting = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock, .math, .comment, .wikilink,
                     .link, .image, .htmlTag, .htmlFormat:
                    return existing.fullRange.location < full.upperBound
                        && existing.fullRange.upperBound > full.location
                default:
                    return false
                }
            }
            guard !overlapsExisting else { continue }

            spans.append(Span(
                kind: .link(destination: destination),
                fullRange: full,
                contentRange: full,
                delimiterRanges: []))
        }
    }

    /// Parses trailing `\` as a line break indicator.
    static func parseLineBreak(_ text: String, into spans: inout [Span]) {
        let nsText = text as NSString
        let len = nsText.length
        guard len > 0 else { return }
        // Must not contain \n (only applies to single-line blocks)
        guard !text.contains("\n") else { return }
        let lastChar = nsText.character(at: len - 1)
        guard lastChar == 0x5C else { return }  // backslash
        // Not an escaped backslash (\\)
        if len >= 2 && nsText.character(at: len - 2) == 0x5C { return }
        let range = NSRange(location: len - 1, length: 1)
        spans.append(Span(
            kind: .lineBreak,
            fullRange: range,
            contentRange: NSRange(location: len - 1, length: 0),
            delimiterRanges: [range]
        ))
    }

    /// Detects list items with deep indentation (4+ spaces or tabs) that
    /// swift-markdown parses as indented code instead of list items. Group 2 is
    /// the marker — an unordered bullet (`-`/`*`/`+`) or an ordered number
    /// (`1.`/`1)`), so nested ordered lists are rescued too.
    static let indentedListRegex = try! NSRegularExpression(
        pattern: #"^([\t ]*\t[\t ]*|[ ]{4,})([-*+]|\d{1,9}[.)])\s"#
    )

    /// Matches a GFM task-list checkbox at the start of list-item content:
    /// "[ ] ", "[x] ", or "[X] ". Capture group 1 is the state character.
    static let checkboxRegex = try! NSRegularExpression(
        pattern: #"^\[([ xX])\]\s"#
    )

    /// An in-progress ordered item containing only its marker and trailing
    /// whitespace. CommonMark accepts bare `1.` but swift-markdown drops the
    /// span as soon as the first space is typed, which makes the editor leave
    /// list layout for one keystroke before re-entering when content arrives.
    static let emptyOrderedListRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\d{1,9}[.)][ \t]+$"#
    )

    static func parseEmptyOrderedListItem(_ text: String, into spans: inout [Span]) {
        guard !text.contains("\n") else { return }
        let nsText = text as NSString
        guard emptyOrderedListRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ) != nil else { return }
        guard !spans.contains(where: {
            if case .listItem = $0.kind { return true }
            return false
        }) else { return }

        let full = NSRange(location: 0, length: nsText.length)
        spans.append(Span(
            kind: .listItem(ordered: true, checkbox: nil),
            fullRange: full,
            contentRange: NSRange(location: full.upperBound, length: 0),
            delimiterRanges: [full]
        ))
    }

    static func parseIndentedListItem(_ text: String, into spans: inout [Span]) {
        let nsText = text as NSString
        let match = indentedListRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        )
        guard let match = match else { return }
        // Don't duplicate if swift-markdown already found a listItem
        let alreadyHasListItem = spans.contains {
            if case .listItem = $0.kind { return true }
            return false
        }
        guard !alreadyHasListItem else { return }

        // BlockParser may merge explicitly indented physical continuation
        // lines into this deeply nested item. swift-markdown sees the whole
        // block as indented code, so the rescue span must cover every merged
        // line rather than only the marker line.
        let full = NSRange(location: 0, length: nsText.length)
        let markerEnd = match.range(at: 0).upperBound  // end of "    - "

        // An ordered marker (1./1)) starts with a digit; a bullet (-/*/+) doesn't.
        let marker = nsText.substring(with: match.range(at: 2))
        let ordered = marker.first?.isNumber ?? false

        // Detect a GFM task-list checkbox following the marker ("[ ] "/"[x] ").
        // swift-markdown skips these on deeply-indented lines (it treats the
        // whole line as code), so we parse the checkbox ourselves — otherwise
        // task items nested beyond level 2 render without a circle. Only the
        // unordered `- [ ]` form is supported.
        var checkbox: Span.Kind.CheckboxState? = nil
        var delimEnd = markerEnd
        if !ordered {
            let afterMarker = nsText.substring(from: markerEnd) as NSString
            if let cb = checkboxRegex.firstMatch(
                in: afterMarker as String,
                range: NSRange(location: 0, length: afterMarker.length)
            ) {
                let stateChar = afterMarker.substring(with: cb.range(at: 1))
                checkbox = (stateChar == "x" || stateChar == "X") ? .checked : .unchecked
                delimEnd = markerEnd + cb.range(at: 0).length
            }
        }

        let delim = NSRange(location: 0, length: delimEnd)
        let content = NSRange(location: delimEnd, length: nsText.length - delimEnd)

        // Remove any codeBlock span swift-markdown created for this indented line
        spans.removeAll { span in
            if case .codeBlock = span.kind { return true }
            return false
        }

        spans.append(Span(
            kind: .listItem(ordered: ordered, checkbox: checkbox),
            fullRange: full,
            contentRange: content,
            delimiterRanges: [delim]
        ))

        // Re-parse the content for inline formatting (bold, italic, code, etc.)
        // since swift-markdown treated the whole line as code and skipped them.
        let contentStr = nsText.substring(with: content)
        let inlineSpans = parse(contentStr)
        for s in inlineSpans {
            // Skip any listItem spans from the recursive parse
            if case .listItem = s.kind { continue }
            // Offset ranges by the content start position
            let offsetFull = NSRange(location: s.fullRange.location + content.location,
                                     length: s.fullRange.length)
            let offsetContent = NSRange(location: s.contentRange.location + content.location,
                                        length: s.contentRange.length)
            let offsetDelims = s.delimiterRanges.map {
                NSRange(location: $0.location + content.location, length: $0.length)
            }
            spans.append(Span(kind: s.kind, fullRange: offsetFull,
                              contentRange: offsetContent,
                              delimiterRanges: offsetDelims))
        }
    }
}
