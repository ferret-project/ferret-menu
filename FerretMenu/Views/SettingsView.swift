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
            UpdateSettings(updates: model.updates)
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
    @Bindable var updates: Updates

    var body: some View {
        Section {
            Toggle("Check for updates once a day", isOn: $updates.automatic)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(Version.running.description)")
                    if let update = updates.available {
                        Text("Version \(update.version) is available.").font(.caption).foregroundStyle(Color.accentColor)
                    } else if let result = updates.lastResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    } else if let when = updates.lastChecked {
                        Text("Checked \(when.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let update = updates.available {
                    Button("Download") { NSWorkspace.shared.open(update.page) }
                } else {
                    Button {
                        Task { await updates.check() }
                    } label: {
                        if updates.checking { ProgressView().controlSize(.small) } else { Text("Check Now") }
                    }
                    .disabled(updates.checking)
                }
            }
            Text("Asks GitHub for the latest release; nothing about you or your Ferret is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
