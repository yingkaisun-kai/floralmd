import AppKit
import FloralMDCore

/// An outline drawer attached to the editing surface. The repository sidebar
/// may shift this drawer to the right, but it remains the editor's immediate
/// neighbor rather than becoming part of the repository navigation chrome.
final class OutlineSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let expandedWidth: CGFloat = 320
    static let collapsedWidth: CGFloat = 0

    private let drawerBackground = QuietSidebarBackgroundView(role: .document)
    private let separator = QuietSidebarSeparatorView()
    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: AppCopy.text("Outline", "大纲"))
    private let collapseButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var items: [MarkdownOutlineItem] = []
    private var widthConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private(set) var isExpanded = true

    var backgroundOpacity: CGFloat {
        get { drawerBackground.backgroundOpacity }
        set { drawerBackground.backgroundOpacity = newValue }
    }

    var onSelectHeading: ((String) -> Void)?
    var onWidthChange: ((CGFloat, TimeInterval) -> Void)?
    var onCollapseRequest: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        drawerBackground.translatesAutoresizingMaskIntoConstraints = false

        separator.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        collapseButton.bezelStyle = .accessoryBarAction
        collapseButton.isBordered = false
        collapseButton.imagePosition = .imageOnly
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.target = self
        collapseButton.action = #selector(requestCollapse(_:))
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collapseButton.widthAnchor.constraint(
                equalToConstant: DocumentPaneLayout.documentControlSize
            ),
            collapseButton.heightAnchor.constraint(
                equalToConstant: DocumentPaneLayout.documentControlSize
            ),
        ])

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(collapseButton)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(selectHeading(_:))

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(drawerBackground)
        drawerBackground.addSubview(header)
        drawerBackground.addSubview(scrollView)
        drawerBackground.addSubview(separator)
        NSLayoutConstraint.activate([
            drawerBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            drawerBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            drawerBackground.topAnchor.constraint(equalTo: topAnchor),
            drawerBackground.bottomAnchor.constraint(equalTo: bottomAnchor),

            header.leadingAnchor.constraint(
                equalTo: drawerBackground.leadingAnchor,
                constant: DocumentPaneLayout.documentControlInset
            ),
            header.trailingAnchor.constraint(equalTo: drawerBackground.trailingAnchor, constant: -14),
            header.topAnchor.constraint(
                equalTo: drawerBackground.topAnchor,
                constant: DocumentPaneLayout.documentControlInset
            ),
            header.heightAnchor.constraint(
                equalToConstant: DocumentPaneLayout.documentControlSize
            ),

            scrollView.leadingAnchor.constraint(equalTo: drawerBackground.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: drawerBackground.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: drawerBackground.bottomAnchor, constant: -12),

            separator.trailingAnchor.constraint(equalTo: drawerBackground.trailingAnchor),
            separator.topAnchor.constraint(equalTo: drawerBackground.topAnchor),
            separator.bottomAnchor.constraint(equalTo: drawerBackground.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage),
                                               name: .appLanguageDidChange, object: nil)
        refreshLocalizedControls()
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    func installConstraints(in container: NSView, leadingOffset: CGFloat) {
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.expandedWidth)
        leadingConstraint = leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                     constant: leadingOffset)
        NSLayoutConstraint.activate([
            leadingConstraint,
            topAnchor.constraint(equalTo: container.topAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
            widthConstraint,
        ])
    }

    func setLeadingOffset(_ offset: CGFloat) {
        leadingConstraint.constant = offset
    }

    func setItems(_ newItems: [MarkdownOutlineItem]) {
        items = newItems
        tableView.reloadData()
    }

    func toggleExpanded() {
        setExpanded(!isExpanded, animated: true)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard let superview else { return }
        guard isExpanded != expanded else { return }
        superview.layoutSubtreeIfNeeded()
        isExpanded = expanded

        if isExpanded {
            drawerBackground.isHidden = false
            titleLabel.isHidden = false
            scrollView.isHidden = false
            separator.isHidden = false
            drawerBackground.alphaValue = 0
        }

        let targetWidth = isExpanded ? Self.expandedWidth : Self.collapsedWidth
        widthConstraint.constant = targetWidth
        let duration = animated ? 0.22 : 0
        onWidthChange?(targetWidth, duration)

        guard animated else {
            drawerBackground.alphaValue = 1
            titleLabel.isHidden = !isExpanded
            scrollView.isHidden = !isExpanded
            separator.isHidden = !isExpanded
            drawerBackground.isHidden = !isExpanded
            superview.layoutSubtreeIfNeeded()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            drawerBackground.animator().alphaValue = isExpanded ? 1 : 0
            superview.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExpanded else { return }
                self.titleLabel.isHidden = true
                self.scrollView.isHidden = true
                self.separator.isHidden = true
                self.drawerBackground.isHidden = true
                self.drawerBackground.alphaValue = 1
            }
        }
    }

    @objc private func refreshLanguage() {
        refreshLocalizedControls()
    }

    private func refreshLocalizedControls() {
        titleLabel.stringValue = AppCopy.text("Outline", "大纲")
        let description = AppCopy.text("Collapse outline", "收起大纲")
        collapseButton.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: description
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        collapseButton.toolTip = description
        collapseButton.setAccessibilityLabel(description)
    }

    @objc private func requestCollapse(_ sender: Any?) {
        onCollapseRequest?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("OutlineHeadingCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = QuietSidebarCellView()
            cell.identifier = id
            let field = QuietSidebarLabel()
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        guard let field = cell.textField else { return cell }
        let item = items[row]
        let paragraph = NSMutableParagraphStyle()
        let indent = CGFloat(min(max(0, item.level - 1), 4)) * 16
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        field.attributedStringValue = NSAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13,
                                         weight: item.level == 1 ? .medium : .regular),
                .foregroundColor: item.level == 1
                    ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        QuietSidebarRowView()
    }

    @objc private func selectHeading(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard items.indices.contains(row) else { return }
        onSelectHeading?(items[row].title)
    }
}

/// A document-level control that stays fixed in the editor margin while the
/// text scrolls underneath. It is a sibling of NSTextView, never text content.
final class OutlineFloatingButton: NSButton {
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .accessoryBarAction
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = isDark
            ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.155, alpha: 0.94)
            : NSColor(srgbRed: 0.995, green: 0.995, blue: 0.99, alpha: 0.96)
        let hover = isDark
            ? NSColor(srgbRed: 0.21, green: 0.21, blue: 0.205, alpha: 0.96)
            : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 0.98)
        layer?.backgroundColor = (isHovered ? hover : base).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDark ? 0.26 : 0.12
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}
