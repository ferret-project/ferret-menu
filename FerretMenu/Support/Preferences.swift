import Foundation
import ServiceManagement

/// Settings kept on this Mac (UserDefaults; the sign-in is in the Keychain).
@MainActor
enum Preferences {
    /// The global shortcut; nil when it's switched off. ⌃⌥⌘F until changed.
    static var shortcut: Shortcut? {
        get {
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "shortcutOff") { return nil }
            guard let data = defaults.data(forKey: "shortcut") else { return .standard }
            return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? .standard
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue == nil, forKey: "shortcutOff")
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "shortcut")
        }
    }

    /// Opens at login (a login item macOS lists in General → Login Items).
    static var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws when macOS refuses (it then asks for approval in System Settings).
    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
