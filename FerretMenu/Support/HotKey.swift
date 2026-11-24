import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut that works from any app (Carbon's hot keys: no Accessibility permission needed).
struct Shortcut: Codable, Equatable, Sendable {
    /// A virtual key code (`kVK_ANSI_F`…).
    var keyCode: UInt32
    /// Carbon modifier flags (`cmdKey | optionKey`…).
    var modifiers: UInt32
    /// The key as typed, for showing ("F").
    var key: String

    /// ⌃⌥⌘F: rarely taken by other apps (⌥⌘F is Find and Replace in many).
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey | cmdKey), key: "F")

    /// "⌃⌥⌘F", in the order macOS menus show modifiers.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// A shortcut from a key press, or nil when it has no ⌘, ⌥ or ⌃ (a plain key would take that key from every app).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: Shortcut.carbon(flags), key: Shortcut.name(of: event))
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    private static func name(of event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return String(localized: "Space")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case let code where functionKeys.contains(code):
            return "F\(functionKeys.firstIndex(of: code)! + 1)"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
}

/// The one global shortcut: opens the menu bar window from any app.
@MainActor
final class HotKey {
    static let shared = HotKey()

    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers `shortcut` (nil: none). False when macOS refused it (another app has it).
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let shortcut else { return true }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4652_5254), id: 1) // "FRRT"
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetEventDispatcherTarget(), 0, &ref) == noErr
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            Task { @MainActor in HotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
