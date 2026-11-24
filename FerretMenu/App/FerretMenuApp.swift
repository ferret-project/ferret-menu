import AppKit
import SwiftUI

@main
struct FerretMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var menuBar: MenuBarController?

    /// Unit tests load the app as their host: no menu bar icon, no network.
    private var testing: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !testing else { return }
        Notifier.shared.activate()
        let menuBar = MenuBarController(model: model) { [weak self] in self?.openSettings() }
        self.menuBar = menuBar
        model.openSettings = { [weak self] in self?.openSettings() }
        HotKey.shared.action = { [weak menuBar] in menuBar?.toggle() }
        HotKey.shared.register(Preferences.shortcut)
        model.start()
        model.updates = Updates(start: true)
        #if DEBUG
        DebugHooks.install(model: model, menuBar: menuBar)
        #endif
        // The Mac woke up or came back online: the bell may have news.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        }
        // First run (nothing kept): open the sign-in. Waits a moment for the Keychain read.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if !self.model.signedIn, !self.model.hasKeptSession { menuBar.show() }
        }
    }

    /// The Settings window, in front (a menu bar app isn't active until asked).
    func openSettings() {
        model.closeWindow()
        SettingsOpener.model = model
        SettingsOpener.open()
    }
}
