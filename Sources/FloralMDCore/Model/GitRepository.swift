import Foundation

public struct GitFileChange: Equatable, Sendable {
    public let path: String
    public let indexStatus: Character
    public let workTreeStatus: Character

    public init(path: String, indexStatus: Character, workTreeStatus: Character) {
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
    }

    public var isIgnored: Bool { indexStatus == "!" && workTreeStatus == "!" }
    public var isUntracked: Bool { indexStatus == "?" && workTreeStatus == "?" }
    public var isStaged: Bool { ![" ", "?", "!"].contains(indexStatus) }

    public var badge: String {
        if isIgnored { return "I" }
        if isUntracked { return "U" }
        if indexStatus == "U" || workTreeStatus == "U" { return "!" }
        if workTreeStatus != " " { return String(workTreeStatus) }
        return String(indexStatus)
    }

    public var pathState: GitPathState {
        if isIgnored { return .ignored }
        if isUntracked { return .untracked }
        if indexStatus == "U" || workTreeStatus == "U" { return .conflicted }
        if workTreeStatus != " " { return .modified }
        return .staged
    }
}

public enum GitPathState: Int, Equatable, Sendable, Comparable {
    case ignored = 1
    case untracked = 2
    case staged = 3
    case modified = 4
    case conflicted = 5

    public static func < (lhs: GitPathState, rhs: GitPathState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var badge: String {
        switch self {
        case .ignored: return "I"
        case .untracked: return "U"
        case .staged: return "A"
        case .modified: return "M"
        case .conflicted: return "!"
        }
    }
}

public struct GitRepositorySnapshot: Equatable, Sendable {
    public let rootURL: URL
    public let branch: String
    public let changes: [GitFileChange]

    public init(rootURL: URL, branch: String, changes: [GitFileChange]) {
        self.rootURL = rootURL
        self.branch = branch
        self.changes = changes
    }

    /// Git state for one repository-relative path. Directories inherit the
    /// highest-priority state of any changed descendant.
    public func state(forRelativePath relativePath: String,
                      isDirectory: Bool) -> GitPathState? {
        let normalized = relativePath.hasSuffix("/")
            ? String(relativePath.dropLast()) : relativePath
        let matching = changes.filter { change in
            let path = change.path.hasSuffix("/")
                ? String(change.path.dropLast()) : change.path
            return isDirectory
                ? (path == normalized || path.hasPrefix(normalized + "/"))
                : path == normalized
        }
        return matching.map(\.pathState).max()
    }

    /// Returns a display snapshot whose work-tree state reflects the current
    /// editor buffer, even before it is saved. This is deliberately pure model
    /// work: callers can update an `M` badge on every edit without spawning
    /// `git status` on the main thread. Native untracked, ignored, and conflict
    /// states are never relabeled by the overlay.
    public func overlayingWorkTreeState(for fileURL: URL,
                                        differsFromHEAD: Bool) -> GitRepositorySnapshot {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return self }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))

        var displayedChanges = changes
        if let index = displayedChanges.firstIndex(where: { $0.path == relativePath }) {
            let existing = displayedChanges[index]
            guard !existing.isUntracked, !existing.isIgnored,
                  existing.indexStatus != "U", existing.workTreeStatus != "U" else {
                return self
            }
            if differsFromHEAD {
                displayedChanges[index] = GitFileChange(
                    path: existing.path,
                    indexStatus: existing.indexStatus,
                    workTreeStatus: "M"
                )
            } else if existing.indexStatus == " " {
                displayedChanges.remove(at: index)
            } else {
                displayedChanges[index] = GitFileChange(
                    path: existing.path,
                    indexStatus: existing.indexStatus,
                    workTreeStatus: " "
                )
            }
        } else if differsFromHEAD {
            displayedChanges.append(GitFileChange(
                path: relativePath, indexStatus: " ", workTreeStatus: "M"
            ))
        }
        displayedChanges.sort {
            if $0.isIgnored != $1.isIgnored { return !$0.isIgnored }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return GitRepositorySnapshot(rootURL: rootURL, branch: branch,
                                     changes: displayedChanges)
    }
}

public enum GitFileBaseline: Equatable, Sendable {
    case tracked(String)
    case untracked
}

