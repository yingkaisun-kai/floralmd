import Foundation

public struct MarkdownDirectoryEntry: Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

public enum MarkdownDirectory {
    public static let extensions = Set(["md", "markdown", "mdown", "mkd"])

    /// Lists visible folders and Markdown files, with folders first. Other
    /// files are intentionally omitted: this sidebar is document navigation,
    /// not a general-purpose Finder replacement.
    public static func entries(at directory: URL,
                               fileManager: FileManager = .default) -> [MarkdownDirectoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isHidden != true else { return nil }
            let isDirectory = values?.isDirectory == true
            guard isDirectory || extensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }
            return MarkdownDirectoryEntry(url: url, isDirectory: isDirectory)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                == .orderedAscending
        }
    }

    public static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Counts Markdown documents below a directory, including nested folders.
    /// Hidden folders are skipped to match the visible navigation tree.
    public static func markdownCount(in directory: URL,
                                     fileManager: FileManager = .default) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            if values?.isHidden == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory != true, isMarkdown(url) { count += 1 }
        }
        return count
    }
}
