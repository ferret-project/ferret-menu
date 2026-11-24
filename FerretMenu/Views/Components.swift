import AppKit
import FerretKit
import SwiftUI

/// A thing's main photo, small; a box glyph when it has none.
struct Thumbnail: View {
    @Environment(AppModel.self) private var model
    let photoId: String?
    var size: CGFloat = 36
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
        .task(id: photoId) {
            image = nil
            if let photoId { image = await model.thumbnail(photoId) }
        }
    }
}

/// A thing in a list: photo, name, where it is. Click opens it in Ferret; files dropped on it are added to it.
struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: Item
    var selected = false
    @State private var hovering = false
    @State private var dropping = false
    @State private var uploading = false

    var body: some View {
        Button {
            model.open(itemRoute(item.id))
        } label: {
            HStack(spacing: 10) {
                Thumbnail(photoId: item.photoId)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    if let line = detail {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if uploading { ProgressView().controlSize(.small) }
                if item.disposition != nil {
                    Text("Gone").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(highlight))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.place.map { String(localized: "In \($0)") } ?? item.name)
        .contextMenu {
            Button("Open in Ferret") { model.open(itemRoute(item.id)) }
            if let place = item.place {
                Button("Copy Where It Is") { copy(place) }
            }
            if let link = model.link(itemRoute(item.id)) {
                Button("Copy Link") { copy(link.absoluteString) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = PickedFile.from(urls)
            guard model.canEdit, !files.isEmpty else { return false }
            uploading = true
            Task {
                let failed = await model.upload(files, to: item.id)
                uploading = false
                if !failed.isEmpty { model.message = failed.joined(separator: "\n") }
            }
            return true
        } isTargeted: { dropping = $0 && model.canEdit }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens it in Ferret"))
    }

    private var detail: String? {
        [item.place, item.subtitle].compactMap { $0 }.first
    }

    private var highlight: Color {
        if dropping { return Color.accentColor.opacity(0.25) }
        if selected || hovering { return Color.primary.opacity(0.08) }
        return .clear
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Something on the bell: what, when, and how pressing it is.
struct BellRow: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem
    @State private var hovering = false

    var body: some View {
        Button {
            model.open(item.route)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(item.kind))
                    .foregroundStyle(item.isUrgent ? Color.red : Color.orange)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(2)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.isUrgent ? "Urgent: \(item.title)" : item.title))
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "maintenance": "wrench.and.screwdriver"
        case "warranty", "coverage": "checkmark.shield"
        case "return": "arrow.uturn.left"
        case "claim": "doc.text"
        case "recall": "exclamationmark.triangle"
        case "loan": "person.2"
        case "shopping": "cart"
        case "backup": "externaldrive"
        case "review", "seen": "eye"
        case "roomscan": "camera.viewfinder"
        case "service", "support": "server.rack"
        case "ai": "sparkles"
        case "paperless": "tray.and.arrow.down"
        default: "bell"
        }
    }
}

/// A heading over a list in the window.
struct SectionHeading: View {
    let title: LocalizedStringKey
    var trailing: AnyView?

    init(_ title: LocalizedStringKey, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet, centred note (nothing found, nothing due).
struct EmptyNote: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Picks a place, searchable (never a long pop-up menu): the place's path, or "No place".
struct PlacePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var placeId: String?
    @State private var open = false
    @State private var filter = ""

    var body: some View {
        Button {
            open = true
        } label: {
            HStack {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                Text(chosen?.path ?? String(localized: "No place")).lineLimit(1).truncationMode(.head)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("Place: \(chosen?.path ?? String(localized: "No place"))"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                TextField("Find a place", text: $filter)
                    .textFieldStyle(.roundedBorder)
                List {
                    Button("No place") { pick(nil) }
                    ForEach(matches, id: \.place.id) { entry in
                        Button {
                            pick(entry.place.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.place.name)
                                if filter.isEmpty == false || entry.depth > 0 {
                                    Text(entry.place.path).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, filter.isEmpty ? CGFloat(entry.depth) * 12 : 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
            .padding(10)
            .frame(width: 300, height: 340)
            .task { await model.loadPlaces() }
        }
    }

    private var everything: [(place: Place, depth: Int)] { model.places?.flattened ?? [] }

    private var chosen: Place? { everything.first { $0.place.id == placeId }?.place }

    private var matches: [(place: Place, depth: Int)] {
        PlaceFilter.matches(everything, filter)
    }

    private func pick(_ id: String?) {
        placeId = id
        open = false
        filter = ""
    }
}

/// Finding a place by any word of its name or path ("garage shelf").
enum PlaceFilter {
    static func matches(_ places: [(place: Place, depth: Int)], _ text: String) -> [(place: Place, depth: Int)] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return places }
        return places.filter { entry in
            let path = entry.place.path.lowercased()
            return words.allSatisfy { path.contains($0) }
        }
    }
}
