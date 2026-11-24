import AppKit
import Observation
import Sparkle

/// Updates through Sparkle: once a day it reads the latest release's feed (`SUFeedURL`), and an update installs only
/// when it's signed with the release key (`SUPublicEDKey`). A menu bar app mustn't pop a window over someone's work,
/// so a scheduled find shows as a line in Ferret Menu's window ("gentle reminders"); "Install" (or Check for Updates)
/// opens Sparkle's own window, which downloads, installs and relaunches.
@MainActor
@Observable
final class Updates: NSObject {
    /// A version found by the daily check that hasn't been looked at yet.
    private(set) var available: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    /// `start`: false in unit tests (no checks, no windows).
    init(start: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    var automatic: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// Downloads updates by itself and installs them when Ferret Menu quits.
    var downloadsByItself: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastChecked: Date? { updater.lastUpdateCheckDate }

    /// Sparkle's window: what's new, then download, install and relaunch.
    func checkNow() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

extension Updates: @preconcurrency SPUUpdaterDelegate {
    #if DEBUG
    /// Debug builds can read a local feed, for trying an update end to end (DebugHooks).
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "debugFeedURL")
    }
    #endif
}

extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's window only when someone is likely looking (just launched, or back after being away); otherwise
    /// the line in Ferret Menu's window.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { available = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        available = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
    }
}
