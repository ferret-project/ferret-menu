import AuthenticationServices
import FerretKit
import SwiftUI

/// "Sign in to Ferret": the server's address, then Ferret's own sign-in page in a browser window, where the person
/// picks the household and whether the app may change things. The only way in: the app never sees the password and
/// takes no API keys, so each Mac is its own connected app that can be disconnected in Ferret.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var address = ""
    @State private var working = false
    @State private var error: String?
    @State private var advanced = false
    @State private var accessId = ""
    @State private var accessSecret = ""

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
            Text("Sign in to Ferret").font(.title2.weight(.semibold))
            Text("Find anything you own from the menu bar.").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server").font(.caption).foregroundStyle(.secondary)
                TextField(ServerAddress.hosted.host() ?? "", text: $address, prompt: Text(verbatim: "ferret.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(signIn)
                Text("Your own Ferret's address, or leave it empty for the hosted Ferret.").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Cloudflare Access", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A service token, if your server sits behind Cloudflare Access").font(.caption).foregroundStyle(.secondary)
                    TextField(text: $accessId, prompt: Text("Client ID")) { Text("Client ID") }
                        .textFieldStyle(.roundedBorder)
                    SecureField(text: $accessSecret, prompt: Text("Client secret")) { Text("Client secret") }
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).textSelection(.enabled)
            } else if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            Button(action: signIn) {
                if working { ProgressView().controlSize(.small).frame(maxWidth: .infinity) } else { Text("Sign In").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(working)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(20)
        .onAppear {
            address = model.lastServer
            if let server = ServerAddress.parse(address), let kept = AccessTokenStore(service: AppModel.keychainService).load(for: server) {
                accessId = kept.clientId
                accessSecret = kept.clientSecret
            }
        }
    }

    private func signIn() {
        guard !working else { return }
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = typed.isEmpty ? ServerAddress.hosted : ServerAddress.parse(typed) else {
            error = String(localized: "That doesn't look like a server address.")
            return
        }
        let access = AccessToken(clientId: accessId, clientSecret: accessSecret)
        let accessToken = access.isComplete ? access : nil
        error = nil
        working = true
        model.holdOpen = true
        Task {
            defer {
                working = false
                model.holdOpen = false
            }
            do {
                let tokens = try await authorize(server, clientId: model.clientId(for: server), access: accessToken)
                let session = Session(server: server, credential: .oauth(tokens), access: accessToken)
                AccessTokenStore(service: AppModel.keychainService).save(accessToken, for: server)
                model.lastServer = typed
                model.signedIn(session)
                model.showWindow()
            } catch FerretError.cancelled {
                // Closed the sign-in window or pressed Cancel: nothing to say.
            } catch let failure as FerretError {
                error = failure.localizedDescription
                if failure == .accessBlocked { advanced = true }
            } catch {
                self.error = AppModel.describe(error)
            }
        }
    }

    /// Registers once per server; a registration the server no longer knows (its database was reset) is made again.
    private func authorize(_ server: URL, clientId: String?, access: AccessToken?) async throws -> OAuthTokens {
        let session = URLSession.ferret(access: access)
        let start = try await OAuth.start(server: server, clientName: Self.clientName, redirectURI: AppModel.redirectURI, knownClientId: clientId, session: session)
        model.saveClientId(start.clientId, for: server)
        let callback: URL
        do {
            callback = try await webAuthenticationSession.authenticate(
                using: start.url,
                callback: .customScheme(AppModel.callbackScheme),
                preferredBrowserSession: .shared,
                // The first page load carries the Access headers; Access's CF_Authorization cookie carries the rest.
                additionalHeaderFields: access?.headers ?? [:]
            )
        } catch ASWebAuthenticationSessionError.canceledLogin {
            throw FerretError.cancelled
        }
        do {
            return try await OAuth.finish(start, callback: callback, session: session)
        } catch FerretError.server(_, let message) where clientId != nil && message.localizedCaseInsensitiveContains("client") {
            model.saveClientId(nil, for: server)
            return try await authorize(server, clientId: nil, access: access)
        }
    }

    /// How the app shows on Ferret's Connect screen and in Settings → Connected apps: "Ferret Menu on Sam's MacBook".
    static var clientName: String {
        let computer = Host.current().localizedName ?? ""
        return computer.isEmpty ? String(localized: "Ferret Menu") : String(localized: "Ferret Menu on \(computer)")
    }
}
