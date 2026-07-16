import Foundation

/// Supported intervals for AppKit's periodic document autosave timer.
public enum DocumentAutoSaveInterval: TimeInterval, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30

    public var id: TimeInterval { rawValue }

    public static let defaultValue = DocumentAutoSaveInterval.twoSeconds

    /// Falls back to the product default if a stored preference is invalid or
    /// came from an older build with a no-longer-supported interval.
    public static func resolved(_ value: TimeInterval) -> DocumentAutoSaveInterval {
        DocumentAutoSaveInterval(rawValue: value) ?? defaultValue
    }
}

/// Converts the user-facing save mode into `NSDocumentController` semantics.
public enum DocumentSavePolicy {
    public static func autosavingDelay(
        automaticSavingEnabled: Bool,
        requestedInterval: TimeInterval
    ) -> TimeInterval {
        guard automaticSavingEnabled else { return 0 }
        return DocumentAutoSaveInterval.resolved(requestedInterval).rawValue
    }

    /// A successful save may finish after another edit. Only clear the dirty
    /// state when the completed write targets the document's current file and
    /// the bytes on disk still represent the current editor contents.
    public static func shouldClearDirtyStateAfterSave(
        saveSucceeded: Bool,
        savedCurrentFile: Bool,
        persistedContentMatchesEditor: Bool
    ) -> Bool {
        saveSucceeded && savedCurrentFile && persistedContentMatchesEditor
    }

    public static func shouldSaveBeforeClosing(
        automaticSavingEnabled: Bool,
        hasFileURL: Bool,
        isDocumentEdited: Bool,
        hasUnautosavedChanges: Bool
    ) -> Bool {
        automaticSavingEnabled && hasFileURL
            && (isDocumentEdited || hasUnautosavedChanges)
    }

    public static func shouldBypassCloseReview(
        automaticSavingEnabled: Bool,
        hasFileURL: Bool,
        persistedContentMatchesEditor: Bool
    ) -> Bool {
        automaticSavingEnabled && hasFileURL && persistedContentMatchesEditor
    }

    public static func shouldCompleteAutomaticTerminationReview(
        saveSucceeded: Bool,
        hasUnsavedDocuments: Bool
    ) -> Bool {
        saveSucceeded && !hasUnsavedDocuments
    }
}

public enum DocumentSavePresentation: Equatable, Sendable {
    case idle
    case unsaved
    case saving
    case saved
    case failed
}

/// The exact file state produced by FloralMD's most recent successful write.
/// File-presenter notifications can arrive after the write completion, when
/// the editor already contains newer text, so origin must be identified
/// against the saved snapshot rather than the live buffer.
public struct DocumentOwnWriteSnapshot: Sendable {
    public let fileURL: URL
    public let rawSource: String
    public let lineEnding: LineEnding

    public init(fileURL: URL, rawSource: String, lineEnding: LineEnding) {
        self.fileURL = fileURL.standardizedFileURL
        self.rawSource = rawSource
        self.lineEnding = lineEnding
    }

    public func matches(fileURL: URL, diskContent: String) -> Bool {
        guard self.fileURL == fileURL.standardizedFileURL else { return false }
        let diskEnding = LineEnding.isInconsistent(in: diskContent)
            ? LineEnding.lf : LineEnding.detect(in: diskContent)
        return LineEnding.normalize(diskContent) == rawSource
            && diskEnding == lineEnding
    }
}
