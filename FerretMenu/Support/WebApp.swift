import AppKit

/// Ferret's web app installed on this Mac with Chrome, Edge or Brave, chosen in Settings. Pages open in it through
/// `web+ferret:` links: Ferret's manifest makes the installed app their handler (Ferret 2026.11.28 or newer), and the
/// app opens only pages of its own server. A sandboxed app can't start a web app at an address any other way.
struct WebApp: Codable, Equatable, Sendable {
    /// Where the app is (`~/Applications/Chrome Apps.localized/Ferret.app`).
    let path: String
    let name: String
    /// The server it was installed from (`https://ferret.example.com`).
    let origin: String

    /// Reads a chosen app. Chromium web apps say what they open (`CrAppModeShortcutURL`); anything else is nil.
    static func read(_ url: URL) -> WebApp? {
        guard let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")),
              let start = (info["CrAppModeShortcutURL"] as? String).flatMap(URL.init(string:)),
              let origin = origin(of: start)
        else { return nil }
        let name = info["CrAppModeShortcutName"] as? String ?? url.deletingPathExtension().lastPathComponent
        return WebApp(path: url.standardizedFileURL.path, name: name, origin: origin)
    }

    /// `https://host[:port]`.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host()?.lowercased() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    func isFor(_ server: URL) -> Bool { Self.origin(of: server) == origin }

    var host: String { URL(string: origin)?.host() ?? origin }

    /// The `web+ferret:` link for a page: its address percent-encoded, so nothing on the way drops its `#…`.
    static func link(to page: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return page.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "web+ferret:" + $0) }
    }

    /// Whether macOS hands `web+ferret:` links to this app: true once it has opened a Ferret new enough to say it
    /// handles them (and Chrome was allowed to, if it asked).
    var handlesLinks: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "web+ferret:test")!) else { return false }
        return handler.standardizedFileURL.path == path
    }
}
