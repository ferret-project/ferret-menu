import FerretKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search

/// Search box on top; with nothing typed, what needs doing and what was opened last.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var results: [Item] = []
    @State private var searching = false
    @State private var searched = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find anything you own", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                if searching {
                    ProgressView().controlSize(.small)
                } else if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(Text("Clear"))
                        .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { scroller in
                FittedScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        if trimmed.isEmpty {
                            Glance()
                        } else if results.isEmpty, !searching, searched == trimmed {
                            EmptyNote(symbol: "magnifyingglass", text: "Nothing found for “\(trimmed)”.")
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                ItemRow(item: item, selected: index == selected).id(index)
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { _, index in scroller.scrollTo(index) }
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { focused = true }
        .task(id: trimmed) { await search(trimmed) }
    }

    private var trimmed: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func search(_ text: String) async {
        guard !text.isEmpty else {
            results = []
            searched = ""
            return
        }
        // Wait for a pause in typing; a new keystroke cancels this.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await model.search(text)
            guard !Task.isCancelled else { return }
            results = found
            searched = text
            selected = 0
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            model.show(error)
        }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        selected = min(max(selected + by, 0), results.count - 1)
        return .handled
    }

    private func openSelected() {
        guard results.indices.contains(selected) else { return }
        model.open(itemRoute(results[selected].id))
    }
}

/// With nothing typed: the most pressing bell items and the things opened last.
private struct Glance: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.attention.isEmpty {
            SectionHeading("Needs attention", trailing: model.attention.count > 3 ? AnyView(
                Button("All \(model.attention.count)") { model.screen = .bell }.buttonStyle(.link).font(.caption)
            ) : nil)
            ForEach(model.attention.prefix(3), id: \.key) { BellRow(item: $0) }
        }
        if !model.recent.isEmpty {
            SectionHeading("Opened lately")
            ForEach(model.recent) { ItemRow(item: $0) }
        }
        if model.attention.isEmpty, model.recent.isEmpty, model.summary != nil {
            EmptyNote(symbol: "pawprint", text: "Search by name, brand, what it's for, or what's in its photos and documents.")
        }
    }
}

// MARK: - The bell

struct BellScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let urgent = model.attention.filter(\.isUrgent)
        let soon = model.attention.filter { !$0.isUrgent }
        if model.attention.isEmpty {
            EmptyNote(symbol: "checkmark.circle", text: "Nothing needs doing right now.")
        } else {
            ScrollViewReader { scroller in
                FittedScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        if !urgent.isEmpty {
                            SectionHeading("Urgent")
                            ForEach(urgent, id: \.key) { BellRow(item: $0).id($0.key) }
                        }
                        if !soon.isEmpty {
                            SectionHeading("Coming up")
                            ForEach(soon, id: \.key) { BellRow(item: $0).id($0.key) }
                        }
                    }
                    .padding(6)
                }
                // The form that opened is shown whole.
                .onChange(of: model.dealing) { _, key in
                    guard let key else { return }
                    Task { @MainActor in withAnimation { scroller.scrollTo(key, anchor: .center) } }
                }
                .onAppear { if let key = model.dealing { scroller.scrollTo(key, anchor: .center) } }
            }
        }
    }
}

// MARK: - Shopping list

/// What's run out or running low: tick off what was bought (its count goes up), copy the list.
struct ShoppingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            if let last = model.lastBought {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Added \(last.count) to “\(last.name)”.").font(.callout).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Undo") { Task { await model.undoBought() } }.controlSize(.small)
                    Button { model.forgetBought() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(Text("Dismiss"))
                        .accessibilityLabel(Text("Dismiss"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
            }
            if let list = model.shopping {
                if list.items.isEmpty {
                    EmptyNote(symbol: "cart", text: "Nothing to buy. Things you keep track of show up here when they run out or get low.")
                } else {
                    FittedScroll {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(list.items) { ShoppingRow(entry: $0) }
                        }
                        .padding(6)
                    }
                    Divider()
                    HStack {
                        Button(copied ? "Copied" : "Copy List") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(list.text, forType: .string)
                            copied = true
                        }
                        Spacer()
                        Button("Open in Ferret") { model.open("#/shopping") }
                    }
                    .controlSize(.small)
                    .padding(8)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 36)
            }
        }
        .task { await model.loadShopping() }
    }
}

