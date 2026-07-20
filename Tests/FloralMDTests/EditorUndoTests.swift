// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
@testable import FloralMDCore

@MainActor private final class UndoChangeNotificationProbe: NSObject {
    var sources: [String] = []

    @objc func editorDidChange(_ notification: Notification) {
        guard let editor = notification.object as? EditorTextView else { return }
        sources.append(editor.rawSource)
    }
}

// MARK: - Undo

@Suite("EditorTextView — Undo")
struct EditorUndoTests {

    @Test("Undo reverts typing run")
    @MainActor func undoTypingRun() {
        let editor = makeEditor()
        type("hello", into: editor)
        editor.undo(nil)
        #expect(editor.rawSource == "")
    }

    @Test("Undo after single character")
    @MainActor func undoSingleChar() {
        let editor = makeEditor()
        type("a", into: editor)
        editor.undo(nil)
        #expect(editor.rawSource == "")
        #expect(editor.textStorage?.string == "")
    }

    @Test("Undo on empty editor does nothing")
    @MainActor func undoEmpty() {
        let editor = makeEditor()
        editor.undo(nil)  // should not crash
        #expect(editor.rawSource == "")
    }

    @Test("Undo restores cursor position")
    @MainActor func undoRestoresCursor() {
        let editor = makeEditor()
        type("hello", into: editor)
        #expect(editor.selectedRange().location == 5)
        editor.undo(nil)
        #expect(editor.selectedRange().location == 0)
    }

    @Test("Undo coalesces consecutive inserts")
    @MainActor func undoCoalesces() {
        let editor = makeEditor()
        type("hello", into: editor)
        // All 5 chars are one typing run → one undo group
        #expect(editor.undoStack.count == 1)
        editor.undo(nil)
        #expect(editor.rawSource == "")
    }

    @Test("One coalesced typing run returns the document to clean after undo")
    @MainActor func undoRestoresDocumentChangeCount() {
        let editor = makeEditor()
        let document = NSDocument()
        editor.document = document

        type("hello", into: editor)
        #expect(document.isDocumentEdited)

        editor.undo(nil)
        #expect(!document.isDocumentEdited)

        editor.redo(nil)
        #expect(document.isDocumentEdited)
    }

    @Test("Full-selection delete survives the untitled semantic clean boundary")
    @MainActor func fullSelectionDeleteTracksDocumentChangeCount() {
        let editor = makeEditor()
        let document = NSDocument()
        editor.document = document

        type("hello", into: editor)
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        pressBackspace(in: editor)
        #expect(UntitledDocumentContentPolicy.dirtyStateAction(
            hasFileURL: false, rawSource: editor.rawSource, hasMarkedText: false,
            isDocumentEdited: document.isDocumentEdited
        ) == .clearEdited)
        document.updateChangeCount(.changeCleared)

        #expect(editor.rawSource.isEmpty)
        #expect(!document.isDocumentEdited)

        editor.undo(nil)
        #expect(editor.rawSource == "hello")
        #expect(document.isDocumentEdited)

        editor.redo(nil)
        #expect(editor.rawSource.isEmpty)
        #expect(UntitledDocumentContentPolicy.dirtyStateAction(
            hasFileURL: false, rawSource: editor.rawSource, hasMarkedText: false,
            isDocumentEdited: document.isDocumentEdited
        ) == .none)
        #expect(!document.isDocumentEdited)
    }

    @Test("Undo and redo publish synchronized source notifications")
    @MainActor func undoRedoPublishSynchronizedChanges() {
        let editor = makeEditor()
        type("hello", into: editor)
        let probe = UndoChangeNotificationProbe()
        NotificationCenter.default.addObserver(
            probe, selector: #selector(UndoChangeNotificationProbe.editorDidChange(_:)),
            name: .editorDidSynchronizeText, object: editor
        )
        defer { NotificationCenter.default.removeObserver(probe) }

        editor.undo(nil)
        editor.redo(nil)

        #expect(probe.sources == ["", "hello"])
    }

    @Test("A save boundary splits a continuing typing run")
    @MainActor func saveBoundarySplitsTypingRun() {
        let editor = makeEditor()
        let document = NSDocument()
        editor.document = document

        type("a", into: editor)
        document.updateChangeCount(.changeCleared)
        editor.breakUndoCoalescingAfterSave()
        type("b", into: editor)

        #expect(editor.rawSource == "ab")
        #expect(document.isDocumentEdited)

        editor.undo(nil)
        #expect(editor.rawSource == "a")
        #expect(!document.isDocumentEdited)

        editor.undo(nil)
        #expect(editor.rawSource == "")
        #expect(document.isDocumentEdited)
    }

    @Test("Undo separates insert and delete groups")
    @MainActor func undoSeparatesInsertDelete() {
        let editor = makeEditor()
        type("abc", into: editor)
        pressBackspace(in: editor)  // switch from insert to delete
        #expect(editor.undoStack.count == 2)
        editor.undo(nil)  // undo the delete
        #expect(editor.rawSource == "abc")
        editor.undo(nil)  // undo the typing
        #expect(editor.rawSource == "")
    }

    @Test("Undo after paste reverts entire paste")
    @MainActor func undoPaste() {
        let editor = makeEditor()
        type("start", into: editor)
        paste(" pasted text", into: editor)
        // Paste is .other → always new group
        #expect(editor.undoStack.count == 2)
        editor.undo(nil)
        #expect(editor.rawSource == "start")
    }

    @Test("Undo after Enter merges blocks back")
    @MainActor func undoEnter() {
        let editor = makeEditor()
        type("hello", into: editor)
        pressEnter(in: editor)
        editor.undo(nil)
        // The Enter pushed a new undo group (newline is .other)
        #expect(editor.rawSource == "hello")
        #expect(editor.blocks.count == 1)
    }

    @Test("Multiple undos walk back through history")
    @MainActor func multipleUndos() {
        let editor = makeEditor()
        type("aaa", into: editor)      // group 1
        pressBackspace(in: editor)     // group 2
        type("bbb", into: editor)      // group 3

        editor.undo(nil)  // undo "bbb"
        #expect(editor.rawSource == "aa")
        editor.undo(nil)  // undo backspace
        #expect(editor.rawSource == "aaa")
        editor.undo(nil)  // undo "aaa"
        #expect(editor.rawSource == "")
    }
}

