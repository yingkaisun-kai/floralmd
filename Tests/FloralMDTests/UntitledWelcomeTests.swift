import AppKit
import Testing
@testable import FloralMDCore
@testable import floralmd

@Suite("Untitled welcome presentation")
struct UntitledWelcomeTests {
    @Test("AppKit launch options are not mistaken for an explicit file request")
    func appKitOptionsAreNotDocuments() {
        #expect(ApplicationLifecyclePolicy.explicitDocumentPath(in: [
            "floralmd-debug",
            "-ApplePersistenceIgnoreState", "YES",
        ]) == nil)
        #expect(ApplicationLifecyclePolicy.explicitDocumentPath(in: [
            "floralmd-debug",
            "-debug.reproScript", "/tmp/input.repro",
        ]) == nil)
    }

    @Test("A positional command-line path remains an explicit file request")
    func positionalPathIsDocument() {
        #expect(ApplicationLifecyclePolicy.explicitDocumentPath(in: [
            "floralmd-debug",
            "/tmp/note.md",
            "-ApplePersistenceIgnoreState", "YES",
        ]) == "/tmp/note.md")
        #expect(ApplicationLifecyclePolicy.explicitDocumentPath(in: [
            "floralmd-debug",
            "--", "-draft.md",
        ]) == "-draft.md")
    }

    @Test("Cold launch, New, and Quick Capture share blank untitled eligibility",
          arguments: ["cold launch", "Cmd-N", "Quick Capture"])
    func everyBlankUntitledSourceIsEligible(_ source: String) {
        #expect(UntitledWelcomePresentationPolicy.shouldPresent(
            hasFileURL: false,
            rawSource: "",
            hasMarkedText: false
        ), Comment(rawValue: source))
    }

    @Test("Committed input hides and deleting back to semantic blank restores")
    func committedInputAndDeletionAreDynamic() {
        #expect(!UntitledWelcomePresentationPolicy.shouldPresent(
            hasFileURL: false,
            rawSource: "First note",
            hasMarkedText: false
        ))
        #expect(UntitledWelcomePresentationPolicy.shouldPresent(
            hasFileURL: false,
            rawSource: " \n\t",
            hasMarkedText: false
        ))
    }

    @Test("Marked text hides and cancellation back to blank restores")
    func markedTextLifecycleIsDynamic() {
        #expect(!UntitledWelcomePresentationPolicy.shouldPresent(
            hasFileURL: false,
            rawSource: "",
            hasMarkedText: true
        ))
        #expect(UntitledWelcomePresentationPolicy.shouldPresent(
            hasFileURL: false,
            rawSource: "",
            hasMarkedText: false
        ))
    }

    @Test("A file URL permanently excludes an empty document after save")
    func fileBackedDocumentsAreNeverEligible() {
        for source in ["", " \n", "Draft"] {
            #expect(!UntitledWelcomePresentationPolicy.shouldPresent(
                hasFileURL: true,
                rawSource: source,
                hasMarkedText: false
            ))
        }
    }

    @MainActor
    @Test("Hidden untitled tab preparation presents the welcome surface")
    func hiddenUntitledTabPreparationPresentsWelcome() throws {
        let document = Document()
        document.prepareForHiddenWindowPresentation()

        let contentView = try #require(document.windowControllers.first?.window?.contentView)
        let welcome = try #require(descendants(of: contentView)
            .compactMap { $0 as? UntitledWelcomeView }
            .first)
        #expect(welcome.isPresented)
        #expect(!welcome.isHidden)

        document.close()
    }

    @MainActor
    @Test("Foreground controls own actions while transparent space passes through")
    func foregroundControlsOwnHitTestingAndActions() throws {
        let recentURL = URL(fileURLWithPath: "/tmp/FloralMD welcome recent.md")
        let editorSurface = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        let welcome = UntitledWelcomeView(
            frame: editorSurface.bounds,
            recentURLs: [recentURL],
            inputInsets: NSSize(width: 24, height: 20)
        )
        welcome.setPresented(true, animated: false)

        let container = NSView(frame: editorSurface.bounds)
        container.addSubview(editorSurface)
        container.addSubview(welcome)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let recentButton = try #require(descendants(of: welcome)
            .compactMap { $0 as? UntitledWelcomeRecentFileButton }
            .first)
        let openButton = try #require(descendants(of: welcome)
            .compactMap { $0 as? UntitledWelcomeActionButton }
            .first { !($0 is UntitledWelcomeRecentFileButton) })

        var openedRecentURL: URL?
        var openFileCount = 0
        welcome.onOpenRecent = { openedRecentURL = $0 }
        welcome.onOpenFile = { openFileCount += 1 }

        let recentLeadingPoint = container.convert(
            NSPoint(x: 2, y: recentButton.bounds.midY),
            from: recentButton
        )
        let openTrailingPoint = container.convert(
            NSPoint(x: openButton.bounds.maxX - 2, y: openButton.bounds.midY),
            from: openButton
        )
        #expect(container.hitTest(recentLeadingPoint) === recentButton)
        #expect(container.hitTest(openTrailingPoint) === openButton)

        recentButton.performClick(nil)
        openButton.performClick(nil)
        #expect(openedRecentURL == recentURL)
        #expect(openFileCount == 1)

        let backgroundPoint = NSPoint(x: 20, y: 20)
        #expect(welcome.hitTest(backgroundPoint) == nil)
        #expect(container.hitTest(backgroundPoint) === editorSurface)

        let wordmark = try #require(descendants(of: welcome)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "FloralMD" })
        let wordmarkPoint = container.convert(
            NSPoint(x: wordmark.bounds.midX, y: wordmark.bounds.midY),
            from: wordmark
        )
        #expect(container.hitTest(wordmarkPoint) === editorSurface)
    }

    @MainActor
    @Test("Hover feedback strengthens the row immediately")
    func hoverFeedbackIsImmediateAndVisible() throws {
        let button = UntitledWelcomeActionButton(title: "Open File…", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 320, height: 34)
        button.appearance = NSAppearance(named: .aqua)
        button.updateLayer()
        #expect(button.layer?.backgroundColor?.alpha == 0)
        #expect(button.contentTintColor == .secondaryLabelColor)

        button.setHovered(true)
        button.updateLayer()
        let lightHoverAlpha = try #require(button.layer?.backgroundColor?.alpha)
        #expect(abs(lightHoverAlpha - 0.07) < 0.001)
        #expect(button.contentTintColor == .labelColor)

        button.appearance = NSAppearance(named: .darkAqua)
        button.updateLayer()
        let darkHoverAlpha = try #require(button.layer?.backgroundColor?.alpha)
        #expect(abs(darkHoverAlpha - 0.10) < 0.001)

        button.setHovered(false)
        button.updateLayer()
        #expect(button.layer?.backgroundColor?.alpha == 0)
        #expect(button.contentTintColor == .secondaryLabelColor)
    }
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}
