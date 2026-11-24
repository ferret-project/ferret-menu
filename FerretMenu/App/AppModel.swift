import AppKit
import FerretKit
import Observation

/// Where the sign-in is kept: the Keychain, or a stand-in for tests.
protocol SessionKeeping: Sendable {
    func load() -> Session?
    func exists() -> Bool
    func save(_ session: Session)
    func clear()
}

extension SessionStore: SessionKeeping {}

/// The menu bar window's screens.
enum Screen: Hashable {
    case search, bell, ask, add
}

/// Everything the menu bar app knows: the sign-in, the household at a glance, the bell, and what's being added.
/// The views read it; the menu bar controller watches `urgentCount` for the badge.
@MainActor
@Observable
final class AppModel {
    static let keychainService = "us.digitalempire.ferret.menu"
    /// The app's own redirect address (its scheme is caught by the sign-in window, so it needs no URL type).
    static let callbackScheme = "us.digitalempire.ferret.menu"
    static let redirectURI = OAuth.redirectURI(scheme: callbackScheme)
    /// How often the bell is looked at while nothing else asks (opening the window always does).
    static let refreshEvery: Duration = .seconds(10 * 60)

    private(set) var session: Session?
    private(set) var client: FerretClient?
    private(set) var me: Me?
    private(set) var summary: Summary?
    private(set) var attention: [AttentionItem] = []
    private(set) var recent: [Item] = []
    private(set) var places: PlaceTree?
    private(set) var loading = false
    /// The last refresh couldn't reach the server (what's shown is from before).
    private(set) var unreachable = false
    /// Something to tell the person (an error, or why they were signed out).
    var message: String?

    var screen: Screen = .search
    /// What's typed in the search box (kept while the window is closed, like Spotlight).
    var query = ""
    /// Files waiting to be added (dropped on the menu bar icon or the Add screen).
    var staged: [PickedFile] = []
    /// Bumped to put the cursor in the search box (each time the window opens).
    private(set) var focusRequest = 0
    /// While true the window stays open when another window takes focus (the sign-in browser, a file panel).
    var holdOpen = false

    /// Set by the menu bar controller.
    var closeWindow: () -> Void = {}
    var showWindow: () -> Void = {}
    var openSettings: () -> Void = {}

    let defaults: UserDefaults
    /// A newer Ferret Menu on GitHub (checked daily; FerretMenuApp starts it).
    let updates: Updates
    private let store: SessionKeeping
    private let urlSession: URLSession?
    private var thumbs: [String: NSImage] = [:]
    private var loadingThumbs: [String: Task<NSImage?, Never>] = [:]
    private var ticker: Task<Void, Never>?
    private var policy: NotificationPolicy

    init(store: SessionKeeping = SessionStore(service: AppModel.keychainService), defaults: UserDefaults = .standard, urlSession: URLSession? = nil) {
        self.store = store
        self.defaults = defaults
        self.urlSession = urlSession
        updates = Updates(defaults: defaults)
        policy = NotificationPolicy(known: nil)
    }

    // MARK: - Who's signed in

    var signedIn: Bool { session != nil }
    /// Whether a sign-in is saved (without reading it, so no Keychain prompt).
    var hasKeptSession: Bool { store.exists() }
    var server: URL? { session?.server }
    var householdName: String? { me?.household?.name ?? summary?.household }
    /// Viewers and read-only sign-ins can look but not add.
    var canEdit: Bool {
        guard let household = me?.household else { return true }
        return household.readOnly != true && household.role != "viewer"
    }

    var canAsk: Bool { me?.features?.textAi == true }
    var urgentCount: Int { attention.count(where: \.isUrgent) }

