import AppKit
import Foundation
import Testing
@testable import FloralMDCore
@testable import floralmd

@Suite("Hidden document presentation lifecycle")
struct DocumentPresentationLifecycleTests {
    @MainActor
    @Test("A hidden file tab initializes its Git baseline before the first edit")
    func hiddenFileTabInitializesGitBaseline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-HiddenTab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("tracked.md")
        let original = "main line\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        try runGit(["init", "-q"], in: root)
        try runGit(["config", "user.name", "FloralMD Tests"], in: root)
        try runGit(["config", "user.email", "tests@floralmd.local"], in: root)
        try runGit(["add", "tracked.md"], in: root)
        try runGit(["commit", "-qm", "baseline"], in: root)

        let target = Document()
        target.fileURL = file
        try target.read(from: file, ofType: "public.plain-text")
        target.prepareForHiddenWindowPresentation()
        defer { target.close() }

        let completion = ApplicationLifecyclePolicy.hiddenDocumentPresentationCompletion(
            activatedIncrementallyInAllSpaces: false
        )
        #expect(completion == .afterNativeTabActivation)
        target.finishHiddenWindowPresentationSetup()
        let editor = try #require(target.editor)
        #expect(editor.rawSource == original)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", into: editor)
        #expect(editor.gitChangeSet.lines[0] == .modified)

        editor.undo(nil)
        #expect(editor.rawSource == original)
        #expect(editor.gitChangeSet.lines.isEmpty)
        #expect(editor.gitChangeSet.deletionBoundaries.isEmpty)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
