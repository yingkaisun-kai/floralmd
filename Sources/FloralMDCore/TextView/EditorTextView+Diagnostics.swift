// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit

// MARK: - Editor diagnostics
//
// The edit pipeline lives in the live NSTextView / TextKit 2 / input-context
// layer, which can't be reproduced or inspected headlessly — so bugs there
// (caret drift, sync desyncs) are hard to pin down from a recording alone. These
// helpers capture the decisive live state:
//
//   - `traceEdit` — a one-line snapshot of caret + flags + lengths, emitted only
//     when verbose editor tracing is on (Settings ▸ Advanced). Sprinkled at the
//     key pipeline points so a reproduction yields a readable keystroke-level
//     trail in `~/.floralmd/logs`.
//   - `verifyEditorInvariants` — checks the two model invariants after a sync. A
//     cheap length check is effectively always on (logs an error if the
//     storage==rawSource invariant ever breaks); the full structural check runs
//     under verbose tracing (and asserts in DEBUG).

extension EditorTextView {

    #if DEBUG
    /// Live-repro oracle for the explicit short caret. This intentionally reads
    /// the current overlay without refreshing it, so a stale IME update remains
    /// observable instead of being healed by the diagnostic itself.
    public func reproInsertionIndicatorDelta() -> CGFloat? {
        guard let expected = reproLiveStorageInsertionPointFrame() else { return nil }
        return fontHeightInsertionIndicator.frame.midX - expected.midX
    }

    /// Independent IME oracle: unlike the production short-caret helper on the
    /// baseline build, this measures against live storage, whose extra marked
    /// characters are legitimate until commit.
    private func reproLiveStorageInsertionPointFrame() -> CGRect? {
        let marked = markedRange()
        let selection = selectedRange()
        if marked.location != NSNotFound,
           selection.location >= marked.location,
           selection.location <= NSMaxRange(marked),
           let tlm = textLayoutManager,
           let storage = textStorage,
           let startLocation = tlm.location(tlm.documentRange.location,
                                            offsetBy: marked.location) {
            tlm.ensureLayout(for: NSTextRange(location: startLocation))
            if let fragment = tlm.textLayoutFragment(for: startLocation),
               let paragraphStart = fragment.textElement?.elementRange?.location {
                let offsetInParagraph = tlm.offset(from: paragraphStart, to: startLocation)
                let line = fragment.textLineFragments.first {
                    offsetInParagraph >= $0.characterRange.location
                        && offsetInParagraph <= NSMaxRange($0.characterRange)
                } ?? fragment.textLineFragments.last
                if let line {
                    let prefixRange = NSRange(location: marked.location,
                                              length: selection.location - marked.location)
                    let prefixWidth = storage.attributedSubstring(from: prefixRange).size().width
                    let frame = fragment.layoutFragmentFrame
                    let startX = textContainerOrigin.x + frame.minX + line.typographicBounds.minX
                        + line.locationForCharacter(at: offsetInParagraph).x
                    return CGRect(x: startX + prefixWidth, y: frame.minY,
                                  width: 2, height: line.typographicBounds.height)
                }
            }
        }
        if let window {
            var actual = NSRange()
            let screen = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
            if !screen.isEmpty {
                return convert(window.convertFromScreen(screen), from: nil)
            }
        }
        guard let tlm = textLayoutManager, let storage = textStorage else { return nil }
        let offset = min(max(0, selectedRange().location), storage.length)
        guard let location = tlm.location(tlm.documentRange.location, offsetBy: offset)
        else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = tlm.textLayoutFragment(for: location),
              let paragraphStart = fragment.textElement?.elementRange?.location
        else { return nil }
        let offsetInParagraph = tlm.offset(from: paragraphStart, to: location)
        let line = fragment.textLineFragments.first {
            offsetInParagraph >= $0.characterRange.location
                && offsetInParagraph <= NSMaxRange($0.characterRange)
        } ?? fragment.textLineFragments.last
        guard let line else { return nil }
        let frame = fragment.layoutFragmentFrame
        let x = textContainerOrigin.x + frame.minX + line.typographicBounds.minX
            + line.locationForCharacter(at: offsetInParagraph).x
        return CGRect(x: x, y: frame.minY, width: 2, height: line.typographicBounds.height)
    }

    /// Distance from the current logical caret line to the typewriter target.
    /// The explicit short-caret geometry includes the terminal-empty-line
    /// fallback, making it a useful oracle when TextKit 2 has no fragment.
    public func reproTypewriterCenterDelta() -> CGFloat? {
        guard let scrollView = enclosingScrollView,
              let caret = currentFontHeightInsertionPointFrame() else { return nil }
        return caret.midY - scrollView.contentView.bounds.midY
    }

