import AppKit
import Carbon.HIToolbox
import FloralMDCore

/// Registers one system-wide shortcut without keyboard monitoring or
/// Accessibility permission. Carbon's hot-key API is old but remains the
/// native permission-free mechanism for a discrete global shortcut.
@MainActor
final class GlobalHotKeyController {
    private static let signature: OSType = 0x50745143 // "PtQC"

    // Carbon owns these opaque pointers; all mutations still happen on the
    // main actor, while `nonisolated(unsafe)` lets deinit release them under
    // Swift 6's nonisolated-deinit rule.
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    private(set) var registeredShortcut: CommandShortcut?
    private var nextHotKeyID: UInt32 = 1
    var onPressed: (() -> Void)?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.onPressed?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Returns `noErr` when disabled or successfully registered, otherwise the
    /// Carbon status (most commonly a collision with another global shortcut).
    @discardableResult
    func update(enabled: Bool, shortcut: CommandShortcut?) -> OSStatus {
        guard enabled, let shortcut else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            registeredShortcut = nil
            return noErr
        }
        guard registeredShortcut != shortcut else { return noErr }
        guard shortcut.scope == .global, let keyCode = shortcut.keyCode else {
            return OSStatus(paramErr)
        }

        var registered: EventHotKeyRef?
        let candidateID = nextHotKeyID
        nextHotKeyID &+= 1
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers(for: shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: candidateID),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registered
        )
        if status == noErr, let registered {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = registered
            registeredShortcut = shortcut
        }
        return status
    }

    private func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
