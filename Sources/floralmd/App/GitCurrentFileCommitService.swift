import Foundation
import FloralMDCore

enum GitCurrentFileStatus: Equatable, Sendable {
    case clean
    case tracked(index: Character, workTree: Character)
    case untracked

    var isUntracked: Bool {
        if case .untracked = self { return true }
        return false
    }
}

struct GitCurrentFileCommitContext: Equatable, Sendable {
    let rootURL: URL
    let branch: String
    let relativePath: String
    let status: GitCurrentFileStatus
}

struct GitCurrentFileCommitResult: Equatable, Sendable {
    let context: GitCurrentFileCommitContext
    let abbreviatedCommit: String
}

enum GitCurrentFileCommitError: LocalizedError, Equatable, Sendable {
    case notMarkdown
    case fileUnavailable
    case noRepository
    case outsideRepository
    case detachedHEAD
    case operationInProgress(String)
    case ignored
    case conflicted
    case deleted
    case renamedOrCopied
    case noChanges
    case emptyMessage
    case gitFailed(String)
    case cleanupFailed(commitError: String, cleanupError: String)

    var errorDescription: String? {
        switch self {
        case .notMarkdown:
            AppCopy.text("Only Markdown files can be committed here.",
                         "这里只能提交 Markdown 文件。")
        case .fileUnavailable:
            AppCopy.text("The current file is missing or is not a regular file.",
                         "当前文件不存在，或不是普通文件。")
        case .noRepository:
            AppCopy.text("The current file is not inside a Git repository.",
                         "当前文件不在 Git 仓库中。")
        case .outsideRepository:
            AppCopy.text("The current file is outside the detected Git repository.",
                         "当前文件不在检测到的 Git 仓库范围内。")
        case .detachedHEAD:
            AppCopy.text("Git is in detached HEAD state. Check out a branch before committing.",
                         "Git 当前处于 detached HEAD 状态。请先切换到分支再提交。")
        case .operationInProgress(let operation):
            AppCopy.text("A Git \(operation) operation is in progress. Finish or abort it first.",
                         "Git 正在进行 \(operation) 操作。请先完成或中止该操作。")
        case .ignored:
            AppCopy.text("The current file is ignored by Git.", "当前文件已被 Git 忽略。")
        case .conflicted:
            AppCopy.text("The current file has unresolved conflicts.", "当前文件存在未解决的冲突。")
        case .deleted:
            AppCopy.text("The current file is marked as deleted in Git.",
                         "当前文件在 Git 中被标记为已删除。")
        case .renamedOrCopied:
            AppCopy.text("A pending rename or copy cannot be committed as one current file safely.",
                         "当前文件存在待提交的重命名或复制，无法安全地只提交此文件。")
        case .noChanges:
            AppCopy.text("The saved file has no changes to commit.", "已保存文件没有可提交的变化。")
        case .emptyMessage:
            AppCopy.text("Enter a commit message.", "请输入提交信息。")
        case .gitFailed(let message):
            AppCopy.text("Git could not create the commit:\n\(message)",
                         "Git 无法创建提交：\n\(message)")
        case .cleanupFailed(let commitError, let cleanupError):
            AppCopy.text(
                "Git could not create the commit, and the temporary intent-to-add could not be removed. Commit error:\n\(commitError)\n\nCleanup error:\n\(cleanupError)",
                "Git 无法创建提交，且无法清理临时 intent-to-add 状态。提交错误：\n\(commitError)\n\n清理错误：\n\(cleanupError)"
            )
        }
    }
}

/// Runs the narrow mutation needed for one document commit away from the main
/// actor. The existing synchronous `GitRepository` runner remains read-only;
/// this service revalidates safety immediately before every mutation.
struct GitCurrentFileCommitService: Sendable {
    func inspect(fileURL: URL) async throws -> GitCurrentFileCommitContext {
        try await Task.detached(priority: .userInitiated) {
            try Self.inspectSynchronously(fileURL: fileURL)
        }.value
    }

