import FerretKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search

/// Search box on top; with nothing typed, what needs doing and what was opened last.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Item] = []
    @State private var searching = false
    @State private var searched = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find anything you own", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                if searching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(Text("Clear"))
                        .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if trimmed.isEmpty {
                            Glance()
                        } else if results.isEmpty, !searching, searched == trimmed {
                            EmptyNote(symbol: "magnifyingglass", text: "Nothing found for “\(trimmed)”.")
                                .frame(height: 200)
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

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                .frame(height: 260)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !urgent.isEmpty {
                        SectionHeading("Urgent")
                        ForEach(urgent, id: \.key) { BellRow(item: $0) }
                    }
                    if !soon.isEmpty {
                        SectionHeading("Coming up")
                        ForEach(soon, id: \.key) { BellRow(item: $0) }
                    }
                }
                .padding(6)
            }
        }
    }
}

// MARK: - Ask Ferret

struct AskScreen: View {
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
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).count < 3 || asking)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if asking {
                        HStack { ProgressView().controlSize(.small); Text("Looking through your things…").foregroundStyle(.secondary) }
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if let answer {
                        Text(asked).font(.headline)
                        Text(Self.markdown(answer.answer)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !answer.citations.isEmpty {
                            SectionHeading("From").padding(.horizontal, -8)
                            ForEach(answer.citations, id: \.self) { citation in
                                if let itemId = citation.itemId {
                                    Button { model.open(itemRoute(itemId)) } label: {
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
        guard text.count >= 3, !asking else { return }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                ScrollView {
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
                .frame(maxHeight: 110)
            }
            Spacer(minLength: 0)
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
