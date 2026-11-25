import FerretKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var atLogin = Preferences.opensAtLogin
    @State private var loginError: String?
    @State private var notifications = true
    @State private var permission: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $atLogin)
                    .onChange(of: atLogin) { _, on in
                        do {
                            try Preferences.setOpensAtLogin(on)
                            loginError = nil
                        } catch {
                            loginError = AppModel.describe(error)
                            atLogin = Preferences.opensAtLogin
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Open the Ferret window") {
                    ShortcutRecorder()
                }
            }
            Section {
                Toggle("Notify me when something becomes urgent", isOn: $notifications)
                    .onChange(of: notifications) { _, on in
                        model.notificationsOn = on
                        if on { Task { await Notifier.shared.requestPermission(); permission = await Notifier.shared.status() } }
                    }
                if notifications, permission == .denied {
                    HStack {
                        Text("Notifications are off for Ferret Menu in System Settings.").font(.caption).foregroundStyle(.secondary)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
                Text("Warranties ending, maintenance due, recalls and the rest of Ferret's bell. The paw shows how many are urgent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            WebAppSettings()
            if let updates = model.updates { UpdateSettings(updates: updates) }
        }
        .formStyle(.grouped)
        .task {
            notifications = model.notificationsOn
            if notifications { await Notifier.shared.requestPermission() }
            permission = await Notifier.shared.status()
            atLogin = Preferences.opensAtLogin
        }
    }
}

/// Click, then press the new shortcut; Delete switches it off, Escape keeps the old one.
private struct ShortcutRecorder: View {
    @State private var shortcut = Preferences.shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refused = false

    var body: some View {
        HStack {
            Button {
                recording ? stop() : record()
            } label: {
                Text(recording ? String(localized: "Press a shortcut…") : (shortcut?.display ?? String(localized: "None")))
                    .frame(minWidth: 110)
            }
            .accessibilityHint(Text("Press to record a new shortcut"))
            if refused {
                Text("Taken by another app").font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        recording = true
        HotKey.shared.register(nil) // so pressing the current one is recorded, not acted on
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Escape
                stop()
            case 51, 117: // Delete, Forward Delete
                save(nil)
            default:
                guard let new = Shortcut(event: event) else { NSSound.beep(); return nil }
                save(new)
            }
            return nil
        }
    }

    private func save(_ new: Shortcut?) {
        shortcut = new
        Preferences.shortcut = new
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        refused = !HotKey.shared.register(Preferences.shortcut)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        Form {
            if let server = model.server {
                Section {
                    LabeledContent("Server", value: server.absoluteString)
                    if let me = model.me {
                        LabeledContent("Signed in as", value: me.user.name.isEmpty ? me.user.email : "\(me.user.name) (\(me.user.email))")
                    }
                    if let household = model.householdName {
                        LabeledContent("Household", value: household)
                    }
                    LabeledContent("Can change things", value: model.canEdit ? String(localized: "Yes") : String(localized: "No, look only"))
                }
                Section {
                    HStack {
                        Button("Connected Apps in Ferret…") { model.open("#/settings/api") }
                        Spacer()
                        Button("Sign Out…", role: .destructive) { confirming = true }
                    }
                    Text("Signing out ends this Mac's sign-in on the server too. You can also disconnect it from Ferret's Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not signed in. Click the paw in the menu bar to sign in.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out of Ferret?", isPresented: $confirming) {
            Button("Sign Out", role: .destructive) {
                model.signOut()
                model.showWindow()
            }
        } message: {
            Text("You'll need to sign in again to use Ferret Menu.")
        }
    }
}

private struct UpdateSettings: View {
    let updates: Updates
    @State private var automatic = true
    @State private var byItself = false

    var body: some View {
        Section {
            Toggle("Check for updates once a day", isOn: $automatic)
                .onChange(of: automatic) { _, on in updates.automatic = on }
            Toggle("Install updates automatically", isOn: $byItself)
                .onChange(of: byItself) { _, on in updates.downloadsByItself = on }
                .disabled(!automatic)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(Updates.version)")
                    if let version = updates.available {
                        Text("Version \(version) is available.").font(.caption).foregroundStyle(Color.accentColor)
                    } else if let when = updates.lastChecked {
                        Text("Checked \(when.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check Now") { updates.checkNow() }
            }
            Text("Automatic updates download in the background and install the next time Ferret Menu quits or your Mac restarts. Updates come from Ferret Menu's GitHub releases and install only when they're signed by Ferret.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            automatic = updates.automatic
            byItself = updates.downloadsByItself
        }
    }
}

/// Where things open: the browser, or Ferret installed as a web app (Chrome, Edge or Brave).
private struct WebAppSettings: View {
    @Environment(AppModel.self) private var model
    @State private var refused: String?
    /// Bumped to look again whether the web app takes links (after opening it).
    @State private var looked = 0

    var body: some View {
        Section {
            LabeledContent("Open things in") {
                Text(model.webApp.map { String(localized: "\($0.name) (web app)") } ?? String(localized: "Your browser"))
            }
            HStack {
                Button("Choose Web App…", action: choose)
                if model.webApp != nil {
                    Button("Use the Browser") { model.webApp = nil; refused = nil }
                }
                Spacer()
                if model.webApp != nil {
                    Button("Check Again") { looked += 1 }.buttonStyle(.link)
                }
            }
            if let refused {
                Text(refused).font(.caption).foregroundStyle(.red)
            } else if let app = model.webApp {
                Text(status(app)).font(.caption).foregroundStyle(.secondary).id(looked)
            }
            Text("Ferret installed as an app with Chrome, Edge or Brave (Install Ferret in the browser's menu). Safari's web apps can't open pages for other apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func status(_ app: WebApp) -> String {
        if let server = model.server, !app.isFor(server) {
            return String(localized: "This web app is for \(app.host), but Ferret Menu is signed in to \(server.host() ?? ""). Things open in your browser.")
        }
        if !app.handlesLinks {
            return String(localized: "Not ready yet: open the web app once so it learns to open pages for Ferret Menu (it needs Ferret 2026.11.28 or newer), and allow it if the browser asks. Until then, things open in your browser.")
        }
        return String(localized: "Things open in the web app.")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Applications", isDirectory: true)
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose Ferret's web app (in Applications, or Chrome Apps in your home folder's Applications).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let app = WebApp.read(url) else {
            refused = String(localized: "That isn't a web app installed with Chrome, Edge or Brave.")
            return
        }
        refused = nil
        model.webApp = app
    }
}
