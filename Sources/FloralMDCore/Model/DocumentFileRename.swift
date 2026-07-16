import Foundation

public enum DocumentFileRenameError: LocalizedError, Equatable {
    case emptyName
    case reservedName
    case pathSeparator
    case surroundingWhitespace
    case extensionChanged(expected: String)
    case directoryChanged
    case sourceMissing
    case sourceIsDirectory
    case destinationExists
    case rollbackFailed(destination: URL)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a file name."
        case .reservedName:
            "A file cannot be named “.” or “..”."
        case .pathSeparator:
            "A file name cannot contain a path separator."
        case .surroundingWhitespace:
            "Remove spaces from the beginning or end of the file name."
        case .extensionChanged(let expected):
            "Renaming keeps the .\(expected) extension. Edit only the name before it."
        case .directoryChanged:
            "Rename keeps the file in its current folder. Use Move to change folders."
        case .sourceMissing:
            "The original file no longer exists. Refresh the sidebar and try again."
        case .sourceIsDirectory:
            "This version can rename files only, not folders."
        case .destinationExists:
            "A file with that name already exists in this folder."
        case .rollbackFailed(let destination):
            "The rename could not be completed or rolled back. The document remains at \(destination.path)."
        }
    }
}

public struct DocumentFileRenameRequest: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let preservedExtension: String

    public init(sourceURL: URL, proposedStem: String) throws {
        let source = sourceURL.standardizedFileURL
        let ext = source.pathExtension
        try Self.validateStem(proposedStem)
        guard !ext.isEmpty else {
            throw DocumentFileRenameError.extensionChanged(expected: "md")
        }
        self.sourceURL = source
        preservedExtension = ext
        destinationURL = source.deletingLastPathComponent()
            .appendingPathComponent(proposedStem)
            .appendingPathExtension(ext)
            .standardizedFileURL
    }

    public init(sourceURL: URL, proposedFullName: String) throws {
        let source = sourceURL.standardizedFileURL
        let expectedExtension = source.pathExtension
        let proposedExtension = (proposedFullName as NSString).pathExtension
        guard !expectedExtension.isEmpty,
              proposedExtension.caseInsensitiveCompare(expectedExtension) == .orderedSame else {
            throw DocumentFileRenameError.extensionChanged(
                expected: expectedExtension.isEmpty ? "md" : expectedExtension
            )
        }
        let stem = (proposedFullName as NSString).deletingPathExtension
        try Self.validateStem(stem)
        self.sourceURL = source
        preservedExtension = expectedExtension
        destinationURL = source.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(expectedExtension)
            .standardizedFileURL
    }

    public var isNoChange: Bool {
        sourceURL == destinationURL
    }

    public var isCaseOnlyChange: Bool {
        sourceURL != destinationURL
            && sourceURL.path.caseInsensitiveCompare(destinationURL.path) == .orderedSame
    }

    public static func editableStem(for url: URL) -> String {
        (url.lastPathComponent as NSString).deletingPathExtension
    }

    private static func validateStem(_ stem: String) throws {
        guard !stem.isEmpty else { throw DocumentFileRenameError.emptyName }
        guard stem == stem.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DocumentFileRenameError.surroundingWhitespace
        }
        guard stem != ".", stem != ".." else {
            throw DocumentFileRenameError.reservedName
        }
        guard !stem.contains("/"), !stem.contains("\\"), !stem.contains(":") else {
            throw DocumentFileRenameError.pathSeparator
        }
    }
}

public enum DocumentFileRenameOperation {
    @discardableResult
    public static func renameUnopenedFile(
        _ request: DocumentFileRenameRequest,
        fileManager: FileManager = .default
    ) throws -> URL {
        if request.isNoChange { return request.sourceURL }
        try validateSource(request.sourceURL, fileManager: fileManager)
        if request.isCaseOnlyChange {
            return try renameCaseOnly(request, fileManager: fileManager)
        }
        guard !fileManager.fileExists(atPath: request.destinationURL.path) else {
            throw DocumentFileRenameError.destinationExists
        }
        try coordinatedMove(from: request.sourceURL,
                            to: request.destinationURL,
                            fileManager: fileManager)
        return request.destinationURL
    }

    public static func validateSource(
        _ sourceURL: URL,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw DocumentFileRenameError.sourceMissing
        }
        guard !isDirectory.boolValue else {
            throw DocumentFileRenameError.sourceIsDirectory
        }
    }

    public static func temporaryURL(for request: DocumentFileRenameRequest) -> URL {
        request.sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".floralmd-rename-\(UUID().uuidString)")
            .appendingPathExtension(request.preservedExtension)
    }

    private static func renameCaseOnly(
        _ request: DocumentFileRenameRequest,
        fileManager: FileManager
    ) throws -> URL {
        let temporaryURL = temporaryURL(for: request)
        try coordinatedMove(from: request.sourceURL,
                            to: temporaryURL,
                            fileManager: fileManager)
        do {
            guard !fileManager.fileExists(atPath: request.destinationURL.path) else {
                throw DocumentFileRenameError.destinationExists
            }
            try coordinatedMove(from: temporaryURL,
                                to: request.destinationURL,
                                fileManager: fileManager)
            return request.destinationURL
        } catch {
            do {
                try coordinatedMove(from: temporaryURL,
                                    to: request.sourceURL,
                                    fileManager: fileManager)
            } catch {
                throw DocumentFileRenameError.rollbackFailed(destination: temporaryURL)
            }
            throw error
        }
    }

    private static func coordinatedMove(from source: URL,
                                        to destination: URL,
                                        fileManager: FileManager) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: [],
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                try fileManager.moveItem(at: coordinatedSource, to: coordinatedDestination)
            } catch {
                moveError = error
            }
        }
        if let moveError { throw moveError }
        if let coordinationError { throw coordinationError }
    }
}

