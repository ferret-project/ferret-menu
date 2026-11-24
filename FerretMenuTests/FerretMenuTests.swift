import AppKit
import Carbon.HIToolbox
import FerretKit
import Foundation
import Testing
@testable import Ferret_Menu

private func bell(_ id: String, urgent: Bool, kind: String = "warranty") -> AttentionItem {
    AttentionItem(kind: kind, severity: urgent ? "urgent" : "soon", id: id, title: "T \(id)", detail: "", itemId: id)
}

@Suite struct NotificationPolicyTests {
    @Test func firstLookTellsNothing() {
        var policy = NotificationPolicy(known: nil)
        #expect(policy.newlyUrgent(in: [bell("a", urgent: true)]).isEmpty)
        #expect(policy.known == ["warranty:a"])
    }

    @Test func tellsOnlyWhatJustBecameUrgent() {
        var policy = NotificationPolicy(known: ["warranty:a"])
        let fresh = policy.newlyUrgent(in: [bell("a", urgent: true), bell("b", urgent: true), bell("c", urgent: false)])
        #expect(fresh.map(\.id) == ["b"])
        #expect(policy.newlyUrgent(in: [bell("a", urgent: true), bell("b", urgent: true)]).isEmpty)
    }

    @Test func oneThatComesBackIsToldAgain() {
        var policy = NotificationPolicy(known: ["warranty:a"])
        _ = policy.newlyUrgent(in: [])
        #expect(policy.newlyUrgent(in: [bell("a", urgent: true)]).map(\.id) == ["a"])
    }

    @Test func sameIdDifferentKindIsDifferent() {
        var policy = NotificationPolicy(known: ["warranty:a"])
        #expect(policy.newlyUrgent(in: [bell("a", urgent: true, kind: "maintenance")]).count == 1)
    }
}

@Suite struct ShortcutTests {
    @Test func showsModifiersInMenuOrder() {
        #expect(Shortcut.standard.display == "⌃⌥⌘F")
        let s = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), key: "Space")
        #expect(s.display == "⇧⌘Space")
    }

    @Test func convertsModifierFlags() {
        #expect(Shortcut.carbon([.command, .option]) == UInt32(cmdKey | optionKey))
        #expect(Shortcut.carbon([.control, .shift]) == UInt32(controlKey | shiftKey))
    }

    @Test func needsACommandOptionOrControl() throws {
        let plain = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil, characters: "F", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)))
        #expect(Shortcut(event: plain) == nil)
        let good = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "ƒ", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)))
        #expect(Shortcut(event: good)?.display == "⌥⌘F")
    }
}

@Suite struct PickedFileTests {
    @Test func photosAndDocuments() {
        #expect(PickedFile(url: URL(fileURLWithPath: "/tmp/a.HEIC")).kind == "photo")
        #expect(PickedFile(url: URL(fileURLWithPath: "/tmp/a.jpg")).contentType == "image/jpeg")
        #expect(PickedFile(url: URL(fileURLWithPath: "/tmp/receipt.pdf")).kind == "document")
        #expect(PickedFile(url: URL(fileURLWithPath: "/tmp/receipt.pdf")).contentType == "application/pdf")
        #expect(PickedFile(url: URL(fileURLWithPath: "/tmp/noext")).contentType == "application/octet-stream")
    }

    @Test func leavesOutFoldersAndMissingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "picked-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "a.txt")
        try Data("x".utf8).write(to: file)
        let picked = PickedFile.from([folder, file, folder.appending(path: "gone.png"), URL(string: "https://example.com/a.png")!])
        #expect(picked.map(\.name) == ["a.txt"])
    }
}

@Suite struct PlaceFilterTests {
    let places: [(place: Place, depth: Int)] = {
        let json = Data("""
        {"properties":[{"id":"p","name":"Home","locations":[
          {"id":"g","name":"Garage","path":"Home › Garage","children":[{"id":"s","name":"Top shelf","path":"Home › Garage › Top shelf"}]},
          {"id":"k","name":"Kitchen","path":"Home › Kitchen"}
        ]}]}
        """.utf8)
        return try! JSONDecoder().decode(PlaceTree.self, from: json).flattened
    }()

