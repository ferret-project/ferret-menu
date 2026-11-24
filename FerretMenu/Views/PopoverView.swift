import FerretKit
import SwiftUI

/// The menu bar window: the sign-in until there is one, then search, the bell, Ask Ferret and Add.
struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.signedIn {
                MainView()
            } else {
                SignInView()
            }
        }
        .frame(width: 380, height: 520)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabBar()
            Divider()
            if let message = model.message {
                MessageBanner(text: message) { model.message = nil }
            }
            if let update = model.offeredUpdate, model.laterTick >= 0 {
                UpdateBanner(update: update)
            }
            if model.unreachable {
                MessageBanner(text: String(localized: "Can't reach the server. Showing what Ferret said last."), symbol: "wifi.slash", dismiss: nil)
            }
            Group {
                switch model.screen {
                case .search: SearchScreen()
                case .bell: BellScreen()
                case .ask: AskScreen()
                case .add: AddScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Footer()
        }
    }
}

/// The screens as icons along the top, and the More menu.
private struct TabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            tab(.search, "magnifyingglass", "Search")
            tab(.bell, "bell", "Needs attention", count: model.urgentCount)
            if model.canAsk { tab(.ask, "sparkles", "Ask Ferret") }
            if model.canEdit { tab(.add, "plus", "Add a thing") }
            Spacer()
            Menu {
                Button("Open Ferret") { model.open("#/") }
                Button("Refresh") { Task { await model.refresh() } }
                Divider()
                Button("Settings…") { model.openSettings() }
                Button("Quit Ferret Menu") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("More"))
            .accessibilityLabel(Text("More"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tab(_ screen: Screen, _ symbol: String, _ label: LocalizedStringKey, count: Int = 0) -> some View {
        let current = model.screen == screen
        return Button {
            model.screen = screen
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).fontWeight(current ? .semibold : .regular)
                if count > 0 {
                    Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).background(Capsule().fill(.red))
                }
            }
            .frame(minWidth: 32, minHeight: 26)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityValue(count > 0 ? Text("\(count) urgent") : Text(""))
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// The household at a glance, along the bottom.
private struct Footer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Paw.image).renderingMode(.template).foregroundStyle(.secondary)
            if let summary = model.summary {
                Text(model.householdName ?? summary.household).fontWeight(.medium).lineLimit(1)
                Text(verbatim: "·").foregroundStyle(.secondary)
                Text("\(summary.things) things").foregroundStyle(.secondary).lineLimit(1)
                if summary.valueCents > 0 {
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Text(money(summary.valueCents, currency: summary.currency)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(model.server?.host() ?? "").foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

/// An amount in the household's currency, whole units (the footer has no room for cents).
func money(_ cents: Int, currency: String) -> String {
    (Double(cents) / 100).formatted(.currency(code: currency).precision(.fractionLength(0)))
}

struct MessageBanner: View {
    let text: String
    var symbol = "exclamationmark.circle"
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text("Dismiss"))
                    .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

/// A newer Ferret Menu is out: download it from its release page, or not now (until the next one).
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    let update: AvailableUpdate

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
            Text("Ferret Menu \(update.version) is available.").font(.callout)
            Spacer(minLength: 0)
            Button("Later") { model.laterForUpdate() }
                .buttonStyle(.link)
                .font(.callout)
            Button("Download") {
                NSWorkspace.shared.open(update.page)
                model.closeWindow()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
    }
}
