// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit
import Testing
@testable import FloralMDCore

@MainActor
@Suite("Extended syntax — offscreen visual rendering")
struct ExtendedRenderingTests {
    @Test("Light and dark surfaces render classified source-backed attachment labels")
    func lightAndDark() throws {
        for (name, appearance) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua),
        ] {
            let editor = makeEditor()
            editor.appearance = NSAppearance(named: appearance)
            editor.frame = NSRect(x: 0, y: 0, width: 720, height: 360)
            editor.textContainerInset = NSSize(width: 28, height: 24)
            editor.loadContent("# Attachments\n\n![[Paper.pdf]] · ![[Audio.mp3]] · ![[Video.mov]]\n\n![[Meeting notes]] · ![[Archive.zip]]")
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.recompose(cursorInRaw: 0)
            ensureFullLayout(editor)
            editor.layoutSubtreeIfNeeded()

            let fixtures: [(String, AttachmentKind)] = [
                ("Paper.pdf", .pdf), ("Audio.mp3", .audio), ("Video.mov", .video),
                ("Meeting notes", .note), ("Archive.zip", .unknown),
            ]
            var colors: [NSColor] = []
            for (target, kind) in fixtures {
                let offset = (editor.rawSource as NSString).range(of: target).location
                #expect(editor.textStorage?.attribute(.editorAttachmentKind, at: offset,
                                                      effectiveRange: nil) as? String == kind.rawValue)
                #expect((editor.textStorage?.attribute(.toolTip, at: offset,
                                                       effectiveRange: nil) as? String)?.contains("暂不支持预览") == true)
                let color = try #require(editor.textStorage?.attribute(
                    .foregroundColor, at: offset, effectiveRange: nil
                ) as? NSColor)
                colors.append(color)
            }
            #expect(Set(colors.map { $0.usingColorSpace(.sRGB)?.hexString ?? "" }).count == fixtures.count)
            #expect(editor.string == editor.rawSource)

            let rep = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.cacheDisplay(in: editor.bounds, to: rep)
            #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
            if let directory = ProcessInfo.processInfo.environment["FLORALMD_VISUAL_OUTPUT_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: directory)
                    .appendingPathComponent("attachment-labels-\(name).png")
                try png.write(to: url)
            }
        }
    }
}
