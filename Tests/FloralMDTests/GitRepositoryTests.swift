import Foundation
import Testing
@testable import FloralMDCore

@Suite("Git repository discovery and status")
struct GitRepositoryTests {
    @Test("Finds the nearest repository above a document")
    func nearestRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-GitRoot-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("notes/daily")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = nested.appendingPathComponent("today.md")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(GitRepository.nearestRoot(from: file) == root.standardizedFileURL)
    }

    @Test("Stops repository discovery at the file-system root")
    func nearestRootStopsOutsideRepositories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-NoGitRoot-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("notes/daily")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = nested.appendingPathComponent("draft.md")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(GitRepository.nearestRoot(from: file) == nil)
        let ancestors = GitRepository.ancestorPaths(startingAt: file.deletingLastPathComponent().path)
        #expect(ancestors.first == nested.standardizedFileURL.path)
        #expect(ancestors.last == "/")
        #expect(Set(ancestors).count == ancestors.count)
    }

    @Test("Parses branch and file states from porcelain output")
    func parseStatus() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let output = "## main...origin/main\0 M notes/a.md\0A  notes/b.md\0?? draft.md\0!! cache/\0"
        let snapshot = GitRepository.parseStatus(output, rootURL: root)

        #expect(snapshot.branch == "main")
        #expect(snapshot.changes.map(\.path) == ["draft.md", "notes/a.md", "notes/b.md", "cache/"])
        #expect(snapshot.changes.first { $0.path == "notes/b.md" }?.isStaged == true)
        #expect(snapshot.changes.first { $0.path == "draft.md" }?.isUntracked == true)
        #expect(snapshot.changes.last?.isIgnored == true)
    }

    @Test("Propagates the strongest descendant state to folders")
    func folderState() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let snapshot = GitRepository.parseStatus(
            "## main\0 M notes/a.md\0?? notes/drafts/new.md\0UU notes/conflict.md\0",
            rootURL: root
        )

        #expect(snapshot.state(forRelativePath: "notes", isDirectory: true) == .conflicted)
        #expect(snapshot.state(forRelativePath: "notes/a.md", isDirectory: false) == .modified)
        #expect(snapshot.state(forRelativePath: "notes/drafts", isDirectory: true) == .untracked)
        #expect(snapshot.state(forRelativePath: "elsewhere", isDirectory: true) == nil)
    }

    @Test("Overlays an unsaved tracked-file modification without running Git")
    func unsavedModificationOverlay() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let clean = GitRepositorySnapshot(rootURL: root, branch: "main", changes: [])
        let modified = clean.overlayingWorkTreeState(
            for: root.appendingPathComponent("notes/current.md"),
            differsFromHEAD: true
        )

        #expect(modified.changes == [
            GitFileChange(path: "notes/current.md", indexStatus: " ", workTreeStatus: "M")
        ])
        #expect(modified.state(forRelativePath: "notes/current.md",
                               isDirectory: false) == .modified)
    }

    @Test("Unsaved overlay preserves staged and untracked Git states")
    func unsavedOverlayPreservesExistingState() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let snapshot = GitRepository.parseStatus(
            "## main\0A  staged.md\0?? draft.md\0", rootURL: root
        )

        let staged = snapshot.overlayingWorkTreeState(
            for: root.appendingPathComponent("staged.md"),
            differsFromHEAD: true
        )
        #expect(staged.changes.first { $0.path == "staged.md" } ==
                GitFileChange(path: "staged.md", indexStatus: "A", workTreeStatus: "M"))

        let untracked = snapshot.overlayingWorkTreeState(
            for: root.appendingPathComponent("draft.md"),
            differsFromHEAD: true
        )
        #expect(untracked.changes.first { $0.path == "draft.md" }?.isUntracked == true)
    }

    @Test("Unsaved overlay clears a stale work-tree modification on HEAD reversion")
    func unsavedOverlayClearsModification() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let snapshot = GitRepository.parseStatus(
            "## main\0 M current.md\0M  staged.md\0UU conflicted.md\0",
            rootURL: root
        )

        let current = snapshot.overlayingWorkTreeState(
            for: root.appendingPathComponent("current.md"),
            differsFromHEAD: false
        )
        #expect(current.changes.contains { $0.path == "current.md" } == false)

        let staged = snapshot.overlayingWorkTreeState(
            for: root.appendingPathComponent("staged.md"),
            differsFromHEAD: false
        )
        #expect(staged.changes.first { $0.path == "staged.md" } ==
                GitFileChange(path: "staged.md", indexStatus: "M", workTreeStatus: " "))

        let conflicted = snapshot.overlayingWorkTreeState(
            for: root.appendingPathComponent("conflicted.md"),
            differsFromHEAD: false
        )
        #expect(conflicted.changes.first { $0.path == "conflicted.md" }?.pathState == .conflicted)
    }

    @Test("Maps current lines changed from HEAD-style baseline")
    func changedLines() {
        let changed = GitLineChanges.changedLineIndexes(
            baseline: .tracked("one\ntwo\nthree"),
            current: "one\nTWO\nthree\nfour"
        )
        #expect(changed == [1, 3])
    }

    @Test("Distinguishes inserted lines from replacements")
    func lineChangeKinds() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("one\ntwo\nthree"),
            current: "one\nnew\ntwo\nTHREE"
        )
        #expect(changes.lines == [1: .added, 3: .modified])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Classifies an inserted blank line as added")
    func insertedBlankLine() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("one\ntwo"),
            current: "one\n\ntwo"
        )
        #expect(changes.lines == [1: .added])
    }

    @Test("Bridges unchanged blank separators inside a changed region")
    func changedRegionBlankSeparator() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("old heading\n\nold body\n\nunchanged"),
            current: "new heading\n\nnew body\n\nunchanged"
        )
        #expect(changes.lines[0] == .modified)
        #expect(changes.lines[1] == .modified)
        #expect(changes.lines[2] == .modified)
        #expect(changes.lines[3] == nil,
                "the blank line outside the changed region must stay unmarked")
    }

    @Test("Marks every line of an untracked file")
    func untrackedLines() {
        #expect(GitLineChanges.changedLineIndexes(
            baseline: .untracked,
            current: "one\ntwo"
        ) == [0, 1])
    }

    @Test("Represents a deletion as an inter-line boundary")
    func deletedLine() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("one\ntwo\nthree"),
            current: "one\nthree"
        )
        #expect(changes.lines.isEmpty)
        #expect(changes.deletionBoundaries == [1])
    }

    @Test("Unequal replacement keeps unmatched old lines as deletions")
    func unequalReplacementKeepsDeletion() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("one\nold A\nold B\nthree"),
            current: "one\nnew\nthree"
        )
        #expect(changes.lines == [1: .modified])
        #expect(changes.deletionBoundaries == [2])
    }

    @Test("Deleting characters at line end remains a line modification")
    func lineEndCharacterDeletionIsModified() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("heading with suffix\nnext"),
            current: "heading\nnext"
        )
        #expect(changes.lines == [0: .modified])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Appending characters at line end remains a line modification")
    func lineEndCharacterInsertionIsModified() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("heading\nnext"),
            current: "heading with suffix\nnext"
        )
        #expect(changes.lines == [0: .modified])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Adjacent new line stays added after a modified line")
    func adjacentNewLineStaysAdded() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("before\nold line\nafter"),
            current: "before\nedited line\nbrand new\nafter"
        )
        #expect(changes.lines == [1: .modified, 2: .added])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Editing a line to match its predecessor remains a modification")
    func duplicatePredecessorDoesNotStealAnchor() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("A\nB\nC"),
            current: "A\nA\nC"
        )
        #expect(changes.lines == [1: .modified])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Editing a duplicate line remains a modification")
    func replacingDuplicateLineDoesNotShiftAnchor() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("A\nA\nC"),
            current: "A\nB\nC"
        )
        #expect(changes.lines == [1: .modified])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Splitting one line produces one modification and one addition")
    func splitLineSeparatesModificationAndAddition() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("before\nalpha beta\nafter"),
            current: "before\nalpha\nbeta\nafter"
        )
        #expect(changes.lines == [1: .modified, 2: .added])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Adjacent inserted blank and text lines stay added")
    func adjacentBlankAndTextLinesStayAdded() {
        let changes = GitLineChanges.changes(
            baseline: .tracked("before\nold line\nafter"),
            current: "before\nedited line\n\nbrand new\nafter"
        )
        #expect(changes.lines == [1: .modified, 2: .added, 3: .added])
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Separates modified and newly added lines inside a changelog rewrite")
    func changelogRewrite() {
        let baseline = """
        # Changelog

        Old introduction.

        ## [0.2.0]

        ### Added
        - Existing feature with old wording.
        - Stable feature.

        ### Fixed
        - Existing fix with old wording.
        """
        let current = """
        # Changelog

        Rewritten introduction on one line,
        continued on another line.

        ## [0.2.1]

        ### Added
        - Existing feature with revised wording.
        - Stable feature.
        - Completely new watchdog feature.

        ### Fixed
        - Existing fix with revised wording.
        """

        let changes = GitLineChanges.changes(
            baseline: .tracked(baseline), current: current
        )

        #expect(changes.lines[5] == .modified,
                "the edited version heading must be blue")
        #expect(changes.lines[8] == .modified,
                "an edited existing bullet must be blue")
        #expect(changes.lines[10] == .added,
                "an unrelated new bullet in the same section must stay green")
        #expect(changes.lines[13] == .modified,
                "the edited existing fix must be blue")
    }

    @Test("Large rewritten hunk classifies without character-pair diffing")
    func largeRewrittenHunk() {
        let baseline = (0..<200).map { "old paragraph \($0)" }.joined(separator: "\n")
        let current = (0..<200).map { "new paragraph \($0)" }.joined(separator: "\n")

        let changes = GitLineChanges.changes(
            baseline: .tracked(baseline), current: current
        )

        #expect(changes.lines.count == 200)
        #expect(changes.lines.values.allSatisfy { $0 == .modified })
        #expect(changes.deletionBoundaries.isEmpty)
    }

    @Test("Git gutter marker survives activating its Markdown block")
    @MainActor
    func markerSurvivesActiveRestyle() {
        let editor = makeEditor()
        editor.loadContent("changed line\nclean line")
        editor.gitChangeSet = GitLineChangeSet(lines: [0: .modified])
        #expect(editor.textStorage?.attribute(.gitChangeMarker, at: 0,
                                              effectiveRange: nil) as? GitLineChangeKind == .modified)

        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.applyBlockStyle()

        #expect(editor.textStorage?.attribute(.gitChangeMarker, at: 0,
                                              effectiveRange: nil) as? GitLineChangeKind == .modified)
    }

    @Test("Blank-line gutter marker survives activating the adjacent block")
    @MainActor
    func blankMarkerSurvivesAdjacentRestyle() {
        let editor = makeEditor()
        editor.loadContent("first\n\nthird")
        editor.gitChangeSet = GitLineChangeSet(lines: [1: .added])
        #expect(editor.textStorage?.attribute(.gitChangeMarker, at: 6,
                                              effectiveRange: nil) as? GitLineChangeKind == .added)

        let thirdBlock = editor.blocks[1].range.location
        editor.setSelectedRange(NSRange(location: thirdBlock, length: 0))
        editor.recomposeIncremental(cursorInRaw: thirdBlock,
                                    settingSelection: false)

        #expect(editor.textStorage?.attribute(.gitChangeMarker, at: 6,
                                              effectiveRange: nil) as? GitLineChangeKind == .added)
    }

    @Test("Blank-line marker vends a decorated layout fragment")
    @MainActor
    func blankMarkerCreatesLayoutFragment() {
        let editor = makeEditor()
        editor.loadContent("first\n\nthird")
        editor.gitChangeSet = GitLineChangeSet(lines: [1: .modified])
        ensureFullLayout(editor)

        var kinds: [GitLineChangeKind] = []
        guard let layoutManager = editor.textLayoutManager else {
            Issue.record("missing text layout manager")
            return
        }
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            if let decorated = fragment as? DecoratedTextLayoutFragment,
               let kind = decorated.gitChange {
                kinds.append(kind)
            }
            return true
        }
        #expect(kinds.contains(.modified))
    }

    @Test("Deletion boundary vends a separate red-triangle fragment marker")
    @MainActor
    func deletionBoundaryCreatesSeparateMarker() throws {
        let editor = makeEditor()
        editor.loadContent("one\nnew\nthree")
        editor.gitChangeSet = GitLineChangeSet(
            lines: [1: .modified], deletionBoundaries: [2]
        )

        #expect(editor.textStorage?.attribute(.gitChangeMarker, at: 4,
                                              effectiveRange: nil) as? GitLineChangeKind == .modified)
        #expect(editor.textStorage?.attribute(.gitDeletionMarker, at: 4,
                                              effectiveRange: nil) as? Set<GitDeletionEdge> == [.after])

        ensureFullLayout(editor)
        let layoutManager = try #require(editor.textLayoutManager)
        var deletionFragment: DecoratedTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let decorated = fragment as? DecoratedTextLayoutFragment,
                  !decorated.gitDeletionEdges.isEmpty else { return true }
            deletionFragment = decorated
            return false
        }
        let fragment = try #require(deletionFragment)
        for edge in [GitDeletionEdge.before, .after] {
            let triangle = DecoratedTextLayoutFragment.gitDeletionTriangleBounds(
                edge: edge, fragmentHeight: fragment.layoutFragmentFrame.height
            )
            #expect(triangle.minY >= 0)
            #expect(triangle.maxY <= fragment.layoutFragmentFrame.height,
                    "the adjacent fragment must not cover part of the triangle")
        }
    }
}
