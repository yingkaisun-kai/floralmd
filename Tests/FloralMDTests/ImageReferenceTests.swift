import AppKit
import Foundation
import Testing
@testable import FloralMDCore

@Suite("Image references")
struct ImageReferenceTests {
    @Test("Builds a sibling relative path and encodes Markdown-special characters")
    func relativePath() {
        let document = URL(fileURLWithPath: "/tmp/Notes/today.md")
        let image = URL(fileURLWithPath: "/tmp/Notes/assets/model (最终)#1.png")
        #expect(ImageReference.relativeDestination(documentURL: document, imageURL: image)
                == "assets/model%20%28%E6%9C%80%E7%BB%88%29%231.png")
    }

    @Test("Builds a parent relative path")
    func parentPath() {
        let document = URL(fileURLWithPath: "/tmp/Notes/daily/today.md")
        let image = URL(fileURLWithPath: "/tmp/Notes/images/chart.png")
        #expect(ImageReference.relativeDestination(documentURL: document, imageURL: image)
                == "../images/chart.png")
    }

    @Test("Builds an encoded absolute path without requiring a saved document")
    func absolutePath() {
        let image = URL(fileURLWithPath: "/tmp/My Images/chart #1.png")
        #expect(ImageReference.destination(documentURL: nil, imageURL: image, style: .absolute)
                == "/tmp/My%20Images/chart%20%231.png")
    }

    @Test("Relative destinations require a saved document")
    func unsavedRelativePath() {
        let image = URL(fileURLWithPath: "/tmp/chart.png")
        #expect(ImageReference.destination(documentURL: nil, imageURL: image, style: .relative) == nil)
    }

    @Test("Builds the editable clipboard prefix deterministically")
    func timestampPrefix() {
        let date = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(ImageReference.timestampPrefix(for: date, timeZone: utc) == "1970-01-01_00-00-00_")
    }

    @Test("Sanitizes image names without forcing the timestamp prefix")
    func sanitizedName() {
        #expect(ImageReference.sanitizedImageBaseName("  own/name.png ") == "own-name")
        #expect(ImageReference.sanitizedImageBaseName(".png") == "image")
    }

    @Test("Keeps asset folders relative to the Markdown document")
    func normalizedAssetFolder() {
        #expect(ImageReference.normalizedAssetFolder("images/screenshots") == "images/screenshots")
        #expect(ImageReference.normalizedAssetFolder("../outside") == "assets")
        #expect(ImageReference.normalizedAssetFolder("/tmp/images") == "assets")
    }

    @Test("Escapes alt text without adding display characters")
    func markdown() {
        #expect(ImageReference.markdown(altText: "a]b\\c\nnext", destination: "assets/a.png")
                == "![a\\]b\\\\c next](assets/a.png)")
    }

    @Test("Parses and updates Obsidian-compatible image dimensions")
    func obsidianDimensions() {
        #expect(ImageReference.displaySize(in: "diagram|480")
                == .init(altText: "diagram", width: 480, height: nil))
        #expect(ImageReference.displaySize(in: "diagram|480x320")
                == .init(altText: "diagram", width: 480, height: 320))
        #expect(ImageReference.displaySize(in: "2026")
                == .init(altText: "", width: 2026, height: nil))
        #expect(ImageReference.displaySize(in: "figure 2026")
                == .init(altText: "figure 2026", width: nil, height: nil))
        #expect(ImageReference.markdownBySettingWidth("![diagram](assets/a.png)", width: 480)
                == "![diagram|480](assets/a.png)")
        #expect(ImageReference.markdownBySettingWidth("![diagram|320](assets/a.png)", width: 480)
                == "![diagram|480](assets/a.png)")
    }
}

@MainActor
@Suite("Image reference insertion")
struct ImageReferenceInsertionTests {
    @Test("Uses selected source as alt text in one undoable edit")
    func insertsOverSelection() {
        let editor = makeEditor()
        editor.loadContent("diagram")
        editor.setSelectedRange(NSRange(location: 0, length: 7))

        editor.insertImageReference(destination: "assets/model.png", defaultAltText: "model")

        #expect(editor.rawSource == "![diagram](assets/model.png)")
        #expect(editor.string == editor.rawSource)
        editor.undo(nil)
        #expect(editor.rawSource == "diagram")
    }

    @Test("Image handler gets first refusal without changing ordinary paste")
    func pasteInterception() {
        let editor = makeEditor()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)

        editor.imagePasteHandler = { false }
        editor.paste(nil)
        #expect(editor.rawSource == "ordinary text")

        var handled = false
        editor.imagePasteHandler = {
            handled = true
            return true
        }
        pasteboard.clearContents()
        pasteboard.setString(" must not appear", forType: .string)
        editor.paste(nil)
        #expect(handled)
        #expect(editor.rawSource == "ordinary text")
    }

    @Test("Resizing writes Obsidian width syntax as one undoable raw-source edit")
    func resizeImageReference() {
        let editor = makeEditor()
        editor.loadContent("![diagram](assets/model.png)\n\nafter")
        editor.setSelectedRange(NSRange(location: (editor.rawSource as NSString).length,
                                        length: 0))

        #expect(editor.setImageWidth(atRawOffset: 0, width: 480))
        #expect(editor.rawSource == "![diagram|480](assets/model.png)\n\nafter")
        #expect(editor.string == editor.rawSource)
        editor.undo(nil)
        #expect(editor.rawSource == "![diagram](assets/model.png)\n\nafter")
    }
}
