import Foundation
import Observation

/// A version number as releases are tagged (`v0.2.1` or `0.2.1`), compared part by part (0.10 is after 0.9).
struct Version: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        let numbers = trimmed.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0 ..< max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }

    /// This build's version (`CFBundleShortVersionString`).
    static var running: Version {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Version.init) ?? Version("0")!
    }
}

/// A newer release on GitHub.
struct AvailableUpdate: Equatable, Sendable {
    let version: String
    /// The release's page (what's new, and the download).
    let page: URL
}

/// Looks for a newer Ferret Menu on GitHub's releases: once a day while switched on, and when asked. Only GitHub
/// is asked, and only for the latest release; nothing about this Mac or the person's Ferret is sent.
@MainActor
@Observable
final class Updates {
    static let latest = URL(string: "https://api.github.com/repos/ferret-project/ferret-menu/releases/latest")!
    static let every: TimeInterval = 24 * 60 * 60

    private(set) var available: AvailableUpdate?
    private(set) var checking = false
    /// What the last check found, for Settings ("Up to date", or why it couldn't check).
    private(set) var lastResult: String?

    private let defaults: UserDefaults
    private let session: URLSession
    private let running: Version
    private var ticker: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared, running: Version = .running) {
        self.defaults = defaults
        self.session = session
        self.running = running
    }

    var automatic: Bool {
        get { defaults.object(forKey: "checkForUpdates") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "checkForUpdates")
            if newValue { start() } else { ticker?.cancel() }
        }
    }

    var lastChecked: Date? { defaults.object(forKey: "updatesCheckedAt") as? Date }

    /// Checks now if a day has passed since the last check, then once a day.
    func start() {
        ticker?.cancel()
        guard automatic else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled, let self {
                let since = self.lastChecked.map { Date().timeIntervalSince($0) } ?? .infinity
                if since >= Updates.every { await self.check() }
                let wait = Updates.every - min(since, Updates.every)
                try? await Task.sleep(for: .seconds(max(wait, 60 * 60)))
            }
        }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: Self.latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FerretMenu/\(running)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            defaults.set(Date(), forKey: "updatesCheckedAt")
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                // No release yet.
                available = nil
                lastResult = String(localized: "Up to date")
                return
            }
            guard status == 200 else {
                lastResult = String(localized: "Couldn't check (GitHub answered \(status))")
                return
            }
            available = Self.newer(in: data, than: running)
            lastResult = available == nil ? String(localized: "Up to date") : nil
        } catch {
            lastResult = String(localized: "Couldn't check: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// For checking the banner before there's a release (DebugHooks).
    func pretend(_ version: String) {
        available = AvailableUpdate(version: version, page: URL(string: "https://github.com/ferret-project/ferret-menu/releases")!)
    }
    #endif

    /// The release in GitHub's reply, if it's newer than `running` (drafts and prereleases never count).
    nonisolated static func newer(in data: Data, than running: Version) -> AvailableUpdate? {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = Version(release.tag_name), running < version
        else { return nil }
        return AvailableUpdate(version: version.description, page: release.html_url)
    }
}
