import AppKit
import SwiftUI

/// The Settings window. Its own window rather than SwiftUI's Settings scene, which a menu bar app can't reliably open
/// from AppKit (the right-click menu, the window's gear).
@MainActor
enum SettingsOpener {
    private static var window: NSWindow?
    static var model: AppModel?
    static var view: NSView? { window?.contentView }

    static func open() {
        guard let model else { return }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(model))
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Ferret Menu Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