    public var reproInputGeometryState: String {
        let marked = markedRange()
        let indicatorDelta = reproInsertionIndicatorDelta()
        let centerDelta = reproTypewriterCenterDelta()
        let indicatorDeltaDescription = indicatorDelta.map { String(describing: $0) } ?? "nil"
        let centerDeltaDescription = centerDelta.map { String(describing: $0) } ?? "nil"
        let viewport = enclosingScrollView?.contentView.bounds ?? .zero
        return "\(diagnosticState) "
            + "indicator={\(fontHeightInsertionIndicator.frame.minX),"
            + "\(fontHeightInsertionIndicator.frame.minY),"
            + "\(fontHeightInsertionIndicator.frame.width),"
            + "\(fontHeightInsertionIndicator.frame.height)} "
            + "indicatorMode=\(String(describing: fontHeightInsertionIndicator.displayMode)) "
            + "indicatorDelta=\(indicatorDeltaDescription) "
            + "centerDelta=\(centerDeltaDescription) "
            + "viewFrame={\(frame.minY),\(frame.height)} "
            + "viewport={\(viewport.minY),\(viewport.height)} "
            + "markedSelectionEnd=\(marked.location == NSNotFound ? -1 : NSMaxRange(marked))"
    }
    #endif

    /// Compact live-state prefix: caret, active block, marked-text, the sync
    /// flags, and storage-vs-rawSource lengths — everything that explains a caret
    /// drift or a stranded sync.
    var diagnosticState: String {
        let sel = selectedRange()
        let marked = markedRange()
        let markedDesc = marked.location == NSNotFound
            ? "-" : "{\(marked.location),\(marked.length)}"
        let storLen = textStorage?.length ?? -1
        let rawLen = (rawSource as NSString).length
        return "sel={\(sel.location),\(sel.length)} active=\(activeBlockIndex.map(String.init) ?? "nil") "
            + "marked=\(markedDesc) up=\(isUpdating ? "Y" : "N") undo=\(isUndoRedoing ? "Y" : "N") "
            + "blocks=\(blocks.count) storLen=\(storLen) rawLen=\(rawLen)"
            + (storLen == rawLen ? "" : " ⚠︎LEN-MISMATCH")
    }

    /// One verbose trace line: `<event> | <live state>`. No-op (and the message
    /// closure isn't built) unless verbose editor tracing is on.
    func traceEdit(_ event: @autoclosure () -> String) {
        Log.trace("\(event()) | \(diagnosticState)", category: .edit)
    }

    /// Under verbose tracing, logs a condensed call stack for a suspicious
    /// selection change — one arriving mid-recompose (up=Y) or while a
    /// pendingEdit is unconsumed. Those are exactly the changes behind the
    /// issue-#156 caret drifts, and the stack names the AppKit path that
    /// moved the caret.
    func traceSelectionOrigin() {
        guard Log.shouldTrace else { return }
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(14).map { frame in
            // "3  AppKit  0x00: -[NSTextView foo] + 12" → drop index/module/addr.
            let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count > 3 ? parts[3...].joined(separator: " ") : frame
        }
        Log.trace("selection origin:\n    " + frames.joined(separator: "\n    "),
                  category: .edit)
    }

    /// A short, newline-escaped, length-capped rendering of edit text for traces.
    func logSnippet(_ s: String?) -> String {
        guard let s else { return "nil" }
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 24 ? "\"\(flat)\"" : "\"\(flat.prefix(24))…\"(\(s.count))"
    }

    /// Validates the editor's two model invariants and reports violations. The
    /// length check is O(1) and the error is written whenever logging is on (the
    /// always-on tripwire for a desync); the structural checks are O(n) and run
    /// only under verbose tracing. In DEBUG any violation also trips an assertion.
    func verifyEditorInvariants(_ context: String) {
        guard let ts = textStorage else { return }
        let storLen = ts.length
        let rawLen = (rawSource as NSString).length
        if storLen != rawLen {
            Log.error("invariant: storage.length \(storLen) != rawSource.length \(rawLen) [\(context)]",
                      category: .edit)
            assertionFailure("storage != rawSource length after \(context)")
            return
        }
        guard Log.shouldTrace else { return }
        if ts.string != rawSource {
            Log.error("invariant: storage string != rawSource (same length) [\(context)]", category: .edit)
            assertionFailure("storage string != rawSource after \(context)")
        }
        let reconstructed = blocks.map(\.content).joined(separator: blockSeparator)
        if reconstructed != rawSource {
            Log.error("invariant: blocks do not reconstruct rawSource [\(context)]", category: .edit)
            assertionFailure("blocks != rawSource after \(context)")
        }
        if let bad = blocks.first(where: { $0.range.upperBound > rawLen }) {
            Log.error("invariant: block range \(bad.range) exceeds rawSource \(rawLen) [\(context)]",
                      category: .edit)
            assertionFailure("block range out of bounds after \(context)")
        }
    }
}
