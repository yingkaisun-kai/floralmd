import AppKit

// MARK: - Table Rendering Support
//
// Helpers used by the `.table` branch of `styleBlock` (in
// EditorTextView+Rendering.swift) to lay out GFM tables:
// `splitTableRow` / `cellRanges` parse a pipe-delimited row into its cells.
//
// A rendered table is a run of consecutive single-line paragraphs (one per
// table row) that the BlockParser merges into a single block. Each row
// carries a `.tableRow` BlockDecoration; because every row uses the same
// column X offsets, the per-row vertical strokes line up into continuous
// column borders.

// MARK: - Column Alignment

/// GFM table column alignment, parsed from the separator row's `:` markers.
enum ColumnAlign: Equatable { case left, center, right }

/// Fits natural table-column widths into the editor column while preserving a
/// shared grid. Columns keep their natural size when possible; when the table
/// is wider than the editor, each column receives a readable minimum and the
/// remaining width is distributed in proportion to its natural excess.
func fittedTableColumnWidths(_ natural: [CGFloat], maximumWidth: CGFloat,
                             minimumWidth: CGFloat) -> [CGFloat] {
    guard !natural.isEmpty else { return [] }
    let cap = max(CGFloat(natural.count), maximumWidth)
    let count = CGFloat(natural.count)
    // A long path/hash/unbroken word must not monopolize the table even when
    // the other columns are tiny. Two columns may use at most 60% each; wider
    // tables progressively approach an even split while still allowing short
    // columns to stay compact.
    let maximumShare = min(CGFloat(0.60), max(CGFloat(0.35), CGFloat(1.35) / count))
    let perColumnCap = cap * maximumShare
    let limited = natural.map { min($0, perColumnCap) }
    if natural.reduce(0, +) <= cap && natural.allSatisfy({ $0 <= perColumnCap }) {
        return natural
    }
    if limited.reduce(0, +) <= cap { return limited }

    let floor = min(minimumWidth, cap / count)
    let availableExtra = max(0, cap - floor * count)
    let naturalExtra = limited.reduce(CGFloat(0)) { total, width in
        total + max(0, width - floor)
    }
    guard naturalExtra > 0 else {
        return [CGFloat](repeating: cap / count, count: natural.count)
    }
    return limited.map { width in
        floor + availableExtra * max(0, width - floor) / naturalExtra
    }
}

/// Word wrapping is preferable for prose, but AppKit cannot keep an oversized
/// path/hash/identifier inside a narrow cell without a character-break mode.
/// Detect only runs that exceed the actual content rectangle, so ordinary
/// English continues to wrap at spaces.
func tableCellNeedsCharacterWrapping(_ cell: NSAttributedString,
                                     contentWidth: CGFloat) -> Bool {
    guard cell.length > 0, contentWidth > 0 else { return false }
    let regex = try! NSRegularExpression(pattern: "\\S+")
    let whole = NSRange(location: 0, length: cell.length)
    var exceeds = false
    regex.enumerateMatches(in: cell.string, range: whole) { match, _, stop in
        guard let range = match?.range, range.length > 0 else { return }
        let run = cell.attributedSubstring(from: range)
        if ceil(run.size().width) > contentWidth {
            exceeds = true
            stop.pointee = true
        }
    }
    return exceeds
}

/// Parses per-column alignment from a table's separator row (`:--`/`:-:`/`--:`).
/// `:` on both ends = center, trailing only = right, otherwise left. Padded to
/// `count` with `.left`. Mirrors swift-markdown's `Table.columnAlignments`, so
/// the live editor and the HTML export agree.
func tableColumnAlignments(separatorRow: String, count: Int) -> [ColumnAlign] {
    var aligns = [ColumnAlign](repeating: .left, count: count)
    let cells = splitTableRow(separatorRow)
    for ci in 0..<min(cells.count, count) {
        let t = cells[ci].trimmingCharacters(in: .whitespaces)
        let lead = t.hasPrefix(":")
        let trail = t.hasSuffix(":")
        aligns[ci] = (lead && trail) ? .center : (trail ? .right : .left)
    }
    return aligns
}

// MARK: - Table Row Parsing

/// Splits a markdown table row into cell strings (text between pipes).
/// Handles both `| A | B |` (outer pipes) and `A | B` (no outer pipes).
/// A `\|` is escaped content, not a cell separator (GFM Example 200).
func splitTableRow(_ line: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var prevWasBackslash = false
    for ch in line {
        if ch == "|" && !prevWasBackslash {
            parts.append(current)
            current = ""
        } else {
            current.append(ch)
        }
        prevWasBackslash = (ch == "\\") && !prevWasBackslash
    }
    parts.append(current)

    // Remove empty/whitespace-only first/last from outer pipes.
    if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeFirst()
    }
    if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeLast()
    }
    return parts
}

/// Returns `(start, end)` character ranges for each cell in a table line.
/// Works with or without outer pipes. `start` is the first content char,
/// `end` is one past the last content char (i.e., the next pipe or line end).
func cellRanges(in line: NSString) -> [(start: Int, end: Int)] {
    var pipePos: [Int] = []
    for ci in 0..<line.length {
        guard line.character(at: ci) == 0x7C else { continue }
        // A `\|` is escaped content, not a cell separator (GFM Example 200).
        if ci > 0 && line.character(at: ci - 1) == 0x5C { continue }
        pipePos.append(ci)
    }
    guard !pipePos.isEmpty else { return [] }

    // Build edge list: either the pipe position or a virtual -1/length sentinel.
    var edges: [Int] = []
    if pipePos[0] == 0 {
        edges.append(contentsOf: pipePos)
    } else {
        edges.append(-1)
        edges.append(contentsOf: pipePos)
    }
    if pipePos.last != line.length - 1 {
        edges.append(line.length)
    }

    var result: [(start: Int, end: Int)] = []
    for ei in 0..<(edges.count - 1) {
        let s = edges[ei] + 1
        let e = edges[ei + 1]
        // Preserve an empty middle cell (`a || c`). Dropping its zero-length
        // range would shift every following cell one column to the left.
        if e >= s { result.append((s, e)) }
    }
    return result
}
