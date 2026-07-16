import AppKit

/// Source-based coordinate system shared by every minimap element.
///
/// Physical source lines are split into estimated visual rows using the
/// editor's current wrap column. This accounts for long wrapped paragraphs
/// without asking TextKit 2 to lay out every off-screen fragment. Rows keep
/// their natural pitch until the document exceeds the minimap's usable height;
/// only then is the whole coordinate space compressed.
public struct DocumentMinimapCoordinateModel {
    public struct SemanticRow: Equatable {
        public let lineIndex: Int
        public let sourceRange: NSRange
        public let y: CGFloat
    }

    private struct SourceLine {
        let sourceStart: Int
        let contentLength: Int
        let rowStart: Int
        let rowCount: Int
    }

    public let sourceLength: Int
    public let lineCount: Int
    public let semanticRows: [SemanticRow]
    public let rowPitch: CGFloat
    public let contentRange: ClosedRange<CGFloat>

    private let lines: [SourceLine]
    private let topInset: CGFloat
    private let wrapColumn: Int

    public init(source: String,
                viewportHeight: CGFloat,
                wrapColumn: Int,
                contentInset: CGFloat = 4,
                naturalRowPitch: CGFloat = 3) {
        let ns = source as NSString
        sourceLength = ns.length
        self.wrapColumn = max(1, wrapColumn)
        topInset = max(0, contentInset)

        var parsedLines: [SourceLine] = []
        var rowSpecs: [(lineIndex: Int, range: NSRange)] = []
        var lineStart = 0
        var lineIndex = 0

        while lineStart <= ns.length {
            let searchRange = NSRange(location: lineStart, length: ns.length - lineStart)
            let newline = ns.range(of: "\n", options: [], range: searchRange)
            let contentEnd = newline.location == NSNotFound ? ns.length : newline.location
            let contentLength = contentEnd - lineStart
            let rowCount = max(1, (max(1, contentLength) + self.wrapColumn - 1)
                                   / self.wrapColumn)
            let rowStart = rowSpecs.count

            for rowIndex in 0..<rowCount {
                let localStart = min(contentLength, rowIndex * self.wrapColumn)
                let remaining = max(0, contentLength - localStart)
                let length = min(self.wrapColumn, remaining)
                rowSpecs.append((
                    lineIndex,
                    NSRange(location: lineStart + localStart, length: length)
                ))
            }
            parsedLines.append(SourceLine(sourceStart: lineStart,
                                          contentLength: contentLength,
                                          rowStart: rowStart,
                                          rowCount: rowCount))

            guard newline.location != NSNotFound else { break }
            lineStart = newline.location + newline.length
            lineIndex += 1
        }

        lines = parsedLines
        lineCount = parsedLines.count
        let usableHeight = max(0, viewportHeight - 2 * topInset)
        let naturalHeight = CGFloat(rowSpecs.count) * max(0, naturalRowPitch)
        let contentHeight = min(usableHeight, naturalHeight)
        let resolvedRowPitch = rowSpecs.isEmpty
            ? 0 : contentHeight / CGFloat(rowSpecs.count)
        rowPitch = resolvedRowPitch
        let resolvedContentRange = topInset...(topInset + contentHeight)
        contentRange = resolvedContentRange
        semanticRows = rowSpecs.enumerated().map { index, spec in
            SemanticRow(lineIndex: spec.lineIndex,
                        sourceRange: spec.range,
                        y: resolvedContentRange.lowerBound
                            + CGFloat(index) * resolvedRowPitch)
        }
    }

    public func y(forUTF16Offset offset: Int) -> CGFloat {
        topInset + semanticPosition(forUTF16Offset: offset) * rowPitch
    }

    public func rowOriginY(forUTF16Offset offset: Int) -> CGFloat {
        guard !semanticRows.isEmpty else { return topInset }
        let position = min(CGFloat(semanticRows.count) - .ulpOfOne,
                           max(0, semanticPosition(forUTF16Offset: offset)))
        return topInset + floor(position) * rowPitch
    }

    public func y(forLineBoundary boundary: Int) -> CGFloat {
        guard !lines.isEmpty else { return topInset }
        if boundary <= 0 { return topInset }
        if boundary >= lines.count { return contentRange.upperBound }
        return topInset + CGFloat(lines[boundary].rowStart) * rowPitch
    }

    public func sourceOffset(atY y: CGFloat) -> Int {
        guard !semanticRows.isEmpty, rowPitch > 0 else { return 0 }
        if y <= contentRange.lowerBound { return 0 }
        if y >= contentRange.upperBound { return sourceLength }

        let position = (y - topInset) / rowPitch
        let rowIndex = min(semanticRows.count - 1, max(0, Int(floor(position))))
        let row = semanticRows[rowIndex]
        guard row.sourceRange.length > 0 else { return row.sourceRange.location }
        let fraction = min(1, max(0, position - CGFloat(rowIndex)))
        let local = Int((fraction * CGFloat(row.sourceRange.length)).rounded())
        return min(sourceLength, row.sourceRange.location + local)
    }

    public func viewportRect(for sourceRange: NSRange,
                             minimumHeight: CGFloat = 18) -> NSRect {
        guard contentRange.upperBound > contentRange.lowerBound else {
            return NSRect(x: 0, y: topInset, width: 0, height: 0)
        }
        let clampedStart = min(sourceLength, max(0, sourceRange.location))
        let clampedEnd = min(sourceLength, max(clampedStart, sourceRange.upperBound))

        if clampedStart == 0, clampedEnd == sourceLength {
            return NSRect(x: 0, y: contentRange.lowerBound,
                          width: 0, height: contentRange.upperBound - contentRange.lowerBound)
        }

        let startY = y(forUTF16Offset: clampedStart)
        let endY = y(forUTF16Offset: clampedEnd)
        let rawHeight = max(rowPitch, endY - startY)
        let height = min(contentRange.upperBound - contentRange.lowerBound,
                         max(minimumHeight, rawHeight))
        let centeredY = (startY + endY - height) / 2
        let y = min(contentRange.upperBound - height,
                    max(contentRange.lowerBound, centeredY))
        return NSRect(x: 0, y: y, width: 0, height: height)
    }

    private func semanticPosition(forUTF16Offset offset: Int) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let clamped = min(sourceLength, max(0, offset))
        if sourceLength > 0, clamped == sourceLength {
            return CGFloat(semanticRows.count)
        }

        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].sourceStart <= clamped {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let line = lines[max(0, low - 1)]
        let local = min(line.contentLength, max(0, clamped - line.sourceStart))
        guard line.contentLength > 0 else { return CGFloat(line.rowStart) }
        if local == line.contentLength {
            return CGFloat(line.rowStart + line.rowCount)
        }

        let rowInLine = min(line.rowCount - 1, local / wrapColumn)
        let rowStart = rowInLine * wrapColumn
        let rowLength = min(wrapColumn, line.contentLength - rowStart)
        let fraction = CGFloat(local - rowStart) / CGFloat(max(1, rowLength))
        return CGFloat(line.rowStart + rowInLine) + fraction
    }
}