public enum GitLineChangeKind: Equatable, Sendable {
    case added
    case modified
}

public enum GitDeletionEdge: Hashable, Sendable {
    case before
    case after
}

public struct GitLineChangeSet: Equatable, Sendable {
    public var lines: [Int: GitLineChangeKind]
    /// Zero-based boundaries in the current document: 0 is before the first
    /// line, N is after line N - 1. Deletions have no current line of their own.
    public var deletionBoundaries: Set<Int>

    public init(lines: [Int: GitLineChangeKind] = [:],
                deletionBoundaries: Set<Int> = []) {
        self.lines = lines
        self.deletionBoundaries = deletionBoundaries
    }
}

public enum GitLineChanges {
    /// Zero-based current lines and how they differ from the HEAD version.
    /// Replacements are modified and pure insertions are added. Deletions are
    /// stored separately as inter-line boundaries, matching VS Code's quick
    /// diff model: they must never overwrite a surviving line's own state.
    /// Blank separator runs inside one changed region inherit the surrounding
    /// kind so the gutter does not visually break between changed paragraphs.
    public static func changes(baseline: GitFileBaseline,
                               current: String) -> GitLineChangeSet {
        let currentLines = lines(in: current)
        switch baseline {
        case .untracked:
            return GitLineChangeSet(lines: Dictionary(
                uniqueKeysWithValues: currentLines.indices.map { ($0, .added) }
            ))
        case .tracked(let source):
            let baselineLines = lines(in: source)
            var result: [Int: GitLineChangeKind] = [:]
            var deletionBoundaries = Set<Int>()

            for change in lineDiffs(original: baselineLines, modified: currentLines) {
                if change.original.isEmpty {
                    for line in change.modified { result[line] = .added }
                } else if change.modified.isEmpty {
                    deletionBoundaries.insert(change.modified.lowerBound)
                } else {
                    let original = Array(baselineLines[change.original])
                    let modified = Array(currentLines[change.modified])
                    let pairs = pairedLineIndexes(original: original,
                                                  modified: modified)
                    let pairedOriginal = Set(pairs.map(\.original))
                    let pairedModified = Set(pairs.map(\.modified))

                    for pair in pairs {
                        result[change.modified.lowerBound + pair.modified] = .modified
                    }
                    for line in modified.indices where !pairedModified.contains(line) {
                        result[change.modified.lowerBound + line] = .added
                    }
                    for line in original.indices where !pairedOriginal.contains(line) {
                        // Attach an unmatched old line immediately before the
                        // next surviving pair, or after the hunk when none remains.
                        let boundary = pairs.first { $0.original > line }?.modified
                            ?? modified.count
                        deletionBoundaries.insert(change.modified.lowerBound + boundary)
                    }
                }
            }
            bridgeBlankLines(in: currentLines, changes: &result)
            return GitLineChangeSet(lines: result,
                                    deletionBoundaries: deletionBoundaries)
        }
    }

    /// Zero-based lines whose current contents differ from the HEAD version.
    /// Pure deletions attach to the nearest surviving line.
    public static func changedLineIndexes(baseline: GitFileBaseline,
                                          current: String) -> Set<Int> {
        let changes = changes(baseline: baseline, current: current)
        var indexes = Set(changes.lines.keys)
        for boundary in changes.deletionBoundaries where !lines(in: current).isEmpty {
            indexes.insert(boundary == 0 ? 0 : boundary - 1)
        }
        return indexes
    }

    private static func lines(in source: String) -> [String] {
        guard !source.isEmpty else { return [] }
        return source.components(separatedBy: "\n")
    }

