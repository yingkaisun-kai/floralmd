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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        drawerBackground.translatesAutoresizingMaskIntoConstraints = false

        separator.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 29
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
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

            header.leadingAnchor.constraint(equalTo: drawerBackground.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: drawerBackground.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: drawerBackground.topAnchor, constant: 13),
            header.heightAnchor.constraint(equalToConstant: 30),

            scrollView.leadingAnchor.constraint(equalTo: drawerBackground.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: drawerBackground.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: drawerBackground.bottomAnchor, constant: -8),

            separator.trailingAnchor.constraint(equalTo: drawerBackground.trailingAnchor),
            separator.topAnchor.constraint(equalTo: drawerBackground.topAnchor),
            separator.bottomAnchor.constraint(equalTo: drawerBackground.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage),
                                               name: .appLanguageDidChange, object: nil)
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
        titleLabel.stringValue = AppCopy.text("Outline", "大纲")
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