// MARK: - Redo

@Suite("EditorTextView — Redo")
struct EditorRedoTests {

    @Test("Redo restores undone text")
    @MainActor func redoRestores() {
        let editor = makeEditor()
        type("hello", into: editor)
        editor.undo(nil)
        #expect(editor.rawSource == "")
        editor.redo(nil)
        #expect(editor.rawSource == "hello")
    }

    @Test("Redo on empty redo stack does nothing")
    @MainActor func redoEmpty() {
        let editor = makeEditor()
        type("hello", into: editor)
        editor.redo(nil)  // nothing to redo
        #expect(editor.rawSource == "hello")
    }

    @Test("New edit clears redo stack")
    @MainActor func editClearsRedo() {
        let editor = makeEditor()
        type("hello", into: editor)
        editor.undo(nil)
        #expect(editor.redoStack.count == 1)
        type("x", into: editor)  // new edit
        #expect(editor.redoStack.isEmpty)
    }

    @Test("Undo then redo then undo roundtrips correctly")
    @MainActor func undoRedoUndoRoundtrip() {
        let editor = makeEditor()
        type("abc", into: editor)
        editor.undo(nil)
        #expect(editor.rawSource == "")
        editor.redo(nil)
        #expect(editor.rawSource == "abc")
        editor.undo(nil)
        #expect(editor.rawSource == "")
    }

    @Test("Multiple undo then multiple redo")
    @MainActor func multipleUndoRedo() {
        let editor = makeEditor()
        type("aaa", into: editor)       // group 1
        pressBackspace(in: editor)      // group 2
        type("bbb", into: editor)       // group 3

        // Undo all
        editor.undo(nil)
        editor.undo(nil)
        editor.undo(nil)
        #expect(editor.rawSource == "")

        // Redo all
        editor.redo(nil)
        #expect(editor.rawSource == "aaa")
        editor.redo(nil)
        #expect(editor.rawSource == "aa")
        editor.redo(nil)
        #expect(editor.rawSource == "aabbb")
    }
}

// MARK: - Undo Coalescing Details

@Suite("EditorTextView — Undo Coalescing")
struct EditorCoalescingTests {

    @Test("Consecutive single-char inserts produce one undo group")
    @MainActor func insertCoalescing() {
        let editor = makeEditor()
        type("abcde", into: editor)
        #expect(editor.undoStack.count == 1)
    }

    @Test("Consecutive single-char deletes produce one undo group")
    @MainActor func deleteCoalescing() {
        let editor = makeEditor()
        type("abc", into: editor)
        let undoCountAfterTyping = editor.undoStack.count  // 1
        pressBackspace(in: editor)
        pressBackspace(in: editor)
        // Delete is a different type from insert → +1 group
        #expect(editor.undoStack.count == undoCountAfterTyping + 1)
    }

    @Test("Switching from insert to delete starts new group")
    @MainActor func insertToDeleteBreak() {
        let editor = makeEditor()
        type("abc", into: editor)
        #expect(editor.undoStack.count == 1)
        pressBackspace(in: editor)
        #expect(editor.undoStack.count == 2)
    }

    @Test("Paste always starts a new group")
    @MainActor func pasteAlwaysNewGroup() {
        let editor = makeEditor()
        type("a", into: editor)
        paste("xyz", into: editor)
        #expect(editor.undoStack.count == 2)
        paste("123", into: editor)
        #expect(editor.undoStack.count == 3)
    }
}
