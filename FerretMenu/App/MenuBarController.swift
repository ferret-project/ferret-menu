import AppKit
import FerretKit
import SwiftUI

/// The paw in the menu bar: click for the window, right-click for a short menu, drop files on it to add them.
/// The count beside the paw is how many bell items are urgent.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var drop: DropTarget?
    private var openSettings: () -> Void

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView().environment(model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        if let button = item.button {
            button.image = Paw.image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityTitle(String(localized: "Ferret"))
            drop = DropTarget(button: button) { [weak self] files in self?.dropped(files) }
        }
        item.autosaveName = "FerretMenu"

        model.closeWindow = { [weak self] in self?.popover.performClose(nil) }
        model.showWindow = { [weak self] in self?.show() }
        watchBadge()
    }

    // MARK: - The window

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    /// Opens the window (from the hotkey too) with the cursor in it.
    func show(on screen: Screen? = nil) {
        if let screen { model.screen = screen }
        guard let button = item.button else { return }
        NSApp.activate()
        if !popover.isShown {
            if iconVisible(button) {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            } else {
                // A full menu bar (the notch) hides the paw: open below the middle of the menu bar instead.
                let anchor = fallbackAnchor()
                popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            }
        }
        popover.contentViewController?.view.window?.makeKey()
        model.windowOpened()
    }

    /// Whether macOS is showing the paw: hidden status items get a window off the menu bar, or none on screen.
    private func iconVisible(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, window.occlusionState.contains(.visible), let screen = window.screen else { return false }
        return window.frame.minY >= screen.visibleFrame.maxY - 1
    }

    private var anchorWindow: NSWindow?

    /// A tiny invisible window just under the middle of the menu bar, for the window to hang from.
    private func fallbackAnchor() -> NSWindow {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.frame.midX - 1, y: screen.visibleFrame.maxY - 2, width: 2, height: 2)
        let window = anchorWindow ?? NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        anchorWindow = window
        return window
    }

    func popoverDidClose(_ notification: Notification) {
        anchorWindow?.orderOut(nil)
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        !model.holdOpen
    }

    /// Dragging the window away from the menu bar keeps it open as a window of its own (handy for dropping files).
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    /// What the window shows (for debug snapshots).
    var windowView: NSView? { popover.contentViewController?.view }
    var badgeTitle: String { item.button?.title ?? "" }
    var iconShown: Bool { item.button.map(iconVisible) ?? false }

    // MARK: - Badge

    private func watchBadge() {
        withObservationTracking {
            updateBadge(model.urgentCount, unreachable: model.unreachable, signedIn: model.signedIn)
            // On Add the window stays open while another app is used, so files can be dragged over from Finder.
            popover.behavior = model.screen == .add ? .semitransient : .transient
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchBadge() }
        }
    }

    private func updateBadge(_ urgent: Int, unreachable: Bool, signedIn: Bool) {
        guard let button = item.button else { return }
        button.title = urgent > 0 ? " \(urgent)" : ""
        button.appearsDisabled = !signedIn || unreachable
        var tip = String(localized: "Ferret")
        if !signedIn {
            tip = String(localized: "Ferret: not signed in")
        } else if unreachable {
            tip = String(localized: "Ferret: can't reach the server")
        } else if urgent > 0 {
            tip = String(localized: "Ferret: \(urgent) urgent")
        }
        button.toolTip = tip
        button.setAccessibilityValue(urgent > 0 ? String(localized: "\(urgent) urgent") : nil)
    }

    // MARK: - Right-click menu

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        if model.signedIn {
            menu.addItem(action(String(localized: "Open Ferret"), #selector(openFerret)))
            menu.addItem(action(String(localized: "Refresh"), #selector(refresh)))
            menu.addItem(.separator())
        }
        menu.addItem(action(String(localized: "Check for Updates…"), #selector(checkForUpdates)))
        menu.addItem(action(String(localized: "Settings…"), #selector(settings), key: ","))
        menu.addItem(action(String(localized: "Quit Ferret Menu"), #selector(quit), key: "q"))
        item.menu = menu
        item.button?.performClick(nil) // shows the menu at the icon
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil // so a left click opens the window again
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func openFerret() { model.open("#/") }
    @objc private func refresh() { Task { await model.refresh() } }
    @objc private func settings() { openSettings() }
    @objc private func checkForUpdates() { model.updates?.checkNow() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Dropping files on the paw

    private func dropped(_ files: [PickedFile]) {
        guard model.signedIn, !files.isEmpty else { return }
        model.stage(files)
        show(on: .add)
    }
}

/// Takes files dragged onto the menu bar icon: the status item's window is registered for file drags and this is
/// its delegate (the button itself can't be given drag handling).
@MainActor
private final class DropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    private weak var button: NSStatusBarButton?
    private let onDrop: ([PickedFile]) -> Void

    init(button: NSStatusBarButton, onDrop: @escaping ([PickedFile]) -> Void) {
        self.button = button
        self.onDrop = onDrop
        super.init()
        attach()
    }

    /// The button's window can appear a moment after the status item.
    private func attach() {
        guard let window = button?.window else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attach() }
            return
        }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    private func files(_ info: NSDraggingInfo) -> [PickedFile] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return PickedFile.from(urls)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !files(sender).isEmpty else { return [] }
        button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let picked = files(sender)
        guard !picked.isEmpty else { return false }
        onDrop(picked)
        return true
    }
}
