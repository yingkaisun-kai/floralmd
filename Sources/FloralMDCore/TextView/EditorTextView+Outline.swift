import Foundation

/// One heading exposed to app-shell outline/navigation UI.
public struct MarkdownOutlineItem: Equatable, Sendable {
    public let level: Int
    public let title: String

    public init(level: Int, title: String) {
        self.level = level
        self.title = title
    }
}

public extension EditorTextView {
    /// A lightweight snapshot of the document headings. The editor's parsed
    /// block model remains the single source of truth, so outline UI never
    /// reparses Markdown independently or mutates text storage.
    func outlineItems() -> [MarkdownOutlineItem] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            let title = Self.headingText(block.content)
            return title.isEmpty ? nil : MarkdownOutlineItem(level: level, title: title)
        }
    }
}
