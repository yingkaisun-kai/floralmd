import Foundation
import Testing
@testable import FloralMDCore

@Suite("DocumentSavePolicy")
struct DocumentSavePolicyTests {
    @Test("Automatic saving defaults to two seconds")
    func defaultInterval() {
        #expect(DocumentAutoSaveInterval.defaultValue == .twoSeconds)
        #expect(DocumentSavePolicy.autosavingDelay(
            automaticSavingEnabled: true,
            requestedInterval: DocumentAutoSaveInterval.defaultValue.rawValue
        ) == 2)
    }

    @Test("Every user-facing interval reaches AppKit unchanged",
          arguments: DocumentAutoSaveInterval.allCases)
    func supportedIntervals(interval: DocumentAutoSaveInterval) {
        #expect(DocumentSavePolicy.autosavingDelay(
            automaticSavingEnabled: true,
            requestedInterval: interval.rawValue
        ) == interval.rawValue)
    }

    @Test("Manual saving disables AppKit's periodic timer")
    func manualMode() {
        #expect(DocumentSavePolicy.autosavingDelay(
            automaticSavingEnabled: false,
            requestedInterval: 2
        ) == 0)
    }

    @Test("Invalid stored intervals fall back to the product default",
          arguments: [0.0, -1.0, 3.0, 60.0])
    func invalidInterval(value: Double) {
        #expect(DocumentSavePolicy.autosavingDelay(
            automaticSavingEnabled: true,
            requestedInterval: value
        ) == DocumentAutoSaveInterval.defaultValue.rawValue)
    }

    @Test("A completed write clears dirty state only when disk matches the current document")
    func clearDirtyStateAfterMatchingSave() {
        #expect(DocumentSavePolicy.shouldClearDirtyStateAfterSave(
            saveSucceeded: true,
            savedCurrentFile: true,
            persistedContentMatchesEditor: true
        ))

        #expect(!DocumentSavePolicy.shouldClearDirtyStateAfterSave(
            saveSucceeded: false,
            savedCurrentFile: true,
            persistedContentMatchesEditor: true
        ))
        #expect(!DocumentSavePolicy.shouldClearDirtyStateAfterSave(
            saveSucceeded: true,
            savedCurrentFile: false,
            persistedContentMatchesEditor: true
        ))
        #expect(!DocumentSavePolicy.shouldClearDirtyStateAfterSave(
            saveSucceeded: true,
            savedCurrentFile: true,
            persistedContentMatchesEditor: false
        ))
    }

    @Test("Automatic mode flushes pending changes before closing a file-backed document")
    func saveBeforeClosing() {
        #expect(DocumentSavePolicy.shouldSaveBeforeClosing(
            automaticSavingEnabled: true,
            hasFileURL: true,
            isDocumentEdited: true,
            hasUnautosavedChanges: true
        ))
        #expect(!DocumentSavePolicy.shouldSaveBeforeClosing(
            automaticSavingEnabled: false,
            hasFileURL: true,
            isDocumentEdited: true,
            hasUnautosavedChanges: true
        ))
        #expect(!DocumentSavePolicy.shouldSaveBeforeClosing(
            automaticSavingEnabled: true,
            hasFileURL: false,
            isDocumentEdited: true,
            hasUnautosavedChanges: true
        ))
        #expect(!DocumentSavePolicy.shouldSaveBeforeClosing(
            automaticSavingEnabled: true,
            hasFileURL: true,
            isDocumentEdited: false,
            hasUnautosavedChanges: false
        ))
    }

    @Test("Automatic close bypasses AppKit review only when the named file matches the editor")
    func bypassCloseReview() {
        #expect(DocumentSavePolicy.shouldBypassCloseReview(
            automaticSavingEnabled: true,
            hasFileURL: true,
            persistedContentMatchesEditor: true
        ))
        #expect(!DocumentSavePolicy.shouldBypassCloseReview(
            automaticSavingEnabled: false,
            hasFileURL: true,
            persistedContentMatchesEditor: true
        ))
        #expect(!DocumentSavePolicy.shouldBypassCloseReview(
            automaticSavingEnabled: true,
            hasFileURL: false,
            persistedContentMatchesEditor: true
        ))
        #expect(!DocumentSavePolicy.shouldBypassCloseReview(
            automaticSavingEnabled: true,
            hasFileURL: true,
            persistedContentMatchesEditor: false
        ))
    }

    @Test("Automatic termination bypasses AppKit's stale review only after every save succeeds")
    func completeAutomaticTerminationReview() {
        #expect(DocumentSavePolicy.shouldCompleteAutomaticTerminationReview(
            saveSucceeded: true,
            hasUnsavedDocuments: false
        ))
        #expect(!DocumentSavePolicy.shouldCompleteAutomaticTerminationReview(
            saveSucceeded: false,
            hasUnsavedDocuments: false
        ))
        #expect(!DocumentSavePolicy.shouldCompleteAutomaticTerminationReview(
            saveSucceeded: true,
            hasUnsavedDocuments: true
        ))
    }

    @Test("A delayed presenter notification recognizes FloralMD's own older save snapshot")
    func ownWriteSnapshotAfterNewerEditing() {
        let url = URL(fileURLWithPath: "/tmp/floralmd-own-write.md")
        let snapshot = DocumentOwnWriteSnapshot(
            fileURL: url,
            rawSource: "voice input, first phrase\n",
            lineEnding: .lf
        )

        // The live editor may already contain a second phrase. The origin of
        // the disk event is still determined by the first phrase FloralMD wrote.
        let newerEditorSource = "voice input, first phrase\nsecond phrase\n"
        #expect(newerEditorSource != snapshot.rawSource)
        #expect(snapshot.matches(
            fileURL: url,
            diskContent: "voice input, first phrase\n"
        ))
    }

    @Test("A genuinely different external write is not suppressed")
    func ownWriteSnapshotRejectsExternalContent() {
        let url = URL(fileURLWithPath: "/tmp/floralmd-own-write.md")
        let snapshot = DocumentOwnWriteSnapshot(
            fileURL: url,
            rawSource: "FloralMD saved this\n",
            lineEnding: .crlf
        )

        #expect(snapshot.matches(fileURL: url, diskContent: "FloralMD saved this\r\n"))
        #expect(!snapshot.matches(fileURL: url, diskContent: "another app changed this\r\n"))
        #expect(!snapshot.matches(
            fileURL: URL(fileURLWithPath: "/tmp/another.md"),
            diskContent: "FloralMD saved this\r\n"
        ))
    }
}