public enum DocumentInlineRenameEndReason: Sendable {
    case returnKey
    case escapeKey
    case focusLoss
}

public enum DocumentInlineRenameEndAction: Equatable, Sendable {
    case commit
    case cancel
}

public enum DocumentInlineRenamePolicy {
    public static func action(for reason: DocumentInlineRenameEndReason)
        -> DocumentInlineRenameEndAction {
        reason == .returnKey ? .commit : .cancel
    }

    public static func action(forTextMovement rawValue: Int?, keyCode: UInt16? = nil)
        -> DocumentInlineRenameEndAction {
        if rawValue == 0x10 || keyCode == 36 || keyCode == 76 { return .commit }
        return .cancel
    }
}

public enum DocumentFileTreeClickTarget: Equatable, Sendable {
    case name
    case rowChrome
}

public enum DocumentFileTreeClickAction: Equatable, Sendable {
    case delayedOpen
    case openImmediately
    case beginRename
}

public enum DocumentFileTreeClickPolicy {
    public static func action(target: DocumentFileTreeClickTarget,
                              clickCount: Int) -> DocumentFileTreeClickAction {
        if target == .name {
            return clickCount >= 2 ? .beginRename : .delayedOpen
        }
        return .openImmediately
    }
}

@MainActor
public protocol OpenDocumentFileMoving: AnyObject {
    var renameFileURL: URL? { get }
    func moveFileForRename(to url: URL,
                           completionHandler: @escaping @MainActor (Error?) -> Void)
}

/// Routes an open file through its document owner instead of moving it behind
/// AppKit's back. A zero-byte destination reservation closes the race between
/// checking for a collision and NSDocument's replace-capable move operation.
@MainActor
public enum OpenDocumentFileRenameCoordinator {
    public static func rename(
        _ request: DocumentFileRenameRequest,
        document: OpenDocumentFileMoving,
        fileManager: FileManager = .default,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        if request.isNoChange {
            completion(.success(request.sourceURL))
            return
        }
        do {
            try DocumentFileRenameOperation.validateSource(
                request.sourceURL,
                fileManager: fileManager
            )
        } catch {
            completion(.failure(error))
            return
        }

        if request.isCaseOnlyChange {
            let temporaryURL = DocumentFileRenameOperation.temporaryURL(for: request)
            reservedMove(document: document,
                         expectedSource: request.sourceURL,
                         destination: temporaryURL,
                         fileManager: fileManager) { firstResult in
                switch firstResult {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    reservedMove(document: document,
                                 expectedSource: temporaryURL,
                                 destination: request.destinationURL,
                                 fileManager: fileManager) { finalResult in
                        switch finalResult {
                        case .success:
                            completion(.success(request.destinationURL))
                        case .failure(let originalError):
                            reservedMove(document: document,
                                         expectedSource: temporaryURL,
                                         destination: request.sourceURL,
                                         fileManager: fileManager) { rollbackResult in
                                switch rollbackResult {
                                case .success:
                                    completion(.failure(originalError))
                                case .failure:
                                    completion(.failure(DocumentFileRenameError.rollbackFailed(
                                        destination: document.renameFileURL ?? temporaryURL
                                    )))
                                }
                            }
                        }
                    }
                }
            }
        } else {
            reservedMove(document: document,
                         expectedSource: request.sourceURL,
                         destination: request.destinationURL,
                         fileManager: fileManager) { result in
                completion(result.map { request.destinationURL })
            }
        }
    }

    private static func reservedMove(
        document: OpenDocumentFileMoving,
        expectedSource: URL,
        destination: URL,
        fileManager: FileManager,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard document.renameFileURL?.standardizedFileURL == expectedSource.standardizedFileURL else {
            completion(.failure(DocumentFileRenameError.sourceMissing))
            return
        }

        let reservation: RenameDestinationReservation
        do {
            reservation = try RenameDestinationReservation(
                url: destination,
                fileManager: fileManager
            )
        } catch {
            completion(.failure(error))
            return
        }

        document.moveFileForRename(to: destination) { error in
            if let error {
                reservation.removeIfOwned()
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
}

private final class RenameDestinationReservation {
    let url: URL
    private let fileManager: FileManager
    private let resourceIdentifier: AnyHashable?

    init(url: URL, fileManager: FileManager) throws {
        self.url = url
        self.fileManager = fileManager
        do {
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                throw DocumentFileRenameError.destinationExists
            }
            throw error
        }
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        resourceIdentifier = values?.fileResourceIdentifier as? AnyHashable
    }

    func removeIfOwned() {
        guard let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .fileSizeKey, .isDirectoryKey,
        ]),
        values.isDirectory != true,
        values.fileSize == 0,
        (values.fileResourceIdentifier as? AnyHashable) == resourceIdentifier else { return }
        try? fileManager.removeItem(at: url)
    }
}