    func commit(fileURL: URL, message: String) async throws -> GitCurrentFileCommitResult {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { throw GitCurrentFileCommitError.emptyMessage }

        return try await Task.detached(priority: .userInitiated) {
            let context = try Self.inspectSynchronously(fileURL: fileURL)
            guard context.status != .clean else {
                throw GitCurrentFileCommitError.noChanges
            }

            var addedIntentToAdd = false
            if context.status.isUntracked {
                let add = Self.runGit(["add", "-N", "--", context.relativePath],
                                      at: context.rootURL)
                guard add.status == 0 else {
                    throw GitCurrentFileCommitError.gitFailed(add.failureDescription)
                }
                addedIntentToAdd = true
            }

            let commit = Self.runGit(
                ["commit", "--only", "-m", trimmedMessage, "--", context.relativePath],
                at: context.rootURL
            )
            guard commit.status == 0 else {
                if addedIntentToAdd {
                    // `add -N` is the only preparatory mutation. Restore only this
                    // path; never snapshot or rewrite the repository-wide index.
                    let cleanup = Self.runGit(["reset", "--", context.relativePath],
                                              at: context.rootURL)
                    guard cleanup.status == 0 else {
                        throw GitCurrentFileCommitError.cleanupFailed(
                            commitError: commit.failureDescription,
                            cleanupError: cleanup.failureDescription
                        )
                    }
                }
                throw GitCurrentFileCommitError.gitFailed(commit.failureDescription)
            }

            let head = Self.runGit(["rev-parse", "--short", "HEAD"], at: context.rootURL)
            let abbreviatedCommit = head.status == 0
                ? head.output.trimmingCharacters(in: .whitespacesAndNewlines)
                : "HEAD"
            return GitCurrentFileCommitResult(
                context: context,
                abbreviatedCommit: abbreviatedCommit
            )
        }.value
    }

    private static func inspectSynchronously(fileURL: URL) throws
        -> GitCurrentFileCommitContext {
        let fileURL = fileURL.standardizedFileURL
        guard MarkdownDirectory.isMarkdown(fileURL) else {
            throw GitCurrentFileCommitError.notMarkdown
        }
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw GitCurrentFileCommitError.fileUnavailable
        }
        guard let rootURL = GitRepository.nearestRoot(from: fileURL)?.standardizedFileURL else {
            throw GitCurrentFileCommitError.noRepository
        }
        let rootPath = rootURL.path
        let filePath = fileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw GitCurrentFileCommitError.outsideRepository
        }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))

        let branchResult = runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], at: rootURL)
        guard branchResult.status == 0 else {
            throw GitCurrentFileCommitError.detachedHEAD
        }
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if let operation = inProgressOperation(at: rootURL) {
            throw GitCurrentFileCommitError.operationInProgress(operation)
        }

        let statusResult = runGit(
            ["status", "--porcelain=v1", "-z", "--ignored=matching", "--", relativePath],
            at: rootURL
        )
        guard statusResult.status == 0 else {
            throw GitCurrentFileCommitError.gitFailed(statusResult.failureDescription)
        }
        guard let record = statusResult.output.split(
            separator: "\0", omittingEmptySubsequences: true
        ).first else {
            return GitCurrentFileCommitContext(rootURL: rootURL, branch: branch,
                                               relativePath: relativePath, status: .clean)
        }
        let characters = Array(record)
        guard characters.count >= 3 else {
            throw GitCurrentFileCommitError.gitFailed("Git returned an invalid file status.")
        }
        let index = characters[0]
        let workTree = characters[1]
        if index == "!", workTree == "!" { throw GitCurrentFileCommitError.ignored }
        if index == "?", workTree == "?" {
            return GitCurrentFileCommitContext(rootURL: rootURL, branch: branch,
                                               relativePath: relativePath, status: .untracked)
        }
        let conflictPairs: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        if index == "U" || workTree == "U" || conflictPairs.contains(String([index, workTree])) {
            throw GitCurrentFileCommitError.conflicted
        }
        if index == "D" || workTree == "D" { throw GitCurrentFileCommitError.deleted }
        if index == "R" || workTree == "R" || index == "C" || workTree == "C" {
            throw GitCurrentFileCommitError.renamedOrCopied
        }
        return GitCurrentFileCommitContext(
            rootURL: rootURL,
            branch: branch,
            relativePath: relativePath,
            status: .tracked(index: index, workTree: workTree)
        )
    }

    private static func inProgressOperation(at rootURL: URL) -> String? {
        let heads = [
            ("MERGE_HEAD", "merge"),
            ("CHERRY_PICK_HEAD", "cherry-pick"),
            ("REVERT_HEAD", "revert"),
            ("BISECT_LOG", "bisect"),
        ]
        for (revision, label) in heads {
            if runGit(["rev-parse", "--quiet", "--verify", revision], at: rootURL).status == 0 {
                return label
            }
        }

        for directory in ["rebase-merge", "rebase-apply"] {
            let path = runGit(["rev-parse", "--git-path", directory], at: rootURL)
            guard path.status == 0 else { continue }
            let value = path.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = value.hasPrefix("/")
                ? URL(fileURLWithPath: value)
                : rootURL.appendingPathComponent(value)
            if FileManager.default.fileExists(atPath: url.path) { return "rebase" }
        }
        return nil
    }

    private struct GitOutput: Sendable {
        let status: Int32
        let output: String

        var failureDescription: String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Git exited with status \(status)." : trimmed
        }
    }

    private static func runGit(_ arguments: [String], at rootURL: URL) -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = rootURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            // Drain while Git and hooks are running so verbose output cannot fill
            // the pipe and deadlock the background task.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return GitOutput(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return GitOutput(status: -1, output: error.localizedDescription)
        }
    }
}
