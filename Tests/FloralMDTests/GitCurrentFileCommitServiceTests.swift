import Foundation
import AppKit
import Testing
@testable import floralmd

struct GitCurrentFileCommitServiceTests {
    @MainActor
    @Test("Git sidebar exposes the current-file commit action in light and dark appearances")
    func sidebarCommitActionRendersInBothAppearances() throws {
        let repo = try TemporaryGitRepository()
        let document = try repo.write("current.md", "before\n")
        try repo.git("add", "--", "current.md")
        try repo.git("commit", "-m", "initial")
        try repo.write(document, "after\n")

        for (appearanceName, suffix) in [
            (NSAppearance.Name.aqua, "light"),
            (NSAppearance.Name.darkAqua, "dark"),
        ] {
            let sidebar = DocumentNavigationSidebarView(
                frame: NSRect(x: 0, y: 0, width: 248, height: 620)
            )
            sidebar.appearance = NSAppearance(named: appearanceName)
            sidebar.refresh(currentFileURL: document)
            let segmented = try #require(
                sidebar.descendant(ofType: NSSegmentedControl.self)
            )
            segmented.selectedSegment = 1
            if let action = segmented.action {
                segmented.sendAction(action, to: segmented.target)
            }
            sidebar.layoutSubtreeIfNeeded()

            let button = try #require(
                sidebar.descendants(ofType: NSButton.self).first {
                    $0.accessibilityIdentifier() == "gitCommitCurrentFileButton"
                }
            )
            #expect(!button.isHidden)
            #expect(button.title.contains("Commit") || button.title.contains("提交"))

