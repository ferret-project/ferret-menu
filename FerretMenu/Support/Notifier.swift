import AppKit
import FerretKit
import UserNotifications

/// Which bell items are new enough to tell someone about: urgent ones not seen urgent before. The first look at a
/// server (nothing remembered yet) tells nothing, so signing in doesn't bring a burst of old news.
struct NotificationPolicy: Equatable, Sendable {
    /// The urgent items' keys remembered from the last look; nil before the first.
    var known: Set<String>?

    /// What to tell now, and what to remember: only what's urgent now, so one that comes back is told again.
    mutating func newlyUrgent(in items: [AttentionItem]) -> [AttentionItem] {
        let urgent = items.filter(\.isUrgent)
        defer { known = Set(urgent.map(\.key)) }
        guard let known else { return [] }
        return urgent.filter { !known.contains($0.key) }
    }
}

/// macOS notifications for newly urgent bell items; clicking one opens it in Ferret.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// More than this at once becomes one notification ("4 things need doing").
    static let most = 3

    private var center: UNUserNotificationCenter { .current() }

    /// Opens Ferret Menu's own bell list (set by the app delegate).
    var openBell: () -> Void = {}

    /// What clicking a notification does: several at once open the bell list here; one opens its own place in Ferret.
    enum Target: Equatable {
        case bell
        case web(URL)
    }

    nonisolated static func target(of userInfo: [AnyHashable: Any]) -> Target? {
        if userInfo["bell"] as? Bool == true { return .bell }
        guard let address = userInfo["url"] as? String, let url = URL(string: address) else { return nil }
        return .web(url)
    }

    func activate() {
        center.delegate = self
    }

    /// Asks once; later calls just say whether it's allowed.
    @discardableResult
    func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    func status() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func post(_ items: [AttentionItem], server: URL) {
        guard !items.isEmpty else { return }
        if items.count > Self.most {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(items.count) things need doing")
            content.body = items.prefix(Self.most).map(\.title).joined(separator: ", ") + "…"
            content.userInfo = ["bell": true]
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "ferret-bell-many", content: content, trigger: nil))
            return
        }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.detail
            content.userInfo = ["url": webURL(server: server, route: item.route).absoluteString]
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "ferret-\(item.key)", content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch Self.target(of: response.notification.request.content.userInfo) {
        case .bell: await MainActor.run { openBell() }
        case .web(let url): await MainActor.run { _ = NSWorkspace.shared.open(url) }
        case nil: break
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
