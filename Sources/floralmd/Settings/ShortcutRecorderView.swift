import AppKit
import FloralMDCore
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    let commandTitle: String
    let scope: CommandShortcut.Scope
    let shortcut: CommandShortcut?
    let onChange: (CommandShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        configure(button)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        configure(button)
    }

    private func configure(_ button: ShortcutRecorderButton) {
        button.commandTitle = commandTitle
        button.scope = scope
        button.onChange = onChange
        if !button.isRecording { button.shortcut = shortcut }
    }
}

final class ShortcutRecorderButton: NSButton {
    var commandTitle = ""
    var scope: CommandShortcut.Scope = .application
    var shortcut: CommandShortcut? {
        didSet { if !isRecording { refreshPresentation() } }
    }
    var onChange: ((CommandShortcut?) -> Void)?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(beginRecording)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        toolTip = AppCopy.text(
            "Click, then press a shortcut. Delete clears; Escape cancels.",
            "点击后按下快捷键。Delete 清除，Escape 取消。"
        )
        refreshPresentation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func beginRecording() {
        isRecording = true
        title = AppCopy.text("Type Shortcut", "按下快捷键")
        setAccessibilityValue(AppCopy.text("Recording", "正在录制"))
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            finishRecording()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onChange?(nil)
            shortcut = nil
            finishRecording()
            return
        }

        let allowed: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = event.modifierFlags.intersection(allowed)
        guard !modifiers.intersection([.command, .option, .control]).isEmpty,
              let keyEquivalent = Self.keyEquivalent(for: event),
              let keyLabel = Self.keyLabel(for: event),
              !keyEquivalent.isEmpty,
              !keyLabel.isEmpty else {
            NSSound.beep()
            return
        }

        let updated: CommandShortcut
        if scope == .global {
            updated = .global(
                event.keyCode,
                keyEquivalent: keyEquivalent,
                keyLabel: keyLabel,
                modifiers: modifiers
            )
        } else {
            updated = CommandShortcut(
                scope: .application,
                keyEquivalent: keyEquivalent,
                modifiers: modifiers,
                keyLabel: keyLabel
            )
        }
        onChange?(updated)
        shortcut = updated
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        isRecording = false
        refreshPresentation()
    }

    private func refreshPresentation() {
        title = shortcut.map(ShortcutManager.displayName(for:))
            ?? AppCopy.text("None", "无")
        setAccessibilityLabel(
            AppCopy.text("\(commandTitle) shortcut", "\(commandTitle)快捷键")
        )
        setAccessibilityValue(title)
        setAccessibilityHelp(toolTip)
    }

    private static func keyEquivalent(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default:
            return event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return AppCopy.text("Space", "空格")
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }
    }
}
