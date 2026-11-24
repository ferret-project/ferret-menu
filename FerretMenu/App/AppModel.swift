import AppKit
import FerretKit
import Observation

/// Where the sign-in is kept: the Keychain, or a stand-in for tests.
typealias SessionKeeping = SessionKeeper

/// The menu bar window's screens.
enum Screen: Hashable {
    case search, bell, shopping, ask, add
}

/// Everything the menu bar app knows: the sign-in, the household at a glance, the bell, and what's being added.
/// The views read it; the menu bar controller watches `urgentCount` for the badge.
@MainActor
@Observable
final class AppModel {
    static let keychainService = "us.digitalempire.ferret.menu"
    /// Where the sign-in is kept. Debug builds can be pointed elsewhere (FERRET_MENU_KEYCHAIN_SERVICE), so trying a
    /// build never touches the real sign-in.
    static var sessionService: String {
        #if DEBUG
        if let other = ProcessInfo.processInfo.environment["FERRET_MENU_KEYCHAIN_SERVICE"] { return other }
        #endif
        return keychainService
    }
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
    /// The shopping list (loaded when its screen opens).
    private(set) var shopping: ShoppingList?
    /// The last "Bought": what, how many, and the change to undo.
    private(set) var lastBought: Bought?
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
    /// The bell row whose Done or Returned form is open (its `key`; one at a time).
    var dealing: String?
    /// Bumped to put the cursor in the search box (each time the window opens).
    private(set) var focusRequest = 0
    /// While true the window stays open when another window takes focus (the sign-in browser, a file panel).
    var holdOpen = false

    /// Set by the menu bar controller.
    var closeWindow: () -> Void = {}
    var showWindow: () -> Void = {}
    var openSettings: () -> Void = {}

    let defaults: UserDefaults
    /// Sparkle's updater (set at launch; none in unit tests).
    var updates: Updates?
    private let store: SessionKeeping
    private let urlSession: URLSession?
    private var thumbs: [String: NSImage] = [:]
    private var loadingThumbs: [String: Task<NSImage?, Never>] = [:]
    private var ticker: Task<Void, Never>?
    private var policy: NotificationPolicy

    init(store: SessionKeeping = SessionStore(service: AppModel.sessionService), defaults: UserDefaults = .standard, urlSession: URLSession? = nil) {
        self.store = store
        self.defaults = defaults
        self.urlSession = urlSession
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
    /// The shopping list's tab shows while there's something to buy (and while it's open).
    var showsShopping: Bool { (summary?.toBuy ?? 0) > 0 || shopping?.items.isEmpty == false || screen == .shopping }

    struct Bought: Equatable {
        let name: String
        let count: Int
        let movementId: String
    }

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
        message = nil
        use(session)
        keep(session)
    }

    /// Keeps the sign-in for the next launch; says so when the Keychain won't (it still works until then).
    private func keep(_ session: Session) {
        do { try store.save(session) } catch { show(error) }
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
        // The client keeps refreshed tokens in the store itself, at once, and reads it before refreshing.
        client = FerretClient(session: session, store: store, urlSession: urlSession, onKeepFailed: { [weak self] error in
            Task { @MainActor in self?.show(error) }
        }) { [weak self] changed in
            Task { @MainActor in self?.sessionChanged(changed) }
        }
        Task { await refresh() }
    }

    /// FerretKit refreshed the tokens (already kept) or the server ended the sign-in (nil).
    private func sessionChanged(_ changed: Session?) {
        guard let changed else {
            reset()
            message = FerretError.signedOut.localizedDescription
            return
        }
        session = changed
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
        shopping = nil
        lastBought = nil
        dealing = nil
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
                // Streamed from the file, never read into memory whole.
                _ = try await client.addFile(to: itemId, fileAt: file.url, filename: file.name, contentType: file.contentType, kind: file.kind)
            } catch {
                failed.append("\(file.name): \(Self.describe(error))")
            }
        }
        return failed
    }

    func stage(_ files: [PickedFile]) {
        staged.append(contentsOf: files.filter { !staged.contains($0) })
    }

    // MARK: - Dealing with the bell

    /// A task's details for marking it done (whether it's due by use, and the last reading).
    func task(_ id: String) async throws -> MaintenanceTask {
        guard let client else { throw FerretError.signedOut }
        return try await client.maintenanceTask(id)
    }

    /// Marks a bell item's maintenance task done; it leaves the bell at once, then the bell is read again.
    func markDone(_ item: AttentionItem, _ done: MaintenanceDone) async throws {
        guard let client else { throw FerretError.signedOut }
        try await client.markDone(item.id, done)
        dealtWith(item)
    }

    /// Marks a bell item's loan returned (lent and back, or borrowed and given back).
    func markReturned(_ item: AttentionItem) async throws {
        guard let client else { throw FerretError.signedOut }
        try await client.markReturned(item.id)
        dealtWith(item)
    }

    private func dealtWith(_ item: AttentionItem) {
        attention.removeAll { $0.key == item.key }
        Task { await refreshSoon() }
    }

    /// A refresh after a change, waiting for one already under way (which may have read the bell before it).
    private func refreshSoon() async {
        while loading { try? await Task.sleep(for: .milliseconds(50)) }
        await refresh()
    }

    // MARK: - Shopping

    func loadShopping() async {
        guard let client else { return }
        do { shopping = try await client.shopping() } catch { show(error) }
    }

    /// Bought some: the thing's count goes up by that many (and it leaves the list once there are enough).
    func bought(_ entry: ShoppingList.Entry, count: Int) async throws {
        guard let client, count > 0 else { return }
        let change = try await client.adjustStock(entry.id, by: count)
        lastBought = change.movementId.map { Bought(name: entry.name, count: count, movementId: $0) }
        await loadShopping()
        Task { await refreshSoon() }
    }

    func undoBought() async {
        guard let client, let last = lastBought else { return }
        lastBought = nil
        do {
            _ = try await client.undoStock(last.movementId)
        } catch {
            show(error)
        }
        await loadShopping()
        Task { await refreshSoon() }
    }

    func forgetBought() { lastBought = nil }

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

    // MARK: - Remembered per server

    var lastServer: String {
        get { defaults.string(forKey: "lastServer") ?? "" }
        set { defaults.set(newValue, forKey: "lastServer") }
    }

    func clientId(for server: URL) -> String? { defaults.string(forKey: "clientId:\(server.absoluteString)") }
    func saveClientId(_ id: String?, for server: URL) { defaults.set(id, forKey: "clientId:\(server.absoluteString)") }
}