    @Test func everyWordOfThePath() {
        #expect(PlaceFilter.matches(places, "").count == 3)
        #expect(PlaceFilter.matches(places, "garage shelf").map(\.place.id) == ["s"])
        #expect(PlaceFilter.matches(places, "KITCH").map(\.place.id) == ["k"])
        #expect(PlaceFilter.matches(places, "attic").isEmpty)
    }
}

// MARK: - The model against a pretend server

/// Answers requests from a table (path → status and body), and records what was asked.
final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var seen: [(method: String, path: String, body: Data?)] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        let key = "\(request.httpMethod ?? "GET") \(path)"
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let (status, text) = StubServer.lock.withLock {
            StubServer.seen.append((request.httpMethod ?? "GET", path, body))
            return StubServer.routes[key] ?? (404, #"{"error":{"code":"not_found","message":"Not found"}}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MemoryStore: SessionKeeping, @unchecked Sendable {
    var session: Session?
    init(_ session: Session?) { self.session = session }
    func load() -> Session? { session }
    func exists() -> Bool { session != nil }
    func save(_ session: Session) { self.session = session }
    func clear() { session = nil }
}

@MainActor
@Suite(.serialized) struct AppModelTests {
    let server = URL(string: "http://ferret.test")!

    init() {
        StubServer.routes = [
            "GET /api/v1/me": (200, #"{"user":{"id":"u","name":"Sam","email":"sam@example.com"},"activeHouseholdId":"h","household":{"id":"h","name":"Home","role":"member","readOnly":false},"features":{"textAi":true}}"#),
            "GET /api/v1/summary": (200, #"{"household":"Home","things":12,"valueCents":123400,"currency":"USD","needsAttention":2,"urgent":1,"toBuy":0}"#),
            "GET /api/v1/attention": (200, #"{"data":[{"kind":"warranty","severity":"urgent","id":"w","title":"Fridge warranty ends","detail":"tomorrow","itemId":"i1","date":null},{"kind":"maintenance","severity":"soon","id":"t","title":"Gutters","detail":"","itemId":null,"date":null}]}"#),
            "GET /api/v1/recently-viewed": (200, #"{"data":[{"id":"i1","name":"Fridge","place":"Home › Kitchen"}]}"#),
            "POST /api/v1/items": (201, #"{"id":"new","name":"Drill"}"#),
            "POST /api/v1/items/new/attachments": (201, #"{"id":"a","itemId":"new","kind":"photo","filename":"drill.jpg"}"#),
        ]
        StubServer.seen = []
    }

    /// An app sign-in, good for an hour (no refresh unless the server turns the token away).
    private var tokens: OAuthTokens {
        OAuthTokens(accessToken: "ferret_at_test", refreshToken: "ferret_rt_test", expiresAt: Date().addingTimeInterval(3600), clientId: "c", tokenEndpoint: URL(string: "http://ferret.test/api/auth/oauth2/token")!, resource: "http://ferret.test/mcp")
    }

    private func model() -> (AppModel, MemoryStore, UserDefaults) {
        let store = MemoryStore(Session(server: server, credential: .oauth(tokens)))
        let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
        defaults.set(false, forKey: "notifications")
        return (AppModel(store: store, defaults: defaults, urlSession: StubServer.session()), store, defaults)
    }

    private func settle(_ model: AppModel) async {
        // The kept sign-in is read in the background first.
        for _ in 0 ..< 200 where !model.signedIn && model.message == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0 ..< 200 where model.loading || model.summary == nil && model.message == nil && model.signedIn {
            try? await Task.sleep(for: .milliseconds(10))
        }
        while model.loading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func refreshFillsTheGlance() async {
        let (model, _, defaults) = model()
        model.start()
        await settle(model)
        #expect(model.householdName == "Home")
        #expect(model.summary?.things == 12)
        #expect(model.urgentCount == 1)
        #expect(model.recent.map(\.name) == ["Fridge"])
        #expect(model.canEdit)
        #expect(model.canAsk)
        // The first look remembers what's urgent without telling.
        #expect(defaults.stringArray(forKey: "knownUrgent:http://ferret.test") == ["warranty:w"])
    }

    @Test func viewersCantAdd() async {
        StubServer.routes["GET /api/v1/me"] = (200, #"{"user":{"id":"u","name":"Sam","email":"s@example.com"},"activeHouseholdId":"h","household":{"id":"h","name":"Home","role":"viewer","readOnly":true}}"#)
        let (model, _, _) = model()
        model.start()
        await settle(model)
        #expect(!model.canEdit)
        #expect(!model.canAsk)
    }

    @Test func aDisconnectedAppSignsOut() async {
        // Disconnected in Ferret's Settings: the token is turned away and so is the refresh.
        StubServer.routes["POST /api/auth/oauth2/token"] = (400, #"{"error":"invalid_grant"}"#)
        StubServer.routes["GET /api/v1/me"] = (401, #"{"error":{"code":"unauthorized","message":"Sign in first"}}"#)
        StubServer.routes["GET /api/v1/summary"] = (401, #"{"error":{"code":"unauthorized","message":"Sign in first"}}"#)
        StubServer.routes["GET /api/v1/attention"] = (401, #"{"error":{"code":"unauthorized","message":"Sign in first"}}"#)
        let (model, store, _) = model()
        model.start()
        await settle(model)
        #expect(!model.signedIn)
        #expect(store.session == nil)
        #expect(model.message == FerretError.signedOut.localizedDescription)
        #expect(StubServer.seen.contains { $0.path == "/api/auth/oauth2/token" })
    }

    @Test func addsAThingWithItsFiles() async throws {
        let (model, _, _) = model()
        model.start()
        await settle(model)
        let file = FileManager.default.temporaryDirectory.appending(path: "drill-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (item, failed) = try await model.add(name: "Drill", placeId: "g", quantity: 2, files: [PickedFile(url: file)])
        #expect(item.id == "new")
        #expect(failed.isEmpty)
        let created = try #require(StubServer.seen.first { $0.method == "POST" && $0.path == "/api/v1/items" })
        let sent = try JSONSerialization.jsonObject(with: created.body ?? Data()) as? [String: Any]
        #expect(sent?["name"] as? String == "Drill")
        #expect(sent?["locationId"] as? String == "g")
        #expect(sent?["quantity"] as? Int == 2)
        let upload = try #require(StubServer.seen.first { $0.path == "/api/v1/items/new/attachments" })
        let form = String(decoding: upload.body ?? Data(), as: UTF8.self)
        #expect(form.contains("name=\"kind\"\r\n\r\nphoto"))
        #expect(form.contains("Content-Type: image/jpeg"))
    }

    @Test func aFileThatFailsIsReported() async throws {
        StubServer.routes["POST /api/v1/items/new/attachments"] = (415, #"{"error":{"code":"unsupported","message":"Ferret can't keep that kind of file"}}"#)
        let (model, _, _) = model()
        model.start()
        await settle(model)
        let file = FileManager.default.temporaryDirectory.appending(path: "x-\(UUID().uuidString).exe")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let failed = await model.upload([PickedFile(url: file)], to: "new")
        #expect(failed.count == 1)
        #expect(failed[0].contains("Ferret can't keep that kind of file"))
    }

    @Test func doneLeavesTheBellAndSaysWhatWasDone() async throws {
        StubServer.routes["POST /api/v1/maintenance/t/done"] = (200, #"{"id":"t","title":"Gutters","doneId":"d"}"#)
        let (model, _, _) = model()
        model.start()
        await settle(model)
        let gutters = try #require(model.attention.first { $0.kind == "maintenance" })
        // The bell read again after this one still lists it until the server says otherwise; here it's gone.
        StubServer.routes["GET /api/v1/attention"] = (200, #"{"data":[{"kind":"warranty","severity":"urgent","id":"w","title":"Fridge warranty ends","detail":"tomorrow","itemId":"i1","date":null}]}"#)
        try await model.markDone(gutters, MaintenanceDone(note: "Cleared", costCents: 4000))
        #expect(!model.attention.contains { $0.key == gutters.key })
        let sent = try #require(StubServer.seen.first { $0.path == "/api/v1/maintenance/t/done" })
        let body = try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any]
        #expect(body?["note"] as? String == "Cleared")
        #expect(body?["costCents"] as? Int == 4000)
        #expect(body?["doneOn"] == nil)
    }

    @Test func aLoanIsMarkedReturned() async throws {
        StubServer.routes["GET /api/v1/attention"] = (200, #"{"data":[{"kind":"loan","severity":"urgent","id":"l1","title":"Give the ladder back to Pat","detail":"Due today","itemId":"i9","date":null}]}"#)
        StubServer.routes["POST /api/v1/loans/l1/returned"] = (200, #"{"id":"l1"}"#)
        let (model, _, _) = model()
        model.start()
        await settle(model)
        let loan = try #require(model.attention.first)
        try await model.markReturned(loan)
        #expect(model.attention.isEmpty)
        #expect(StubServer.seen.contains { $0.method == "POST" && $0.path == "/api/v1/loans/l1/returned" })
    }

    @Test func boughtRaisesTheCountAndCanBeUndone() async throws {
        StubServer.routes["GET /api/v1/shopping"] = (200, #"{"items":[{"id":"f","name":"Furnace filter","place":"Garage","quantity":0,"minQuantity":2,"buy":3,"forTask":null,"photoId":null}],"text":"Furnace filter ×3"}"#)
        StubServer.routes["POST /api/v1/items/f/stock"] = (200, #"{"quantity":3,"applied":3,"movementId":"m1"}"#)
        StubServer.routes["POST /api/v1/stock/movements/m1/undo"] = (200, #"{"itemId":"f","quantity":0,"applied":-3,"movementId":"m2"}"#)
        let (model, _, _) = model()
        model.start()
        await settle(model)
        await model.loadShopping()
        #expect(model.showsShopping)
        let filter = try #require(model.shopping?.items.first)
        try await model.bought(filter, count: filter.buy)
        let sent = try #require(StubServer.seen.first { $0.path == "/api/v1/items/f/stock" })
        #expect((try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])?["delta"] as? Int == 3)
        #expect(model.lastBought == AppModel.Bought(name: "Furnace filter", count: 3, movementId: "m1"))
        await model.undoBought()
        #expect(model.lastBought == nil)
        #expect(StubServer.seen.contains { $0.path == "/api/v1/stock/movements/m1/undo" })
    }

    @Test func noShoppingTabWithNothingToBuy() async {
        let (model, _, _) = model()
        model.start()
        await settle(model)
        #expect(!model.showsShopping)
    }

    @Test func signingOutForgetsAndRevokes() async throws {
        let (model, store, _) = model()
        model.start()
        await settle(model)
        StubServer.routes["GET /.well-known/oauth-authorization-server"] = (200, #"{"revocation_endpoint":"http://ferret.test/api/auth/oauth2/revoke"}"#)
        StubServer.routes["POST /api/auth/oauth2/revoke"] = (200, "{}")
        model.signOut()
        #expect(!model.signedIn)
        #expect(store.session == nil)
        #expect(model.attention.isEmpty)
        // The server forgets the refresh token too.
        for _ in 0 ..< 100 where !StubServer.seen.contains(where: { $0.path == "/api/auth/oauth2/revoke" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let revoke = try #require(StubServer.seen.first { $0.path == "/api/auth/oauth2/revoke" })
        #expect(String(decoding: revoke.body ?? Data(), as: UTF8.self).contains("token=ferret_rt_test"))
    }
}

@Suite struct NotificationClickTests {
    @Test func severalOpenTheBellOneOpensItsPlace() {
        #expect(Notifier.target(of: ["bell": true]) == .bell)
        #expect(Notifier.target(of: ["url": "http://ferret.test/#/items/i1"]) == .web(URL(string: "http://ferret.test/#/items/i1")!))
        #expect(Notifier.target(of: [:]) == nil)
    }
}

@Suite struct DoneFormTests {
    @Test func readsTypedNumbersAndDays() {
        #expect(DoneForm.parse("41,250 mi") == 41250)
        #expect(DoneForm.parse("12.5") == 12.5)
        #expect(DoneForm.parse("none") == nil)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        #expect(DoneForm.isoDay(day) == "2026-03-07")
    }
}

@Suite struct UpdateSettingsTests {
    /// The app reads updates only from the release feed, signed with the release key, through Sparkle's sandbox
    /// installer.
    @Test func infoPlistPointsSparkleAtTheReleases() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://github.com/ferret-project/ferret-menu/releases/latest/download/appcast.xml")
        #expect((info["SUPublicEDKey"] as? String)?.count == 44)
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["CFBundleVersion"] as? String == info["CFBundleShortVersionString"] as? String)
    }
}
