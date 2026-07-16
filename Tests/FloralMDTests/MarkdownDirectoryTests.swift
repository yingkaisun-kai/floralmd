import Foundation
import Testing
@testable import FloralMDCore

@Suite("Markdown directory navigation")
struct MarkdownDirectoryTests {
    @Test("Lists folders and Markdown files, folders first")
    func listsRelevantEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("B.md"))
        try Data().write(to: root.appendingPathComponent("a.markdown"))
        try Data().write(to: root.appendingPathComponent("ignored.txt"))

        let entries = MarkdownDirectory.entries(at: root)
        #expect(entries.map(\.url.lastPathComponent) == ["Notes", "a.markdown", "B.md"])
        #expect(entries.map(\.isDirectory) == [true, false, false])
    }

    @Test("Recognizes the app's supported Markdown extensions")
    func recognizesExtensions() {
        #expect(MarkdownDirectory.isMarkdown(URL(fileURLWithPath: "/tmp/a.MD")))
        #expect(MarkdownDirectory.isMarkdown(URL(fileURLWithPath: "/tmp/a.mdown")))
        #expect(!MarkdownDirectory.isMarkdown(URL(fileURLWithPath: "/tmp/a.txt")))
    }

    @Test("Counts Markdown files recursively while skipping hidden folders")
    func countsMarkdownRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent("one.md"))
        try Data().write(to: nested.appendingPathComponent("two.markdown"))
        try Data().write(to: nested.appendingPathComponent("ignored.txt"))
        try Data().write(to: hidden.appendingPathComponent("hidden.md"))

        #expect(MarkdownDirectory.markdownCount(in: root) == 2)
        #expect(MarkdownDirectory.markdownCount(in: nested) == 1)
    }
}
