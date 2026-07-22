import Foundation
import Testing
@testable import FloralMDCore

@Suite("Git history and graph layout")
struct GitHistoryTests {
    @Test("Parses commit metadata and local branch decorations")
    func parseHistory() throws {
        let output = [
            "ccccccc\0bbbbbbb aaaaaaa\0Merge topic\0Kai\02026-07-22T12:30:00+08:00",
            "bbbbbbb\0aaaaaaa\0Topic work\0Kai\02026-07-22T12:00:00+08:00",
        ].joined(separator: "\n")
        let commits = GitRepository.parseLog(
            output,
            localBranchesByCommit: ["ccccccc": ["main"], "bbbbbbb": ["topic"]]
        )

        #expect(commits.count == 2)
        #expect(commits[0].parentIDs == ["bbbbbbb", "aaaaaaa"])
        #expect(commits[0].subject == "Merge topic")
        #expect(commits[0].localBranches == ["main"])
        #expect(commits[0].authoredAt != nil)
        #expect(commits[1].localBranches == ["topic"])
    }

    @Test("Assigns one lane to linear history")
    func linearLayout() {
        let commits = [
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ]
        let rows = GitGraphLayout.rows(for: commits)

        #expect(rows.map(\.commitLane) == [0, 0, 0])
        #expect(rows.map(\.laneCount) == [1, 1, 1])
        #expect(rows.last?.outgoingLanes.isEmpty == true)
    }

    @Test("Keeps both parents visible until a merge closes")
    func mergeLayout() {
        let commits = [
            commit("m", parents: ["b", "t"]),
            commit("t", parents: ["a"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ]
        let rows = GitGraphLayout.rows(for: commits)

        #expect(rows[0].commitLane == 0)
        #expect(rows[0].outgoingLanes == ["b", "t"])
        #expect(rows[0].parentLanes == [0, 1])
        #expect(rows[1].commitLane == 1)
        #expect(rows[2].commitLane == 0)
        #expect(rows[3].outgoingLanes.isEmpty)
    }

    @Test("HEAD label is part of the row before selection")
    func headPresentation() {
        let head = GitHistoryRowPresentation(commit: commit("head", parents: ["parent"]),
                                             isHEAD: true)
        let ordinary = GitHistoryRowPresentation(commit: commit("parent", parents: []),
                                                 isHEAD: false)

        #expect(head.headLabel == "HEAD")
        #expect(ordinary.headLabel == nil)
    }

    @Test("Straight lanes stay lines and cross-lane connections are smooth cubics")
    func connectorGeometry() {
        let straight = GitGraphGeometry.connector(
            from: GitGraphPoint(x: 6, y: 0),
            to: GitGraphPoint(x: 6, y: 22)
        )
        let curve = GitGraphGeometry.connector(
            from: GitGraphPoint(x: 6, y: 22),
            to: GitGraphPoint(x: 33, y: 45)
        )

        #expect(straight == .line(
            start: GitGraphPoint(x: 6, y: 0),
            end: GitGraphPoint(x: 6, y: 22)
        ))
        #expect(curve == .cubic(
            start: GitGraphPoint(x: 6, y: 22),
            control1: GitGraphPoint(x: 6, y: 33.5),
            control2: GitGraphPoint(x: 33, y: 33.5),
            end: GitGraphPoint(x: 33, y: 45)
        ))
    }

    @Test("Unmerged branch and four lanes retain deterministic lane ownership")
    func multiLaneLayout() {
        let commits = [
            commit("tip", parents: ["main", "experiment"]),
            commit("experiment", parents: ["base", "side-a", "side-b"]),
            commit("main", parents: ["base"]),
            commit("side-a", parents: ["base"]),
            commit("side-b", parents: ["base"]),
            commit("base", parents: []),
        ]
        let rows = GitGraphLayout.rows(for: commits)

        #expect(rows[0].outgoingLanes == ["main", "experiment"])
        #expect(rows[1].commitLane == 1)
        #expect(rows[1].outgoingLanes == ["main", "base", "side-a", "side-b"])
        #expect(rows[1].parentLanes == [1, 2, 3])
        #expect(rows.last?.outgoingLanes.isEmpty == true)
    }

    private func commit(_ id: String, parents: [String]) -> GitCommit {
        GitCommit(
            id: id,
            parentIDs: parents,
            subject: id,
            author: "Kai",
            authoredAt: nil,
            authoredAtText: "",
            localBranches: []
        )
    }
}