            let representation = try #require(
                sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds)
            )
            sidebar.cacheDisplay(in: sidebar.bounds, to: representation)
            let png = try #require(representation.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath:
                "/private/tmp/floralmd-git-current-file-\(suffix).png"))
        }
    }

    @Test("Commits one tracked file while preserving another staged file")
    func trackedFilePreservesOtherStagedFile() async throws {
        let repo = try TemporaryGitRepository()
        let document = try repo.write("notes/current.md", "before\n")
        _ = try repo.write("other.md", "other before\n")
        try repo.git("add", "--", ".")
        try repo.git("commit", "-m", "initial")

        try repo.write(document, "after\n")
        try repo.write("other.md", "other staged\n")
        try repo.git("add", "--", "other.md")
        let otherIndexBefore = try repo.git("rev-parse", ":other.md")

        let result = try await GitCurrentFileCommitService().commit(
            fileURL: document,
            message: "document: update current"
        )

        #expect(result.context.relativePath == "notes/current.md")
        #expect(try repo.git("show", "HEAD:notes/current.md") == "after")
        #expect(try repo.git("rev-parse", ":other.md") == otherIndexBefore)
        #expect(try repo.git("diff", "--cached", "--name-only") == "other.md")
    }

    @Test("Commits the saved working-tree version when current file is staged and modified")
    func stagedAndUnstagedCurrentFileUsesFullWorkingTreeVersion() async throws {
        let repo = try TemporaryGitRepository()
        let document = try repo.write("current.md", "before\n")
        _ = try repo.write("other.md", "other before\n")
        try repo.git("add", "--", ".")
        try repo.git("commit", "-m", "initial")

        try repo.write(document, "staged version\n")
        try repo.git("add", "--", "current.md")
        try repo.write(document, "complete saved version\n")
        try repo.write("other.md", "other staged\n")
        try repo.git("add", "--", "other.md")
        let otherIndexBefore = try repo.git("rev-parse", ":other.md")

        _ = try await GitCurrentFileCommitService().commit(
            fileURL: document,
            message: "document: save complete version"
        )

        #expect(try repo.git("show", "HEAD:current.md") == "complete saved version")
        #expect(try repo.git("rev-parse", ":other.md") == otherIndexBefore)
        #expect(try repo.git("diff", "--cached", "--name-only") == "other.md")
        #expect(try repo.git("status", "--porcelain=v1", "--", "current.md").isEmpty)
    }

    @Test("Commits one untracked Markdown file while preserving another staged file")
    func untrackedFilePreservesOtherStagedFile() async throws {
        let repo = try TemporaryGitRepository()
        _ = try repo.write("other.md", "other before\n")
        try repo.git("add", "--", "other.md")
        try repo.git("commit", "-m", "initial")
        try repo.write("other.md", "other staged\n")
        try repo.git("add", "--", "other.md")
        let otherIndexBefore = try repo.git("rev-parse", ":other.md")
        let document = try repo.write("new note.md", "new document\n")

        _ = try await GitCurrentFileCommitService().commit(
            fileURL: document,
            message: "document: add note"
        )

        #expect(try repo.git("show", "HEAD:new note.md") == "new document")
        #expect(try repo.git("rev-parse", ":other.md") == otherIndexBefore)
        #expect(try repo.git("diff", "--cached", "--name-only") == "other.md")
    }

    @Test("Removes only temporary intent-to-add after a hook rejects the commit")
    func failedUntrackedCommitCleansIntentToAdd() async throws {
        let repo = try TemporaryGitRepository()
        _ = try repo.write("other.md", "other before\n")
        try repo.git("add", "--", "other.md")
        try repo.git("commit", "-m", "initial")
        try repo.write("other.md", "other staged\n")
        try repo.git("add", "--", "other.md")
        let otherIndexBefore = try repo.git("rev-parse", ":other.md")
        let document = try repo.write("new.md", "new document\n")
        try repo.installRejectingPreCommitHook()

        do {
            _ = try await GitCurrentFileCommitService().commit(
                fileURL: document,
                message: "document: rejected"
            )
            Issue.record("Expected the pre-commit hook to reject the commit")
        } catch let error as GitCurrentFileCommitError {
            guard case .gitFailed(let output) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(output.contains("hook rejected commit"))
        }

        #expect(try repo.git("ls-files", "--stage", "--", "new.md").isEmpty)
        #expect(try repo.git("status", "--porcelain=v1", "--", "new.md") == "?? new.md")
        #expect(try repo.git("rev-parse", ":other.md") == otherIndexBefore)
        #expect(try repo.git("diff", "--cached", "--name-only") == "other.md")
    }

    @Test("Rejects a tracked file with no changes")
    func rejectsNoChanges() async throws {
        let repo = try TemporaryGitRepository()
        let document = try repo.write("current.md", "unchanged\n")
        try repo.git("add", "--", "current.md")
        try repo.git("commit", "-m", "initial")

        do {
            _ = try await GitCurrentFileCommitService().commit(
                fileURL: document,
                message: "document: no change"
            )
            Issue.record("Expected a no-changes error")
        } catch let error as GitCurrentFileCommitError {
            #expect(error == .noChanges)
        }
    }

    @Test("Rejects merge-in-progress and detached HEAD repositories")
    func rejectsUnsafeRepositoryStates() async throws {
        let repo = try TemporaryGitRepository()
        let document = try repo.write("current.md", "before\n")
        try repo.git("add", "--", "current.md")
        try repo.git("commit", "-m", "initial")
        try repo.write(document, "after\n")

        let head = try repo.git("rev-parse", "HEAD")
        try (head + "\n").write(
            to: repo.root.appendingPathComponent(".git/MERGE_HEAD"),
            atomically: true,
            encoding: .utf8
        )
        do {
            _ = try await GitCurrentFileCommitService().inspect(fileURL: document)
            Issue.record("Expected merge-in-progress to be rejected")
        } catch let error as GitCurrentFileCommitError {
            #expect(error == .operationInProgress("merge"))
        }

        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/MERGE_HEAD"))
        try repo.git("checkout", "--detach")
        do {
            _ = try await GitCurrentFileCommitService().inspect(fileURL: document)
            Issue.record("Expected detached HEAD to be rejected")
        } catch let error as GitCurrentFileCommitError {
            #expect(error == .detachedHEAD)
        }
    }

    @Test("Rejects a current file with unresolved conflicts")
    func rejectsConflictedFile() async throws {
        let repo = try TemporaryGitRepository()
        let document = try repo.write("current.md", "base\n")
        try repo.git("add", "--", "current.md")
        try repo.git("commit", "-m", "initial")
        try repo.git("checkout", "-b", "side")
        try repo.write(document, "side\n")
        try repo.git("commit", "-am", "side")
        try repo.git("checkout", "main")
        try repo.write(document, "main\n")
        try repo.git("commit", "-am", "main")
        #expect(try repo.gitExpectingFailure("merge", "side").contains("CONFLICT"))

        // Keep the actual unmerged index entries while removing only the
        // operation sentinel so this assertion reaches the file-level gate.
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/MERGE_HEAD"))
        do {
            _ = try await GitCurrentFileCommitService().inspect(fileURL: document)
            Issue.record("Expected the conflicted file to be rejected")
        } catch let error as GitCurrentFileCommitError {
            #expect(error == .conflicted)
        }
    }

    @Test("Handles repository-relative paths containing spaces and Chinese characters")
    func handlesSpacesAndChinesePath() async throws {
        let repo = try TemporaryGitRepository()
        let relativePath = "文章/中文 文档.md"
        let document = try repo.write(relativePath, "旧内容\n")
        try repo.git("add", "--", relativePath)
        try repo.git("commit", "-m", "initial")
        try repo.write(document, "新内容\n")

        let result = try await GitCurrentFileCommitService().commit(
            fileURL: document,
            message: "document: 更新中文文档"
        )

        #expect(result.context.relativePath == relativePath)
        #expect(try repo.git("show", "HEAD:\(relativePath)") == "新内容")
    }
}

private extension NSView {
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            let matchingView = (view as? T).map { [$0] } ?? []
            return matchingView + view.descendants(ofType: type)
        }
    }

    func descendant<T: NSView>(ofType type: T.Type) -> T? {
        descendants(ofType: type).first
    }
}

private final class TemporaryGitRepository {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-GitCommitTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-b", "main")
        try git("config", "user.name", "FloralMD Tests")
        try git("config", "user.email", "tests@floralmd.invalid")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func write(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func installRejectingPreCommitHook() throws {
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'hook rejected commit' >&2\nexit 1\n".write(
            to: hook,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: hook.path
        )
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let result = try runGit(arguments)
        guard result.status == 0 else {
            throw NSError(
                domain: "FloralMDTests.Git",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.output]
            )
        }
        return result.output
    }

    func gitExpectingFailure(_ arguments: String...) throws -> String {
        let result = try runGit(arguments)
        guard result.status != 0 else {
            throw NSError(
                domain: "FloralMDTests.Git",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Git unexpectedly succeeded"]
            )
        }
        return result.output
    }

    private func runGit(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
