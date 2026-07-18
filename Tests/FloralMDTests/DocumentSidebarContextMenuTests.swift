import Foundation
import Testing
@testable import FloralMDCore

@Suite("Document sidebar context menu")
struct DocumentSidebarContextMenuTests {
    @Test("Markdown files receive the focused document actions")
    func markdownFileCommands() {
        #expect(DocumentSidebarContextMenuPolicy.commands(for: .markdownFile) == [
            .open, .rename, .showInFinder, .copyPath, .moveToTrash,
        ])
    }

    @Test("An unavailable trash action is omitted instead of disabled")
    func unavailableTrashCommand() {
        #expect(DocumentSidebarContextMenuPolicy.commands(
            for: .markdownFile,
            canMoveToTrash: false
        ) == [.open, .rename, .showInFinder, .copyPath])
    }

    @Test("Folders stay navigation-only and never expose recursive deletion")
    func directoryCommands() {
        #expect(DocumentSidebarContextMenuPolicy.commands(for: .directory) == [
            .showInFinder, .copyPath,
        ])
    }

    @Test("Trash validation accepts a file and rejects folders or missing paths")
    func trashSourceValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floralmd-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("note.md")
        try Data("recoverable".utf8).write(to: file)
        try DocumentFileTrashOperation.validateSource(file)

        #expect(throws: DocumentFileTrashError.sourceIsDirectory) {
            try DocumentFileTrashOperation.validateSource(directory)
        }
        #expect(throws: DocumentFileTrashError.sourceMissing) {
            try DocumentFileTrashOperation.validateSource(
                directory.appendingPathComponent("missing.md")
            )
        }
    }
}
