import Foundation
import Testing
@testable import FloralMDCore

@Suite("Document file rename")
struct DocumentFileRenameTests {
    @Test("Renaming preserves the Markdown extension and file contents")
    func successfulRename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("notes.md")
        try Data("draft".utf8).write(to: source)

        let request = try DocumentFileRenameRequest(sourceURL: source, proposedStem: "meeting")
        let destination = try DocumentFileRenameOperation.renameUnopenedFile(request)

        #expect(destination.lastPathComponent == "meeting.md")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "draft")
    }

    @Test("An existing same-directory file is never overwritten")
    func duplicateName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("one.md")
        let destination = directory.appendingPathComponent("two.md")
        try Data("source".utf8).write(to: source)
        try Data("keep".utf8).write(to: destination)
        let request = try DocumentFileRenameRequest(sourceURL: source, proposedStem: "two")

        #expect(throws: DocumentFileRenameError.destinationExists) {
            try DocumentFileRenameOperation.renameUnopenedFile(request)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    }

    @Test("Invalid names are rejected before touching the file system",
          arguments: ["", ".", "..", "a/b", "a\\b", " a", "a "])
    func invalidNames(name: String) throws {
        let source = URL(fileURLWithPath: "/tmp/original.md")
        #expect(throws: (any Error).self) {
            try DocumentFileRenameRequest(sourceURL: source, proposedStem: name)
        }
    }

    @Test("Editing the full name cannot remove or change the extension")
    func extensionProtection() throws {
        let source = URL(fileURLWithPath: "/tmp/original.md")
        #expect(throws: DocumentFileRenameError.extensionChanged(expected: "md")) {
            try DocumentFileRenameRequest(sourceURL: source, proposedFullName: "renamed")
        }
        #expect(throws: DocumentFileRenameError.extensionChanged(expected: "md")) {
            try DocumentFileRenameRequest(sourceURL: source, proposedFullName: "renamed.txt")
        }
    }

    @Test("Return commits while Escape and focus loss cancel")
    func inlineEditingEndPolicy() {
        #expect(DocumentInlineRenamePolicy.action(for: .returnKey) == .commit)
        #expect(DocumentInlineRenamePolicy.action(for: .escapeKey) == .cancel)
        #expect(DocumentInlineRenamePolicy.action(for: .focusLoss) == .cancel)
        #expect(DocumentInlineRenamePolicy.action(forTextMovement: 0x10) == .commit)
        #expect(DocumentInlineRenamePolicy.action(forTextMovement: 0x17) == .cancel)
        #expect(DocumentInlineRenamePolicy.action(forTextMovement: nil) == .cancel)
        #expect(DocumentInlineRenamePolicy.action(forTextMovement: 0, keyCode: 36) == .commit)
        #expect(DocumentInlineRenamePolicy.action(forTextMovement: 0, keyCode: 76) == .commit)
    }

    @Test("The name reserves double-click for rename while row chrome stays an immediate open path")
    func fileTreeClickPolicy() {
        #expect(DocumentFileTreeClickPolicy.action(target: .name, clickCount: 1)
                == .delayedOpen)
        #expect(DocumentFileTreeClickPolicy.action(target: .name, clickCount: 2)
                == .beginRename)
        #expect(DocumentFileTreeClickPolicy.action(target: .rowChrome, clickCount: 1)
                == .openImmediately)
    }

    @Test("A case-only rename works without losing the file")
    func caseOnlyRename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Notes.md")
        try Data("case".utf8).write(to: source)
        let request = try DocumentFileRenameRequest(sourceURL: source, proposedStem: "notes")

        let destination = try DocumentFileRenameOperation.renameUnopenedFile(request)

        #expect(destination.lastPathComponent == "notes.md")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "case")
        #expect(MarkdownDirectory.entries(at: directory).map(\.url.lastPathComponent) == ["notes.md"])
    }

    @Test("An open document receives the destination URL through its move owner")
    @MainActor func openDocumentURLSync() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("open.md")
        try Data("unsaved buffer remains document-owned".utf8).write(to: source)
        let document = FakeOpenDocument(fileURL: source)
        let request = try DocumentFileRenameRequest(sourceURL: source, proposedStem: "renamed")

        let result = await withCheckedContinuation { continuation in
            OpenDocumentFileRenameCoordinator.rename(request, document: document) {
                continuation.resume(returning: $0)
            }
        }
        let destination = try result.get()

        #expect(document.renameFileURL == destination)
        #expect(destination.lastPathComponent == "renamed.md")
        #expect(try String(contentsOf: destination, encoding: .utf8)
                == "unsaved buffer remains document-owned")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
private final class FakeOpenDocument: OpenDocumentFileMoving {
    private(set) var renameFileURL: URL?

    init(fileURL: URL) {
        renameFileURL = fileURL.standardizedFileURL
    }

    func moveFileForRename(to url: URL,
                           completionHandler: @escaping @MainActor (Error?) -> Void) {
        guard let source = renameFileURL else {
            completionHandler(DocumentFileRenameError.sourceMissing)
            return
        }
        do {
            // NSDocument's move(to:) replaces the coordinator-owned reservation.
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: source, to: url)
            renameFileURL = url.standardizedFileURL
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