    private static func bridgeBlankLines(in lines: [String],
                                         changes: inout [Int: GitLineChangeKind]) {
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  changes[index] == nil else {
                index += 1
                continue
            }

            let start = index
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  changes[index] == nil {
                index += 1
            }
            guard start > 0, index < lines.count,
                  let before = changes[start - 1],
                  let after = changes[index] else { continue }

            let inherited: GitLineChangeKind = before == after ? before : .modified
            for blankLine in start..<index { changes[blankLine] = inherited }
        }
    }

    private struct SequenceChange {
        var original: Range<Int>
        var modified: Range<Int>
    }

    /// Mirrors the first stage of VS Code's advanced diff: exact trimmed lines
    /// are aligned with a weighted LCS that prefers long, consecutive anchors.
    private static func lineDiffs(original: [String],
                                  modified: [String]) -> [SequenceChange] {
        guard !original.isEmpty, !modified.isEmpty else {
            return original.isEmpty && modified.isEmpty ? [] : [
                SequenceChange(original: 0..<original.count,
                               modified: 0..<modified.count)
            ]
        }
        guard original.count * modified.count <= 2_000_000 else {
            return collectionDiffs(original: original, modified: modified)
        }

        let columns = modified.count
        func offset(_ row: Int, _ column: Int) -> Int { row * columns + column }
        var scores = Array(repeating: 0.0, count: original.count * modified.count)
        var directions = Array(repeating: UInt8(0), count: scores.count)
        var consecutive = Array(repeating: 0, count: scores.count)
        let originalKeys = original.map { $0.trimmingCharacters(in: .whitespaces) }
        let modifiedKeys = modified.map { $0.trimmingCharacters(in: .whitespaces) }

        for oldIndex in original.indices {
            for newIndex in modified.indices {
                let horizontal = oldIndex == 0 ? 0 : scores[offset(oldIndex - 1, newIndex)]
                let vertical = newIndex == 0 ? 0 : scores[offset(oldIndex, newIndex - 1)]
                var diagonal = -1.0
                if originalKeys[oldIndex] == modifiedKeys[newIndex] {
                    diagonal = oldIndex == 0 || newIndex == 0
                        ? 0 : scores[offset(oldIndex - 1, newIndex - 1)]
                    if oldIndex > 0, newIndex > 0,
                       directions[offset(oldIndex - 1, newIndex - 1)] == 3 {
                        diagonal += Double(consecutive[offset(oldIndex - 1, newIndex - 1)])
                    }
                    if original[oldIndex] == modified[newIndex] {
                        diagonal += modified[newIndex].isEmpty
                            ? 0.1 : 1 + log(1 + Double(modified[newIndex].count))
                    } else {
                        diagonal += 0.99
                    }
                }

                let cell = offset(oldIndex, newIndex)
                if diagonal > horizontal, diagonal > vertical {
                    scores[cell] = diagonal
                    directions[cell] = 3
                    consecutive[cell] = (oldIndex > 0 && newIndex > 0
                        ? consecutive[offset(oldIndex - 1, newIndex - 1)] : 0) + 1
                } else if horizontal >= vertical {
                    scores[cell] = horizontal
                    directions[cell] = 1
                } else {
                    scores[cell] = vertical
                    directions[cell] = 2
                }
            }
        }

        var changes: [SequenceChange] = []
        var lastOld = original.count
        var lastNew = modified.count
        func report(_ oldIndex: Int, _ newIndex: Int) {
            if oldIndex + 1 != lastOld || newIndex + 1 != lastNew {
                changes.append(SequenceChange(original: (oldIndex + 1)..<lastOld,
                                              modified: (newIndex + 1)..<lastNew))
            }
            lastOld = oldIndex
            lastNew = newIndex
        }
        var oldIndex = original.count - 1
        var newIndex = modified.count - 1
        while oldIndex >= 0, newIndex >= 0 {
            switch directions[offset(oldIndex, newIndex)] {
            case 3:
                report(oldIndex, newIndex)
                oldIndex -= 1
                newIndex -= 1
            case 1:
                oldIndex -= 1
            default:
                newIndex -= 1
            }
        }
        report(-1, -1)
        return changes.reversed()
    }

    private static func collectionDiffs<Element: Equatable>(original: [Element],
                                                            modified: [Element]) -> [SequenceChange] {
        let difference = modified.difference(from: original)
        let inserted = Set(difference.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        })
        let removed = Set(difference.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        let oldAnchors = original.indices.filter { !removed.contains($0) }
        let newAnchors = modified.indices.filter { !inserted.contains($0) }
        var result: [SequenceChange] = []
        var oldCursor = 0
        var newCursor = 0
        for (oldAnchor, newAnchor) in zip(oldAnchors + [original.count],
                                           newAnchors + [modified.count]) {
            if oldCursor != oldAnchor || newCursor != newAnchor {
                result.append(SequenceChange(original: oldCursor..<oldAnchor,
                                             modified: newCursor..<newAnchor))
            }
            oldCursor = oldAnchor + 1
            newCursor = newAnchor + 1
        }
        return result
    }

    /// Pairs at most one old line with one new line inside a mixed hunk.
    /// Unpaired new lines remain additions instead of being absorbed into a
    /// multi-line modification merely because they are adjacent.
    private static func pairedLineIndexes(original: [String],
                                          modified: [String]) -> [(original: Int, modified: Int)] {
        // The outer line diff has already isolated this mixed hunk between
        // unchanged anchors. Pair surviving lines in document order; any
        // remainder is a true insertion or deletion. Character-diffing every
        // old/new combination here made typing quadratic in hunk size.
        return zip(original.indices, modified.indices).map {
            (original: $0.0, modified: $0.1)
        }
    }
}

