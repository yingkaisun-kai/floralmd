import AppKit
import FloralMDCore

@MainActor
private final class GitHistoryBadgeLabel: NSTextField {
    init(color: NSColor) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 9, weight: .semibold)
        alignment = .center
        textColor = color
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        wantsLayer = true
        layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class GitHistoryCellView: NSTableCellView {
    private let graphView = GitGraphRowView()
    private let headBadge = GitHistoryBadgeLabel(color: .systemBlue)
    private let branchBadge = GitHistoryBadgeLabel(color: .systemBlue)
    private let subjectField = QuietSidebarLabel()
    private let metadataField = QuietSidebarLabel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        graphView.translatesAutoresizingMaskIntoConstraints = false
        headBadge.stringValue = "HEAD"
        headBadge.setContentHuggingPriority(.required, for: .horizontal)
        headBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        branchBadge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        subjectField.font = .systemFont(ofSize: 11.5, weight: .medium)
        subjectField.lineBreakMode = .byTruncatingTail
        subjectField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subjectField.translatesAutoresizingMaskIntoConstraints = false
        metadataField.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        metadataField.textColor = .secondaryLabelColor
        metadataField.lineBreakMode = .byTruncatingTail
        metadataField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(graphView)
        let titleRow = NSStackView(views: [headBadge, branchBadge, subjectField])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleRow)
        addSubview(metadataField)
        NSLayoutConstraint.activate([
            graphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            graphView.topAnchor.constraint(equalTo: topAnchor),
            graphView.bottomAnchor.constraint(equalTo: bottomAnchor),
            graphView.widthAnchor.constraint(equalToConstant: 48),
            titleRow.leadingAnchor.constraint(equalTo: graphView.trailingAnchor, constant: 3),
            titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleRow.heightAnchor.constraint(equalToConstant: 17),
            headBadge.widthAnchor.constraint(equalToConstant: 34),
            headBadge.heightAnchor.constraint(equalToConstant: 16),
            branchBadge.heightAnchor.constraint(equalToConstant: 16),
            branchBadge.widthAnchor.constraint(lessThanOrEqualTo: titleRow.widthAnchor,
                                                multiplier: 0.42),
            metadataField.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            metadataField.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            metadataField.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(commit: GitCommit, row: GitGraphRow, isHEAD: Bool) {
        graphView.configure(commitID: commit.id, row: row, isHEAD: isHEAD)
        let presentation = GitHistoryRowPresentation(commit: commit, isHEAD: isHEAD)
        headBadge.isHidden = presentation.headLabel == nil
        headBadge.toolTip = isHEAD ? "HEAD" : nil
        branchBadge.isHidden = presentation.branchLabel == nil
        branchBadge.stringValue = presentation.branchLabel ?? ""
        branchBadge.toolTip = presentation.branchLabel
        subjectField.stringValue = presentation.subject
        subjectField.toolTip = presentation.subject
        let date = commit.authoredAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
        } ?? commit.authoredAtText
        metadataField.stringValue = "\(commit.shortID)  ·  \(commit.author)  ·  \(date)"
        metadataField.toolTip = metadataField.stringValue
        setAccessibilityLabel(
            [presentation.headLabel, presentation.branchLabel, presentation.subject,
             commit.shortID, commit.author, date]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }
}

@MainActor
private final class GitGraphRowView: NSView {
    private static let colors: [NSColor] = [
        .systemBlue, .systemOrange, .systemPurple, .systemGreen, .systemPink,
    ]
    private var commitID = ""
    private var row: GitGraphRow?
    private var isHEAD = false

    override var isFlipped: Bool { true }

    func configure(commitID: String, row: GitGraphRow, isHEAD: Bool) {
        self.commitID = commitID
        self.row = row
        self.isHEAD = isHEAD
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let nodeY = bounds.midY
        let bottomY = bounds.maxY

        func x(_ lane: Int) -> CGFloat { 6 + CGFloat(lane) * 9 }
        func color(_ lane: Int) -> NSColor {
            Self.colors[lane % Self.colors.count]
        }
        func line(from start: NSPoint, to end: NSPoint, lane: Int) {
            let path = NSBezierPath()
            path.move(to: start)
            let segment = GitGraphGeometry.connector(
                from: GitGraphPoint(x: start.x, y: start.y),
                to: GitGraphPoint(x: end.x, y: end.y)
            )
            switch segment {
            case .line(_, let end):
                path.line(to: NSPoint(x: end.x, y: end.y))
            case .cubic(_, let control1, let control2, let end):
                path.curve(
                    to: NSPoint(x: end.x, y: end.y),
                    controlPoint1: NSPoint(x: control1.x, y: control1.y),
                    controlPoint2: NSPoint(x: control2.x, y: control2.y)
                )
            }
            path.lineWidth = 1.4
            color(lane).withAlphaComponent(0.8).setStroke()
            path.stroke()
        }

        for (incomingLane, id) in row.incomingLanes.enumerated() {
            if id == commitID {
                line(from: NSPoint(x: x(incomingLane), y: bounds.minY),
                     to: NSPoint(x: x(row.commitLane), y: nodeY), lane: incomingLane)
            } else if let outgoingLane = row.outgoingLanes.firstIndex(of: id) {
                line(from: NSPoint(x: x(incomingLane), y: bounds.minY),
                     to: NSPoint(x: x(outgoingLane), y: bottomY), lane: incomingLane)
            }
        }
        for parentLane in row.parentLanes {
            line(from: NSPoint(x: x(row.commitLane), y: nodeY),
                 to: NSPoint(x: x(parentLane), y: bottomY), lane: parentLane)
        }

        let radius: CGFloat = isHEAD ? 4.5 : 3.5
        let node = NSBezierPath(ovalIn: NSRect(
            x: x(row.commitLane) - radius,
            y: nodeY - radius,
            width: radius * 2,
            height: radius * 2
        ))
        color(row.commitLane).setFill()
        node.fill()
        if isHEAD {
            NSColor.controlBackgroundColor.setStroke()
            node.lineWidth = 1.5
            node.stroke()
        }
    }
}

@MainActor
final class GitCommitDetailViewController: NSViewController {
    private let commit: GitCommit
    private let isHEAD: Bool

    init(commit: GitCommit, isHEAD: Bool) {
        self.commit = commit
        self.isHEAD = isHEAD
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 360, height: 230)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = font
            field.textColor = color
            field.isSelectable = true
            return field
        }

        let title = label(commit.subject, font: .systemFont(ofSize: 15, weight: .semibold))
        let refs = ([isHEAD ? "HEAD" : nil] + commit.localBranches.map(Optional.some))
            .compactMap { $0 }.joined(separator: "  ·  ")
        let refsField = label(refs, font: .systemFont(ofSize: 11, weight: .medium),
                              color: .systemBlue)
        refsField.isHidden = refs.isEmpty
        let date = commit.authoredAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium)
        } ?? commit.authoredAtText
        let author = label("\(commit.author)  ·  \(date)", font: .systemFont(ofSize: 11),
                           color: .secondaryLabelColor)
        let hash = label(commit.id, font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                         color: .secondaryLabelColor)
        let parentsText = commit.parentIDs.isEmpty
            ? AppCopy.text("Root commit", "根提交")
            : AppCopy.text("Parents: ", "父提交：") + commit.parentIDs.map { String($0.prefix(7)) }
                .joined(separator: ", ")
        let parents = label(parentsText, font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                            color: .secondaryLabelColor)
        let copyButton = NSButton(
            title: AppCopy.text("Copy Hash", "复制哈希"),
            target: self,
            action: #selector(copyHash(_:))
        )
        copyButton.bezelStyle = .rounded

        let stack = NSStackView(views: [title, refsField, author, hash, parents, copyButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
            copyButton.widthAnchor.constraint(equalToConstant: 96),
        ])
        view = container
    }

    @objc private func copyHash(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.id, forType: .string)
    }
}