private struct ShoppingRow: View {
    @Environment(AppModel.self) private var model
    let entry: ShoppingList.Entry
    @State private var hovering = false
    @State private var saving = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.open(itemRoute(entry.id)) } label: {
                HStack(spacing: 10) {
                    Thumbnail(photoId: entry.photoId)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1).help(entry.name)
                        Text(left).font(.caption).foregroundStyle(entry.quantity == 0 ? Color.red : Color.orange).lineLimit(1)
                        if let forTask = entry.forTask {
                            Text("For \(forTask)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if let place = entry.place {
                            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens it in Ferret"))
            if model.canEdit {
                Button {
                    buy(entry.buy)
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Bought \(entry.buy)") }
                }
                .controlSize(.small)
                .disabled(saving)
                .help(Text("Adds \(entry.buy) to its count"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in Ferret") { model.open(itemRoute(entry.id)) }
            if model.canEdit {
                if entry.buy != 1 { Button("Bought 1") { buy(1) } }
                Button("Bought \(entry.buy)") { buy(entry.buy) }
            }
        }
    }

    private var left: String {
        let count = entry.quantity == 0 ? String(localized: "None left") : String(localized: "\(entry.quantity) left")
        guard let least = entry.minQuantity, least > 0 else { return count }
        return count + " · " + String(localized: "keep at least \(least)")
    }

    private func buy(_ count: Int) {
        saving = true
        Task {
            defer { saving = false }
            do { try await model.bought(entry, count: count) } catch { model.show(error) }
        }
    }
}

// MARK: - Ask Ferret

struct AskScreen: View {
    /// The longest question Ferret takes.
    static let longest = 500
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var asked = ""
    @State private var answer: AskAnswer?
    @State private var asking = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("How often should I descale the kettle?", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    .focused($focused)
                    .onSubmit(ask)
                    .onChange(of: question) { _, text in
                        if text.count > Self.longest { question = String(text.prefix(Self.longest)) }
                    }
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).count < 3 || asking)
            }
            if question.count > Self.longest - 100 {
                Text("\(Self.longest - question.count) characters left")
                    .font(.caption)
                    .foregroundStyle(question.count >= Self.longest ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            FittedScroll {
                VStack(alignment: .leading, spacing: 12) {
                    if asking {
                        HStack { ProgressView().controlSize(.small); Text("Looking through your things…").foregroundStyle(.secondary) }
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else if let answer {
                        Text(asked).font(.headline)
                        Text(Self.markdown(answer.answer)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !answer.citations.isEmpty {
                            SectionHeading("From").padding(.horizontal, -8)
                            ForEach(answer.citations, id: \.self) { citation in
                                if let route = citation.route {
                                    Button { model.open(route) } label: {
                                        Label(citation.label, systemImage: citation.attachmentId == nil ? "shippingbox" : "doc.text")
                                            .multilineTextAlignment(.leading)
                                    }
                                    .buttonStyle(.link)
                                } else {
                                    Label(citation.label, systemImage: "doc.text").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text("Ask about your things: where something is, what a manual says, when a warranty ends. Ferret answers from what's in it, and says so when it doesn't know.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.count <= Self.longest, !asking else { return }
        asking = true
        failure = nil
        asked = text
        Task {
            defer { asking = false }
            do {
                answer = try await model.ask(text)
            } catch {
                answer = nil
                failure = AppModel.describe(error)
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Add

struct AddScreen: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var placeId: String?
    @State private var quantity = 1
    @State private var adding = false
    @State private var added: Item?
    @State private var dropping = false
    @FocusState private var focused: Bool

    var body: some View {
        if let added {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Added “\(added.name)”").font(.headline)
                HStack {
                    Button("Open in Ferret") { model.open(itemRoute(added.id)) }
                    Button("Add Another") { reset() }.keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            form
        }
    }

    private var form: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            TextField("What is it?", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
            PlacePicker(placeId: $placeId)
            Stepper(value: $quantity, in: 1 ... 9999) {
                Text("How many: \(quantity)")
            }
            dropZone
            if !model.staged.isEmpty {
                FittedScroll(tallest: 110) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.staged) { file in
                            HStack {
                                Image(systemName: file.kind == "photo" ? "photo" : "doc")
                                Text(file.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { model.staged.removeAll { $0 == file } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help(Text("Leave out"))
                                    .accessibilityLabel(Text("Leave out \(file.name)"))
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            HStack {
                Text("Add more details in Ferret afterwards.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: add) {
                    if adding { ProgressView().controlSize(.small) } else { Text("Add") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || adding)
            }
        }
        .padding(12)
        .onAppear {
            focused = true
            model.holdOpen = false
        }
    }

    private var dropZone: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(.secondary)
            Text("Drop photos, receipts or manuals here").font(.callout).foregroundStyle(.secondary)
            Button("Choose Files…", action: choose).buttonStyle(.link).font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .background(RoundedRectangle(cornerRadius: 10).fill(dropping ? Color.accentColor.opacity(0.1) : .clear))
        .dropDestination(for: URL.self) { urls, _ in
            let files = PickedFile.from(urls)
            model.stage(files)
            return !files.isEmpty
        } isTargeted: { dropping = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .text, .data]
        model.holdOpen = true
        panel.begin { response in
            Task { @MainActor in
                model.holdOpen = false
                if response == .OK { model.stage(PickedFile.from(panel.urls)) }
                model.showWindow()
            }
        }
    }

    private func add() {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                let (item, failed) = try await model.add(name: text, placeId: placeId, quantity: quantity, files: model.staged)
                model.staged = []
                added = item
                if !failed.isEmpty {
                    model.message = String(localized: "Added, but some files didn't go up:") + "\n" + failed.joined(separator: "\n")
                }
            } catch {
                model.show(error)
            }
        }
    }

    private func reset() {
        added = nil
        name = ""
        quantity = 1
        focused = true
    }
}
