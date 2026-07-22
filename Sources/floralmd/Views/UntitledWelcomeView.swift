import AppKit

/// Quiet, document-external guidance for a semantically blank untitled editor.
/// The view sits above the editor but only its explicit controls participate in
/// hit testing; the rest passes through without disturbing the first responder.
@MainActor
final class UntitledWelcomeView: NSView {
    var onOpenRecent: ((URL) -> Void)?
    var onOpenFile: (() -> Void)?
    private(set) var isPresented = false

    private let recentURLs: [URL]
    private var inputHintLeadingConstraint: NSLayoutConstraint?
    private var inputHintTopConstraint: NSLayoutConstraint?

    init(frame frameRect: NSRect, recentURLs: [URL], inputInsets: NSSize) {
        self.recentURLs = Array(recentURLs.prefix(5))
        super.init(frame: frameRect)
        buildContent(inputInsets: inputInsets)
    }

    required init?(coder: NSCoder) { nil }

    func setPresented(_ presented: Bool, animated: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented { isHidden = false }

        let changes = { self.alphaValue = presented ? 1 : 0 }
        guard animated else {
            changes()
            isHidden = !presented
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = presented ? 0.26 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = presented ? 1 : 0
        } completionHandler: { [weak self] in
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isPresented else { return }
                    self.isHidden = true
                }
            }
        }
    }

    private func interactiveControl(at point: NSPoint) -> NSControl? {
        guard isPresented, bounds.contains(point), let hit = super.hitTest(point) else {
            return nil
        }
        var candidate: NSView? = hit
        while let view = candidate, view !== self {
            if let control = view as? UntitledWelcomeActionButton { return control }
            candidate = view.superview
        }
        return nil
    }

    func updateInputInsets(_ inputInsets: NSSize) {
        inputHintLeadingConstraint?.constant = inputInsets.width + 9
        inputHintTopConstraint?.constant = inputInsets.height - 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactiveControl(at: point)
    }

    private func buildContent(inputInsets: NSSize) {
        let inputHint = NSTextField(labelWithString: AppCopy.text(
            "Start typing here",
            "从这里开始输入"
        ))
        inputHint.font = .systemFont(ofSize: 12.5, weight: .regular)
        inputHint.textColor = .tertiaryLabelColor
        inputHint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputHint)

        inputHintLeadingConstraint = inputHint.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: inputInsets.width + 9
        )
        inputHintTopConstraint = inputHint.topAnchor.constraint(
            equalTo: topAnchor,
            constant: inputInsets.height - 1
        )
        NSLayoutConstraint.activate([
            inputHintLeadingConstraint!,
            inputHintTopConstraint!,
        ])

        let wordmark = NSTextField(labelWithString: "FloralMD")
        wordmark.font = .systemFont(ofSize: 29, weight: .semibold)
        wordmark.textColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1, alpha: 0.28)
                : NSColor(white: 0, alpha: 0.22)
        }
        wordmark.alignment = .center
        wordmark.setAccessibilityElement(false)

        var arranged: [NSView] = [wordmark]
        if !recentURLs.isEmpty {
            let recentHeading = NSTextField(labelWithString: AppCopy.text(
                "Recent Files",
                "最近文件"
            ))
            recentHeading.font = .systemFont(ofSize: 11.5, weight: .semibold)
            recentHeading.textColor = .secondaryLabelColor
            arranged.append(recentHeading)

            for url in recentURLs {
                let button = UntitledWelcomeRecentFileButton(url: url)
                button.target = self
                button.action = #selector(openRecent(_:))
                arranged.append(button)
            }
        }

        let openButton = UntitledWelcomeActionButton(
            title: AppCopy.text("Open File…", "打开文件…"),
            target: self,
            action: #selector(openFile)
        )
        openButton.isBordered = false
        openButton.bezelStyle = .inline
        openButton.font = .systemFont(ofSize: 13, weight: .medium)
        openButton.contentTintColor = .secondaryLabelColor
        openButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        openButton.imagePosition = .imageLeading
        openButton.imageHugsTitle = true
        openButton.alignment = recentURLs.isEmpty ? .center : .left
        openButton.setAccessibilityLabel(AppCopy.text("Open File", "打开文件"))
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        arranged.append(openButton)

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(22, after: wordmark)
        if let lastRecentButton = arranged.last(where: { $0 is UntitledWelcomeRecentFileButton }) {
            stack.setCustomSpacing(14, after: lastRecentButton)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -72),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 26),
        ])
        wordmark.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for control in arranged.compactMap({ $0 as? UntitledWelcomeActionButton }) {
            control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func openRecent(_ sender: UntitledWelcomeRecentFileButton) {
        onOpenRecent?(sender.url)
    }

    @objc private func openFile() {
        onOpenFile?()
    }
}

@MainActor
class UntitledWelcomeActionButton: NSButton {
    private(set) var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        contentTintColor = .secondaryLabelColor
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 7
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hoverAlpha: CGFloat = isDark ? 0.10 : 0.07
        layer?.backgroundColor = (isHovered
            ? NSColor.labelColor.withAlphaComponent(hoverAlpha)
            : NSColor.clear).cgColor
    }

    func updateHoverAppearance(isHovered: Bool) {
        contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func resetCursorRects() {
        // The editor keeps one uninterrupted I-beam across the welcome layer.
        // Clickability is communicated by immediate row highlighting instead
        // of cursor changes, avoiding AppKit cursor-rect competition entirely.
        discardCursorRects()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateHoverAppearance(isHovered: hovered)
        needsDisplay = true
    }
}

@MainActor
final class UntitledWelcomeRecentFileButton: UntitledWelcomeActionButton {
    let url: URL
    private let parentLabel: NSTextField

    init(url: URL) {
        self.url = url
        parentLabel = NSTextField(labelWithString: abbreviatedParentPath(for: url))
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle

        parentLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        parentLabel.textColor = .tertiaryLabelColor
        parentLabel.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [name, parentLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("\(url.lastPathComponent), \(url.path)")
    }

    override func updateHoverAppearance(isHovered: Bool) {
        super.updateHoverAppearance(isHovered: isHovered)
        parentLabel.textColor = isHovered ? .secondaryLabelColor : .tertiaryLabelColor
    }

    required init?(coder: NSCoder) { nil }
}

private func abbreviatedParentPath(for url: URL) -> String {
    let path = url.deletingLastPathComponent().path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}