public enum GitRepository {
    /// Walks upward from a document or directory and returns the nearest Git
    /// worktree root. `.git` may be a directory or a worktree pointer file.
    public static func nearestRoot(from url: URL,
                                   fileManager: FileManager = .default) -> URL? {
        var directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            directory.deleteLastPathComponent()
        }

        // Walk plain file-system paths instead of repeatedly deriving NSURL
        // parents. Save-as can hand NSDocument a bookmark-backed URL whose
        // parent URL does not stabilize at the volume root, which otherwise
        // turns this synchronous UI refresh into an unbounded allocation loop.
        for path in ancestorPaths(startingAt: directory.path) {
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
        }
        return nil
    }

    static func ancestorPaths(startingAt path: String) -> [String] {
        var current = (path as NSString).standardizingPath
        var visited: Set<String> = []
        var result: [String] = []

        while !current.isEmpty, visited.insert(current).inserted {
            result.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != current else { break }
            current = parent
        }
        return result
    }

    public static func snapshot(containing url: URL,
                                fileManager: FileManager = .default) -> GitRepositorySnapshot? {
        guard let root = nearestRoot(from: url, fileManager: fileManager),
              let output = runGit(["status", "--porcelain=v1", "-z", "--branch", "--ignored=matching"],
                                  at: root) else { return nil }
        return parseStatus(output, rootURL: root)
    }

    /// Reads this file's content from the current HEAD. A file inside a Git
    /// worktree but absent from HEAD is reported as untracked.
    public static func baseline(for fileURL: URL) -> GitFileBaseline? {
        guard let root = nearestRoot(from: fileURL) else { return nil }
        let rootPath = root.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(path.dropFirst(rootPath.count + 1))
        guard let content = runGit(["show", "HEAD:\(relativePath)"], at: root) else {
            return .untracked
        }
        return .tracked(normalizeLineEndings(content))
    }

    private static func normalizeLineEndings(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func parseStatus(_ output: String, rootURL: URL) -> GitRepositorySnapshot {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var branch = "HEAD"
        var changes: [GitFileChange] = []
        var index = 0

        if let first = records.first, first.hasPrefix("## ") {
            let description = String(first.dropFirst(3))
            branch = description.components(separatedBy: "...").first ?? description
            index = 1
        }

        while index < records.count {
            let record = records[index]
            guard record.utf8.count >= 3 else { index += 1; continue }
            let chars = Array(record)
            let x = chars[0]
            let y = chars[1]
            var path = String(chars.dropFirst(3))
            // In -z mode a rename/copy record is followed by its old path. The
            // first path is the destination, which is what the sidebar opens.
            if x == "R" || x == "C" || y == "R" || y == "C" {
                index += 1
                if path.isEmpty, index < records.count { path = records[index] }
            }
            changes.append(GitFileChange(path: path, indexStatus: x, workTreeStatus: y))
            index += 1
        }

        changes.sort {
            if $0.isIgnored != $1.isIgnored { return !$0.isIgnored }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return GitRepositorySnapshot(rootURL: rootURL, branch: branch, changes: changes)
    }

    static func runGit(_ arguments: [String], at root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            // Drain before waiting: a repository with many ignored/untracked
            // paths can fill the pipe buffer and deadlock waitUntilExit().
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
