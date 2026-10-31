import AppKit
import Carbon.HIToolbox

/// Global shortcut choices for the quick switcher. A fixed list keeps this dependency-free;
/// each avoids common system and launcher shortcuts.
enum SwitcherShortcut: String, Codable, CaseIterable {
    case controlOptionSpace, controlOptionP, optionCommandD, controlCommandP, none

    var title: String {
        switch self {
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionP: "⌃⌥P"
        case .optionCommandD: "⌥⌘D"
        case .controlCommandP: "⌃⌘P"
        case .none: "None"
        }
    }

    var key: (code: UInt32, modifiers: UInt32)? {
        switch self {
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlOptionP: (UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey))
        case .optionCommandD: (UInt32(kVK_ANSI_D), UInt32(optionKey | cmdKey))
        case .controlCommandP: (UInt32(kVK_ANSI_P), UInt32(controlKey | cmdKey))
        case .none: nil
        }
    }
}

/// One system-wide hotkey through Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ shortcut: SwitcherShortcut) {
        unregister()
        guard let key = shortcut.key else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x44434B54), id: 1) // "DCKT"
        let status = RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            Log.app.error("Registering the switcher shortcut failed: \(status, privacy: .public)")
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
