import Foundation

public struct GitCommit: Equatable, Sendable {
    public let id: String
    public let parentIDs: [String]
    public let subject: String
    public let author: String
    public let authoredAt: Date?
    public let authoredAtText: String
    public let localBranches: [String]

    public var shortID: String { String(id.prefix(7)) }
}

public struct GitHistorySnapshot: Equatable, Sendable {
    public let rootURL: URL
    public let headID: String?
    public let currentBranch: String?
    public let commits: [GitCommit]
}

public struct GitHistoryRowPresentation: Equatable, Sendable {
    public let headLabel: String?
    public let branchLabel: String?
    public let subject: String

    public init(commit: GitCommit, isHEAD: Bool) {
        headLabel = isHEAD ? "HEAD" : nil
        branchLabel = commit.localBranches.first
        subject = commit.subject
    }
}

public struct GitGraphRow: Equatable, Sendable {
    public let commitLane: Int
    public let incomingLanes: [String]
    public let outgoingLanes: [String]
    public let parentLanes: [Int]

    public var laneCount: Int {
        max(incomingLanes.count, outgoingLanes.count)
    }
}

public struct GitGraphPoint: Equatable, Sendable {
    public let x: CGFloat
    public let y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

public enum GitGraphSegment: Equatable, Sendable {
    case line(start: GitGraphPoint, end: GitGraphPoint)
    case cubic(start: GitGraphPoint, control1: GitGraphPoint,
               control2: GitGraphPoint, end: GitGraphPoint)
}

public enum GitGraphGeometry {
    /// Cross-lane connectors keep a vertical tangent at both ends so a branch
    /// leaves and joins its lane without an ambiguous diagonal corner.
    public static func connector(from start: GitGraphPoint,
                                 to end: GitGraphPoint) -> GitGraphSegment {
        guard start.x != end.x else { return .line(start: start, end: end) }
        let middleY = (start.y + end.y) / 2
        return .cubic(
            start: start,
            control1: GitGraphPoint(x: start.x, y: middleY),
            control2: GitGraphPoint(x: end.x, y: middleY),
            end: end
        )
    }
}

public enum GitGraphLayout {
    /// Assigns stable lanes to a topologically ordered commit list. Git owns
    /// the DAG and ordering; this model only turns parent relationships into
    /// row-local drawing coordinates.
    public static func rows(for commits: [GitCommit]) -> [GitGraphRow] {
        var activeLanes: [String] = []
        var rows: [GitGraphRow] = []

        for commit in commits {
            if !activeLanes.contains(commit.id) {
                activeLanes.insert(commit.id, at: 0)
            }
            let incoming = activeLanes
            let commitLane = activeLanes.firstIndex(of: commit.id) ?? 0
            activeLanes.remove(at: commitLane)

            var parentLanes: [Int] = []
            for (offset, parentID) in commit.parentIDs.enumerated() {
                if let existing = activeLanes.firstIndex(of: parentID) {
                    parentLanes.append(existing)
                    continue
                }
                let insertion = min(commitLane + offset, activeLanes.count)
                activeLanes.insert(parentID, at: insertion)
                parentLanes.append(insertion)
            }

            rows.append(GitGraphRow(
                commitLane: commitLane,
                incomingLanes: incoming,
                outgoingLanes: activeLanes,
                parentLanes: parentLanes
            ))
        }
        return rows
    }
}

public extension GitRepository {
    static func history(containing url: URL, limit: Int = 80) -> GitHistorySnapshot? {
        guard let root = nearestRoot(from: url) else { return nil }
        let branch = runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headID = runGit(["rev-parse", "--verify", "HEAD"], at: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let headID, !headID.isEmpty else {
            return GitHistorySnapshot(
                rootURL: root,
                headID: nil,
                currentBranch: branch?.isEmpty == false ? branch : nil,
                commits: []
            )
        }

        guard let log = runGit([
            "log", "HEAD", "--branches", "--topo-order", "--no-color",
            "--max-count=\(max(1, limit))",
            "--format=%H%x00%P%x00%s%x00%an%x00%aI",
        ], at: root) else { return nil }
        let refsOutput = runGit([
            "for-each-ref", "--format=%(objectname)%00%(refname:short)", "refs/heads",
        ], at: root) ?? ""
        let branchesByCommit = parseLocalBranches(refsOutput)
        let commits = parseLog(log, localBranchesByCommit: branchesByCommit)
        return GitHistorySnapshot(
            rootURL: root,
            headID: headID,
            currentBranch: branch?.isEmpty == false ? branch : nil,
            commits: commits
        )
    }

    static func parseLog(_ output: String,
                         localBranchesByCommit: [String: [String]] = [:]) -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, !fields[0].isEmpty else { return nil }
            return GitCommit(
                id: fields[0],
                parentIDs: fields[1].split(separator: " ").map(String.init),
                subject: fields[2],
                author: fields[3],
                authoredAt: formatter.date(from: fields[4]),
                authoredAtText: fields[4],
                localBranches: localBranchesByCommit[fields[0], default: []].sorted()
            )
        }
    }

    static func parseLocalBranches(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            result[fields[0], default: []].append(fields[1])
        }
        return result
    }
}
