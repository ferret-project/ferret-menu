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
            content.userInfo = ["url": webURL(server: server, route: "#/").absoluteString, "bell": true]
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
        guard let address = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: address) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