@Suite("UntitledDocumentSavePolicy")
struct UntitledDocumentSavePolicyTests {
    @Test("Only a nonblank synchronized untitled draft is eligible")
    func eligibility() {
        #expect(UntitledDocumentSavePolicy.isEligible(
            enabled: true, hasFileURL: false, rawSource: "Draft", hasMarkedText: false
        ))
        #expect(!UntitledDocumentSavePolicy.isEligible(
            enabled: false, hasFileURL: false, rawSource: "Draft", hasMarkedText: false
        ))
        #expect(!UntitledDocumentSavePolicy.isEligible(
            enabled: true, hasFileURL: true, rawSource: "Draft", hasMarkedText: false
        ))
        #expect(!UntitledDocumentSavePolicy.isEligible(
            enabled: true, hasFileURL: false, rawSource: " \n\t", hasMarkedText: false
        ))
        #expect(!UntitledDocumentSavePolicy.isEligible(
            enabled: true, hasFileURL: false, rawSource: "Draft", hasMarkedText: true
        ))
    }

    @Test("First-save delay uses the same validated interval as normal autosave")
    func delay() {
        #expect(UntitledDocumentSavePolicy.debounceDelay(requestedInterval: 10) == 10)
        #expect(UntitledDocumentSavePolicy.debounceDelay(requestedInterval: 3) == 2)
    }

    @Test("Timestamp names are stable and append a readable collision suffix")
    func names() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let zone = TimeZone(secondsFromGMT: 0)!
        #expect(UntitledDocumentSavePolicy.fileName(at: date, timeZone: zone)
                == "2023-11-14 22-13-20.md")
        #expect(UntitledDocumentSavePolicy.fileName(at: date, timeZone: zone, sequence: 2)
                == "2023-11-14 22-13-20-2.md")
    }

    @Test("A failed attempt waits for a new edit or settings change")
    func retryState() {
        var state = UntitledDocumentSaveState()
        #expect(state.inputChanged(isEligible: true) == .schedule)
        #expect(state.inputChanged(isEligible: true) == .schedule)
        #expect(state.timerFired(isEligible: true) == .beginSave)
        state.saveCompleted(success: false)
        #expect(state.phase == .failed)
        #expect(state.timerFired(isEligible: true) == .none)
        #expect(state.phase == .failed)
        #expect(state.inputChanged(isEligible: true) == .schedule)
    }

    @Test("Reservation never overwrites a same-second file")
    func reservationCollision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let zone = TimeZone(secondsFromGMT: 0)!
        let firstURL = directory.appendingPathComponent("2023-11-14 22-13-20.md")
        try Data("keep me".utf8).write(to: firstURL)

        let reservation = try UntitledDocumentFileReservation.reserve(
            in: directory, at: date, timeZone: zone
        )
        #expect(reservation.url.lastPathComponent == "2023-11-14 22-13-20-2.md")
        #expect(try String(contentsOf: firstURL, encoding: .utf8) == "keep me")
        #expect(FileManager.default.fileExists(atPath: reservation.url.path))
    }

    @Test("Failure cleanup removes only an untouched reservation")
    func reservationCleanup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = try UntitledDocumentFileReservation.reserve(in: directory)
        empty.removeIfEmpty()
        #expect(!FileManager.default.fileExists(atPath: empty.url.path))

        let nonempty = try UntitledDocumentFileReservation.reserve(in: directory)
        try Data("recoverable".utf8).write(to: nonempty.url)
        nonempty.removeIfEmpty()
        #expect(try String(contentsOf: nonempty.url, encoding: .utf8) == "recoverable")
    }

    @Test("Invalid directories fail without creating a fallback file")
    func invalidDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(throws: (any Error).self) {
            try UntitledDocumentFileReservation.reserve(in: missing)
        }
    }
}
