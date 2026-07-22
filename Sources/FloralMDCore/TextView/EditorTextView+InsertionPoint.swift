import AppKit

/// TextKit 2 draws its system insertion point at line-fragment height, including
/// user line spacing, and bypasses NSTextView's public drawInsertionPoint hook.
/// Keep that system caret transparent and drive a foreground
/// NSTextInsertionIndicator explicitly so it has font height and a reliable
/// first-responder/blink lifecycle.
extension EditorTextView {
    func scheduleFontHeightInsertionIndicatorUpdate() {
        guard !insertionIndicatorUpdateScheduled else { return }
        insertionIndicatorUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.insertionIndicatorUpdateScheduled = false
            self.updateFontHeightInsertionIndicator()
        }
    }

    func updateFontHeightInsertionIndicator() {
        guard window?.firstResponder === self,
              isEditable,
              selectedRange().length == 0,
              let frame = currentFontHeightInsertionPointFrame()
        else {
            stopFontHeightInsertionIndicator()
            return
        }

        fontHeightInsertionIndicator.frame = frame
        fontHeightInsertionIndicator.color = accentColor
        fontHeightInsertionIndicator.displayMode = .visible
        restartInsertionIndicatorBlinkTimer()
    }

    func stopFontHeightInsertionIndicator() {
        insertionIndicatorBlinkTimer?.invalidate()
        insertionIndicatorBlinkTimer = nil
        fontHeightInsertionIndicator.displayMode = .hidden
    }

    private func restartInsertionIndicatorBlinkTimer() {
        insertionIndicatorBlinkTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5,
                          target: self,
                          selector: #selector(toggleFontHeightInsertionIndicator),
                          userInfo: nil,
                          repeats: true)
        insertionIndicatorBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func toggleFontHeightInsertionIndicator() {
        guard window?.firstResponder === self,
              isEditable,
              selectedRange().length == 0
        else {
            stopFontHeightInsertionIndicator()
            return
        }
        fontHeightInsertionIndicator.displayMode =
            fontHeightInsertionIndicator.displayMode == .hidden ? .visible : .hidden
    }

    /// TextKit 2 can absorb an empty paragraph's boundary into the preceding
    /// fragment until the paragraph gains a real glyph. Prefer our synthetic
    /// empty-line geometry so the short caret does not jump on that first glyph.
    func currentFontHeightInsertionPointFrame() -> NSRect? {
        let offset = min(max(0, selectedRange().location), (rawSource as NSString).length)
        if offset == 0, rawSource.isEmpty {
            let lineHeight = ceil(bodyFont.ascender - bodyFont.descender) + theme.lineSpacing
            let proposed = NSRect(x: textContainerOrigin.x,
                                  y: textContainerOrigin.y,
                                  width: 2,
                                  height: lineHeight)
            return fontHeightInsertionPointRect(from: proposed)
        }
        let measured = fontHeightInsertionPointFrame()
        if hasMarkedText(), let measured { return measured }
        let emptyParagraph = emptyParagraphInsertionPointFrame(at: offset)
        if let resolved = Self.preferredInsertionPointFrame(
            measured: measured,
            syntheticEmptyLine: emptyParagraph
        ) { return resolved }

        guard let window else { return nil }
        var actualRange = NSRange()
        let screenRect = firstRect(forCharacterRange: NSRange(location: offset, length: 0),
                                   actualRange: &actualRange)
        guard !screenRect.isEmpty else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        let proposed = convert(windowRect, from: nil)
        return fontHeightInsertionPointRect(from: proposed)
    }

    private func emptyParagraphInsertionPointFrame(at offset: Int) -> NSRect? {
        guard Self.isEmptyParagraphInsertionOffset(offset, in: rawSource),
              let emptyLine = lineRect(forCharacterAt: offset)
        else { return nil }
        let proposed = NSRect(x: textContainerOrigin.x + emptyLine.minX,
                              y: textContainerOrigin.y + emptyLine.minY,
                              width: 2,
                              height: emptyLine.height)
        return fontHeightInsertionPointRect(from: proposed)
    }

    /// Keep this resolver explicit so the synthetic empty paragraph wins over
    /// a boundary location that TextKit 2 reports in the preceding fragment.
    static func preferredInsertionPointFrame(
        measured: NSRect?,
        syntheticEmptyLine: NSRect?
    ) -> NSRect? {
        syntheticEmptyLine ?? measured
    }

    static func isEmptyParagraphInsertionOffset(_ offset: Int, in source: String) -> Bool {
        let utf16 = source as NSString
        guard offset > 0,
              offset <= utf16.length,
              utf16.character(at: offset - 1) == 0x000A
        else { return false }
        return offset == utf16.length || utf16.character(at: offset) == 0x000A
    }

    /// Shrink a system-proposed line-box rect while preserving its position.
    /// Internal so the no-fragment terminal-line fallback is deterministic in
    /// regression tests without a live WindowServer.
    func fontHeightInsertionPointRect(from proposed: NSRect) -> NSRect {
        let offset = min(max(0, selectedRange().location), (rawSource as NSString).length)
        let font = insertionPointFont(at: offset)
        let height = ceil(font.ascender - font.descender)
        return NSRect(x: proposed.minX, y: proposed.midY - height / 2,
                      width: max(2, proposed.width), height: height)
    }

    /// Frame in the text view's coordinates. Internal so regression tests can
    /// verify that line spacing changes the line box but not the insertion bar.
    func fontHeightInsertionPointFrame() -> CGRect? {
        guard let tlm = textLayoutManager else { return nil }
        let selection = selectedRange()
        // During IME composition storage legitimately contains provisional
        // marked text that rawSource does not. Resolve the short caret inside
        // that live marked range without syncing or restyling storage.
        if let markedFrame = markedTextInsertionPointFrame(selection: selection, tlm: tlm) {
            return markedFrame
        }
        let documentLength = textStorage?.length ?? (rawSource as NSString).length
        let offset = min(max(0, selection.location), documentLength)
        guard let location = tlm.location(tlm.documentRange.location, offsetBy: offset)
        else { return nil }

        tlm.ensureLayout(for: NSTextRange(location: location))
        var fragment = tlm.textLayoutFragment(for: location)
        // At a non-newline EOF, TextKit 2 may expose a valid document-end
        // location but no fragment for it. The insertion point still belongs
        // to the preceding line (not a phantom new paragraph), so borrow that
        // fragment while keeping the end location for the x-position lookup.
        if fragment == nil, offset == documentLength, offset > 0,
           !(textStorage?.string.hasSuffix("\n") ?? rawSource.hasSuffix("\n")),
           let previous = tlm.location(tlm.documentRange.location, offsetBy: offset - 1) {
            tlm.ensureLayout(for: NSTextRange(location: previous))
            fragment = tlm.textLayoutFragment(for: previous)
        }
        guard let fragment,
              let paragraphStart = fragment.textElement?.elementRange?.location
        else { return nil }

        let offsetInParagraph = tlm.offset(from: paragraphStart, to: location)
        let line = fragment.textLineFragments.first {
            offsetInParagraph >= $0.characterRange.location
                && offsetInParagraph <= NSMaxRange($0.characterRange)
        } ?? fragment.textLineFragments.last
        guard let line else { return nil }

        let font = insertionPointFont(at: offset)
        let fragmentFrame = fragment.layoutFragmentFrame
        let x = textContainerOrigin.x
            + fragmentFrame.minX
            + line.typographicBounds.minX
            + line.locationForCharacter(at: offsetInParagraph).x
        let baseline = textContainerOrigin.y
            + fragmentFrame.minY
            + line.typographicBounds.minY
            + line.glyphOrigin.y
        let height = ceil(font.ascender - font.descender)
        return CGRect(x: x, y: baseline - font.ascender, width: 2, height: height)
    }

    private func markedTextInsertionPointFrame(selection: NSRange,
                                               tlm: NSTextLayoutManager) -> CGRect? {
        let marked = markedRange()
        guard marked.location != NSNotFound,
              selection.location >= marked.location,
              selection.location <= NSMaxRange(marked),
              let location = tlm.location(tlm.documentRange.location,
                                          offsetBy: marked.location)
        else { return nil }

        tlm.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = tlm.textLayoutFragment(for: location),
              let paragraphStart = fragment.textElement?.elementRange?.location
        else { return nil }

        let markedStartInParagraph = tlm.offset(from: paragraphStart, to: location)
        let caretInParagraph = markedStartInParagraph + selection.location - marked.location
        let line = fragment.textLineFragments.first {
            caretInParagraph >= $0.characterRange.location
                && caretInParagraph <= NSMaxRange($0.characterRange)
        } ?? fragment.textLineFragments.last
        guard let line else { return nil }

        let font = insertionPointFont(at: selection.location)
        let fragmentFrame = fragment.layoutFragmentFrame
        let x = textContainerOrigin.x
            + fragmentFrame.minX
            + line.typographicBounds.minX
            + line.locationForCharacter(at: caretInParagraph).x
        let baseline = textContainerOrigin.y
            + fragmentFrame.minY
            + line.typographicBounds.minY
            + line.glyphOrigin.y
        let height = ceil(font.ascender - font.descender)
        return CGRect(x: x, y: baseline - font.ascender, width: 2, height: height)
    }

    private func insertionPointFont(at offset: Int) -> NSFont {
        guard let storage = textStorage, storage.length > 0 else { return bodyFont }
        let index = min(max(0, offset), storage.length - 1)
        let effective = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        // Hidden Markdown delimiters use a near-zero font. A caret beside one
        // still belongs to the surrounding body line, never to the hidden glyph.
        guard let effective, effective.pointSize >= bodyFont.pointSize else { return bodyFont }
        return effective
    }
}