    /// Picks up a kept sign-in, then keeps the bell fresh.
    func start() {
        // Off the main thread: if macOS asks whether the app may use its Keychain item, the menu bar stays alive.
        let store = store
        Task { [weak self] in
            let kept = await Task.detached { store.load() }.value
            if let kept, let self, self.session == nil { self.use(kept) }
        }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.refreshEvery)
                await self?.refresh()
            }
        }
    }

    func signedIn(_ session: Session) {
        store.save(session)
        message = nil
        use(session)
    }

    /// Ends the sign-in here and, for an app sign-in, on the server.
    func signOut() {
        if let session, case .oauth(let tokens) = session.credential {
            let http = urlSession ?? .ferret(access: session.access)
            Task.detached { await OAuth.revoke(tokens, server: session.server, session: http) }
        }
        reset()
    }

    private func use(_ session: Session) {
        self.session = session
        policy = NotificationPolicy(known: knownUrgent(for: session.server))
        client = FerretClient(session: session, urlSession: urlSession) { [weak self] changed in
            Task { @MainActor in self?.sessionChanged(changed) }
        }
        Task { await refresh() }
    }

    /// FerretKit refreshed the tokens (keep them) or the server ended the sign-in (nil).
    private func sessionChanged(_ changed: Session?) {
        guard let changed else {
            reset()
            message = FerretError.signedOut.localizedDescription
            return
        }
        session = changed
        store.save(changed)
    }

    private func reset() {
        store.clear()
        session = nil
        client = nil
        me = nil
        summary = nil
        attention = []
        recent = []
        places = nil
        staged = []
        thumbs = [:]
        unreachable = false
        screen = .search
        query = ""
    }

    // MARK: - Keeping up to date

    /// Who's signed in, the summary, the bell and recently viewed, together.
    func refresh() async {
        guard let client, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let me = client.me()
            async let summary = client.summary()
            async let attention = client.attention()
            async let recent = client.recentlyViewed(limit: 6)
            let (m, s, a) = try await (me, summary, attention)
            guard self.client === client else { return } // signed out meanwhile
            self.me = m
            self.summary = s
            self.attention = a
            self.recent = (try? await recent) ?? self.recent
            unreachable = false
            notifyIfNew(a)
        } catch FerretError.signedOut {
            // sessionChanged(nil) already signed out.
        } catch FerretError.offline {
            unreachable = true
        } catch {
            show(error)
        }
    }

    /// The places, for the Add screen's picker (once per sign-in, again on request).
    func loadPlaces(force: Bool = false) async {
        guard let client, force || places == nil else { return }
        do { places = try await client.places() } catch { show(error) }
    }

    private func notifyIfNew(_ items: [AttentionItem]) {
        guard let server else { return }
        let fresh = policy.newlyUrgent(in: items)
        defaults.set(Array(policy.known ?? []), forKey: "knownUrgent:\(server.absoluteString)")
        if notificationsOn { Notifier.shared.post(fresh, server: server) }
    }

    private func knownUrgent(for server: URL) -> Set<String>? {
        (defaults.array(forKey: "knownUrgent:\(server.absoluteString)") as? [String]).map(Set.init)
    }

    var notificationsOn: Bool {
        get { defaults.object(forKey: "notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifications") }
    }

    // MARK: - Doing things

    func search(_ query: String) async throws -> [Item] {
        guard let client else { return [] }
        return try await client.items(query: query, limit: 20).data
    }

    func ask(_ question: String) async throws -> AskAnswer {
        guard let client else { throw FerretError.signedOut }
        return try await client.ask(question)
    }

    /// Adds a thing, then its files one by one. Returns the thing and the files that didn't go up.
    func add(name: String, placeId: String?, quantity: Int?, files: [PickedFile]) async throws -> (Item, failed: [String]) {
        guard let client else { throw FerretError.signedOut }
        var changes = ItemChanges()
        changes.name = name
        changes.locationId = placeId
        changes.quantity = quantity.flatMap { $0 > 1 ? $0 : nil }
        let item = try await client.createItem(changes)
        let failed = await upload(files, to: item.id)
        Task { await refresh() }
        return (item, failed)
    }

    /// Adds files to a thing that's already in Ferret. Returns the names of the ones that didn't go up, with why.
    func upload(_ files: [PickedFile], to itemId: String) async -> [String] {
        guard let client else { return files.map(\.name) }
        var failed: [String] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file.url)
                _ = try await client.addFile(to: itemId, data: data, filename: file.name, contentType: file.contentType, kind: file.kind)
            } catch {
                failed.append("\(file.name): \(Self.describe(error))")
            }
        }
        return failed
    }

    func stage(_ files: [PickedFile]) {
        staged.append(contentsOf: files.filter { !staged.contains($0) })
    }

    // MARK: - Opening Ferret

    /// A route of Ferret's web app (`#/…`) in the browser, where the person's own sign-in is.
    func open(_ route: String) {
        guard let server else { return }
        NSWorkspace.shared.open(webURL(server: server, route: route))
        closeWindow()
    }

    func link(_ route: String) -> URL? {
        server.map { webURL(server: $0, route: route) }
    }

    func windowOpened() {
        focusRequest += 1
        Task { await refresh() }
    }

    // MARK: - Photos

    func thumbnail(_ photoId: String) async -> NSImage? {
        if let kept = thumbs[photoId] { return kept }
        if let pending = loadingThumbs[photoId] { return await pending.value }
        guard let client else { return nil }
        let task = Task<NSImage?, Never> {
            guard let data = try? await client.thumbnail(photoId) else { return nil }
            return NSImage(data: data)
        }
        loadingThumbs[photoId] = task
        let image = await task.value
        loadingThumbs[photoId] = nil
        if let image { thumbs[photoId] = image }
        return image
    }

    // MARK: - Messages

    func show(_ error: Error) {
        if case FerretError.cancelled = error { return }
        message = Self.describe(error)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Updates

    /// The update to offer in the window: none once "Later" was chosen for that version.
    var offeredUpdate: AvailableUpdate? {
        guard let update = updates.available, defaults.string(forKey: "updateLater") != update.version else { return nil }
        return update
    }

    func laterForUpdate() {
        defaults.set(updates.available?.version, forKey: "updateLater")
        laterTick += 1
    }

    /// Bumped so the window notices "Later" (UserDefaults isn't observed).
    private(set) var laterTick = 0

    // MARK: - Remembered per server

    var lastServer: String {
        get { defaults.string(forKey: "lastServer") ?? "" }
        set { defaults.set(newValue, forKey: "lastServer") }
    }

    func clientId(for server: URL) -> String? { defaults.string(forKey: "clientId:\(server.absoluteString)") }
    func saveClientId(_ id: String?, for server: URL) { defaults.set(id, forKey: "clientId:\(server.absoluteString)") }
}
