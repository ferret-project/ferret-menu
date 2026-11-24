#if DEBUG
import AppKit
import FerretKit
import os

/// Debug builds only: lets a script drive the app and look at it, for checking it end to end without clicking
/// (`scripts/drive.swift`). Commands come as a distributed notification whose object is `command:argument`;
/// snapshots land in the app's container (`~/Library/Containers/us.digitalempire.ferret.menu/Data/tmp/`).
@MainActor
enum DebugHooks {
    static let name = Notification.Name("us.digitalempire.ferret.menu.debug")
    static let log = Logger(subsystem: "us.digitalempire.ferret.menu", category: "debug")
    private static var pendingSignIn: OAuth.Start?

    static func install(model: AppModel, menuBar: MenuBarController) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let text = note.object as? String ?? ""
            Task { @MainActor in await run(text, model: model, menuBar: menuBar) }
        }
    }

    private static func run(_ text: String, model: AppModel, menuBar: MenuBarController) async {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        log.notice("debug command \(command, privacy: .public)")
        switch command {
        case "show":
            let screens: [String: Screen] = ["search": .search, "bell": .bell, "ask": .ask, "add": .add]
            menuBar.show(on: screens[argument])
        case "close":
            model.closeWindow()
        case "query":
            model.query = argument
        case "signout":
            model.signOut()
        case "stage":
            model.stage(PickedFile.from([URL(fileURLWithPath: argument)]))
        case "add":
            do {
                let (item, failed) = try await model.add(name: argument, placeId: nil, quantity: nil, files: model.staged)
                model.staged = []
                log.notice("added \(item.id, privacy: .public) \(item.name, privacy: .public) failed=\(failed, privacy: .public)")
            } catch {
                log.error("add failed \(AppModel.describe(error), privacy: .public)")
            }
        case "ask":
            do {
                let answer = try await model.ask(argument)
                log.notice("answer found=\(answer.found) \(answer.answer, privacy: .public) from=\(answer.citations.map(\.label), privacy: .public)")
            } catch {
                log.error("ask failed \(AppModel.describe(error), privacy: .public)")
            }
        case "search":
            do {
                let found = try await model.search(argument)
                log.notice("search \(argument, privacy: .public) → \(found.map(\.name), privacy: .public)")
            } catch {
                log.error("search failed \(AppModel.describe(error), privacy: .public)")
            }
        case "oauth-start":
            // The app's own sign-in, with the browser part done elsewhere: logs the address to open.
            guard let server = ServerAddress.parse(argument) else { return }
            do {
                let start = try await OAuth.start(server: server, clientName: SignInView.clientName, redirectURI: AppModel.redirectURI, knownClientId: model.clientId(for: server))
                model.saveClientId(start.clientId, for: server)
                pendingSignIn = start
                log.notice("oauth-url \(start.url.absoluteString, privacy: .public)")
            } catch {
                log.error("oauth-start failed \(AppModel.describe(error), privacy: .public)")
            }
        case "oauth-finish":
            guard let start = pendingSignIn, let callback = URL(string: argument) else { return }
            do {
                let tokens = try await OAuth.finish(start, callback: callback)
                model.signedIn(Session(server: start.endpoints.server!, credential: .oauth(tokens)))
                log.notice("oauth-finish signed in, expires \(tokens.expiresAt, privacy: .public)")
            } catch {
                log.error("oauth-finish failed \(AppModel.describe(error), privacy: .public)")
            }
        case "expire":
            // Makes the access token look ended, so the next call refreshes it.
            guard var session = model.session, case .oauth(var tokens) = session.credential else { return }
            tokens.expiresAt = .distantPast
            session.credential = .oauth(tokens)
            model.signedIn(session)
        case "tokens":
            if case .oauth(let tokens) = model.session?.credential {
                log.notice("tokens access=\(String(tokens.accessToken.prefix(14)), privacy: .public)… refresh=\(String((tokens.refreshToken ?? "").prefix(14)), privacy: .public)… expires \(tokens.expiresAt, privacy: .public)")
            }
        case "settings":
            model.openSettings()
        case "snapshot":
            write(menuBar.windowView, to: argument)
        case "snapshot-settings":
            write(SettingsOpener.view, to: argument)
        case "state":
            let state: [String: Any] = [
                "signedIn": model.signedIn,
                "server": model.server?.absoluteString ?? "",
                "household": model.householdName ?? "",
                "things": model.summary?.things ?? -1,
                "urgent": model.urgentCount,
                "attention": model.attention.map(\.title),
                "recent": model.recent.map(\.name),
                "canEdit": model.canEdit,
                "canAsk": model.canAsk,
                "screen": "\(model.screen)",
                "staged": model.staged.map(\.name),
                "message": model.message ?? "",
                "unreachable": model.unreachable,
                "badge": menuBar.badgeTitle,
                "iconVisible": menuBar.iconShown,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            log.notice("state \(json, privacy: .public)")
        default:
            log.error("unknown debug command \(command, privacy: .public)")
        }
    }

    private static func write(_ view: NSView?, to name: String) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: (name.isEmpty ? "snapshot" : name) + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log.notice("snapshot \(url.path, privacy: .public)")
    }
}
#endif
