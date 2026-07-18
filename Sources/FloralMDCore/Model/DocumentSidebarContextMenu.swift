import Foundation

public enum DocumentSidebarEntryKind: Sendable {
    case markdownFile
    case directory
}

public enum DocumentSidebarContextCommand: Equatable, Sendable {
    case open
    case rename
    case showInFinder
    case copyPath
    case moveToTrash
}

/// Keeps the document-navigation sidebar intentionally smaller than Finder.
/// Directory creation, recursive deletion, and general file management do not
/// belong to this menu.
public enum DocumentSidebarContextMenuPolicy {
    public static func commands(for kind: DocumentSidebarEntryKind,
                                canMoveToTrash: Bool = true)
        -> [DocumentSidebarContextCommand] {
        switch kind {
        case .markdownFile:
            var commands: [DocumentSidebarContextCommand] = [
                .open, .rename, .showInFinder, .copyPath,
            ]
            if canMoveToTrash { commands.append(.moveToTrash) }
            return commands
        case .directory:
            return [.showInFinder, .copyPath]
        }
    }
}

public enum DocumentFileTrashError: LocalizedError, Equatable {
    case sourceMissing
    case sourceIsDirectory

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "The original file no longer exists."
        case .sourceIsDirectory:
            "This version moves Markdown files to the Trash, not folders."
        }
    }
}

public enum DocumentFileTrashOperation {
    public static func validateSource(_ sourceURL: URL,
                                      fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw DocumentFileTrashError.sourceMissing
        }
        guard !isDirectory.boolValue else {
            throw DocumentFileTrashError.sourceIsDirectory
        }
    }
}
