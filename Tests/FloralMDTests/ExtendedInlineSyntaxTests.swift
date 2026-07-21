// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation
import Testing
@testable import FloralMDCore

@Suite("Extended inline Markdown")
struct ExtendedInlineSyntaxTests {
    @Test("Tags require a boundary and a non-numeric name")
    func tags() {
        let spans = SyntaxHighlighter.parse("#project/FloralMD #123 word#no")
        #expect(spans.contains { $0.kind == .tag(name: "project/FloralMD") })
        #expect(!spans.contains { $0.kind == .tag(name: "123") })
        #expect(!spans.contains { $0.kind == .tag(name: "no") })
    }

    @Test("A trailing block ID is metadata and is hidden in Read")
    func blockID() {
        let source = "Paragraph ^stable-id"
        #expect(SyntaxHighlighter.parse(source).contains { $0.kind == .blockID(id: "stable-id") })
        let html = HTMLRenderer.render(markdown: source)
        #expect(html.contains("Paragraph"))
        #expect(!html.contains("stable-id"))
    }

    @Test("Non-image wikilink embeds are labels, not links or images")
    func nonImageEmbed() {
        let spans = SyntaxHighlighter.parse("![[Document.pdf]]")
        #expect(spans.contains { $0.kind == .embed(target: "Document.pdf", kind: .pdf) })
        #expect(!spans.contains {
            if case .wikilink = $0.kind { return true }
            return false
        })
        #expect(HTMLRenderer.render(markdown: "![[Document.pdf]]")
            .contains("class=\"embed-label embed-label-pdf\""))
    }

    @Test("Non-image attachments classify PDF, audio, video, notes, and unknown files")
    func attachmentKinds() {
        let fixtures: [(source: String, target: String, kind: AttachmentKind)] = [
            ("![[Document.pdf]]", "Document.pdf", .pdf),
            ("![[recording.MP3]]", "recording.MP3", .audio),
            ("![[clip.mov]]", "clip.mov", .video),
            ("![[Meeting notes]]", "Meeting notes", .note),
            ("![[notes/Meeting.markdown#Summary]]", "notes/Meeting.markdown#Summary", .note),
            ("![[archive.zip]]", "archive.zip", .unknown),
        ]
        for fixture in fixtures {
            let span = SyntaxHighlighter.parse(fixture.source).first {
                if case .embed = $0.kind { return true }
                return false
            }
            #expect(span?.kind == .embed(
                target: fixture.target,
                kind: fixture.kind
            ))
        }
    }

    @Test("Read attachment labels expose matching type and bilingual unavailable-preview copy")
    func attachmentHTMLSemantics() {
        let html = HTMLRenderer.render(
            markdown: "![[paper.pdf]] ![[talk.m4a]] ![[demo.mp4]] ![[Note]] ![[data.bin]]"
        )
        for kind in AttachmentKind.allCases {
            #expect(html.contains("data-attachment-kind=\"\(kind.rawValue)\""))
            #expect(html.contains("embed-label-\(kind.rawValue)"))
        }
        #expect(html.contains("data-attachment-label=\"Audio / 音频\""))
        #expect(html.components(separatedBy: "role=\"group\"").count - 1
                == AttachmentKind.allCases.count)
        #expect(html.contains("preview unavailable"))
        #expect(html.contains("暂不支持预览"))
        #expect(!html.contains("<audio"))
        #expect(!html.contains("<video"))
        #expect(!html.contains("application/pdf"))
    }

    @Test("Image wikilink embeds remain images and accept independent dimensions")
    func imageEmbed() {
        let spans = SyntaxHighlighter.parse("![[photo.png|320x200]]")
        #expect(spans.contains {
            if case .image("photo.png", 320, 200) = $0.kind { return true }
            return false
        })
        let gated = SyntaxHighlighter.parse(
            "![[photo.png|320x200]]", features: .all.subtracting(.imageDimensions)
        )
        #expect(gated.contains {
            if case .image("photo.png", nil, nil) = $0.kind { return true }
            return false
        })
    }
}
