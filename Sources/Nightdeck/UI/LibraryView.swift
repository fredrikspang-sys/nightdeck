import AppKit
import SwiftUI
import NightdeckCore

extension BrowseItem {
    /// A row that navigates deeper. Tracks keep their play and add buttons.
    var opensInBrowser: Bool {
        !browseKey.isEmpty && type != "section" && type != "track"
    }
}

/// A BluOS `/Browse` page whose every entry is an A–Z (or #) bucket, optionally plus All.
enum LetterBrowse {
    struct LetterKey: Equatable {
        var label: String
        var key: String
    }

    struct Plan: Equatable {
        var allKey: String
        var letters: [LetterKey]
        var indexNext: String
    }

    static func plan(for page: BrowsePage) -> Plan? {
        guard !page.items.isEmpty else { return nil }
        var allKey = ""
        var letters: [LetterKey] = []
        for item in page.items {
            if isAll(item) {
                if allKey.isEmpty { allKey = item.browseKey }
                continue
            }
            guard let label = bucketLabel(item) else { return nil }
            letters.append(LetterKey(label: label, key: item.browseKey))
        }
        guard !letters.isEmpty else { return nil }
        return Plan(allKey: allKey, letters: letters, indexNext: page.nextKey)
    }

    static func isAll(_ item: BrowseItem) -> Bool {
        guard item.browseKey.isEmpty == false, item.playURL.isEmpty, item.actionURL.isEmpty else { return false }
        if item.type == "track" || item.type == "contextMenu" { return false }
        switch item.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "all", "all albums", "all artists", "all songs": return true
        default: return false
        }
    }

    /// One letter, a digit, `#`, or `0-9`, with no play or action URL.
    static func bucketLabel(_ item: BrowseItem) -> String? {
        guard !item.browseKey.isEmpty, item.playURL.isEmpty, item.actionURL.isEmpty else { return nil }
        if item.type == "track" || item.type == "contextMenu" { return nil }
        let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "#" || raw.caseInsensitiveCompare("0-9") == .orderedSame || raw == "0–9" { return "#" }
        guard raw.count == 1, let ch = raw.first else { return nil }
        if ch.isNumber { return "#" }
        if ch.isLetter { return String(ch).uppercased() }
        return nil
    }

    static func isIndexEntry(_ item: BrowseItem) -> Bool {
        isAll(item) || bucketLabel(item) != nil
    }

    static func sortLetter(_ item: BrowseItem) -> String {
        let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = raw.first else { return "#" }
        if first.isASCII, first.isLetter { return String(first).uppercased() }
        return "#"
    }

    static func canonical(_ label: String) -> String {
        let raw = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "#" || raw.caseInsensitiveCompare("0-9") == .orderedSame || raw == "0–9" { return "#" }
        if raw.count == 1, let ch = raw.first, ch.isLetter { return String(ch).uppercased() }
        return raw
    }
}

private struct LibraryFrame {
    var page: BrowsePage
    var flat: FlatBrowse?
}

/// Items walked out of a letter index. The letter page itself is never shown.
private struct FlatBrowse {
    var title: String
    var items: [BrowseItem] = []
    var queue: [String] = []
    var seen = Set<String>()
    var known = Set<String>()
    var pages = 0
    var jumpLabels: [String] = []
    var exhausted = false
}

@MainActor
@Observable
final class LibraryUI {
    static let shared = LibraryUI()
    static let flatPageCap = 400
    static let flatFirstItems = 24
    static let flatFirstPages = 12

    var query = ""
    var loading = false
    var error: String?
    var selection: Int?
    var scrollID: String?
    var hoveredID: String?

    private var stack: [LibraryFrame] = []
    private var generation = 0
    private var loadedEndpoint = ""
    /// Key of the page on screen. Wake reloads this, not the whole library.
    private var browseKey = ""

    var page: BrowsePage? {
        guard let frame = stack.last else { return nil }
        guard let flat = frame.flat else { return frame.page }
        return BrowsePage(
            serviceName: flat.title,
            searchKey: frame.page.searchKey,
            nextKey: "",
            type: "flat",
            items: flat.items
        )
    }

    var hasMore: Bool {
        guard let frame = stack.last else { return false }
        if let flat = frame.flat { return !flat.exhausted }
        return !frame.page.nextKey.isEmpty
    }

    var jumpLabels: [String] {
        stack.last?.flat?.jumpLabels ?? []
    }

    var depth: Int { stack.count }

    /// Clears a browse that belonged to another player. Same player keeps the pages already loaded.
    func prepare(_ model: AppModel) {
        let endpoint = "\(model.host):\(model.port)"
        guard endpoint != loadedEndpoint else { return }
        loadedEndpoint = endpoint
        clearStack()
    }

    /// Drops the cached player so the next load hits the browse API again.
    func resetSession() {
        loadedEndpoint = ""
        clearStack()
    }

    func loadInitial(_ model: AppModel) async {
        guard !model.host.isEmpty, model.connected, stack.isEmpty, !loading else { return }
        await open(model, key: AppModel.libraryRoot, push: false)
    }

    /// Re-reads the page on screen. Browse only; does not add or play.
    func reloadAfterReconnect(_ model: AppModel) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            await search(model)
            return
        }
        let key = browseKey.isEmpty ? AppModel.libraryRoot : browseKey
        if stack.isEmpty {
            await open(model, key: key, push: false)
            return
        }
        generation += 1
        let token = generation
        loading = true
        defer { if token == generation { loading = false } }
        guard let fetched = await model.browse(key: key) else {
            if token == generation, let message = model.lastError { error = message }
            return
        }
        guard token == generation else { return }
        error = nil
        if stack.last?.flat != nil {
            let title = stack.last?.page.serviceName ?? ""
            present(fetched, title: title, push: false)
            browseKey = key
            guard stack.last?.flat != nil else { return }
            await fillFlat(model, token: token, itemGoal: Self.flatFirstItems, pageGoal: Self.flatFirstPages)
            return
        }
        guard var frame = stack.last else { return }
        frame.page.items = fetched.items
        frame.page.nextKey = fetched.nextKey
        if !fetched.searchKey.isEmpty { frame.page.searchKey = fetched.searchKey }
        stack[stack.count - 1] = frame
    }

    func open(_ model: AppModel, key: String, push: Bool, title: String = "") async {
        browseKey = key
        generation += 1
        let token = generation
        loading = true
        selection = nil
        scrollID = nil
        hoveredID = nil
        defer { if token == generation { loading = false } }
        guard let page = await model.browse(key: key) else {
            if token == generation, let message = model.lastError { error = message }
            return
        }
        guard token == generation else { return }
        error = nil
        present(page, title: title, push: push)
        guard stack.last?.flat != nil else { return }
        await fillFlat(model, token: token, itemGoal: Self.flatFirstItems, pageGoal: Self.flatFirstPages)
    }

    func back() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        selection = nil
        scrollID = nil
        hoveredID = nil
    }

    func more(_ model: AppModel) async {
        guard !loading else { return }
        generation += 1
        let token = generation
        let depth = stack.count
        loading = true
        defer { if token == generation { loading = false } }
        if stack.last?.flat != nil {
            _ = await stepFlat(model, token: token)
            return
        }
        guard let current = stack.last?.page, !current.nextKey.isEmpty else { return }
        let key = current.nextKey
        guard let next = await model.browse(key: key) else {
            if token == generation, let message = model.lastError { error = message }
            return
        }
        guard token == generation, stack.count == depth, var frame = stack.last,
              frame.flat == nil, frame.page.nextKey == key else { return }
        frame.page.items.append(contentsOf: next.items)
        frame.page.nextKey = next.nextKey == key ? "" : next.nextKey
        stack[stack.count - 1] = frame
    }

    /// Loads every remaining page, stopping on a repeated key or the page cap.
    func drain(_ model: AppModel) async {
        var spins = 0
        while hasMore, spins < Self.flatPageCap {
            let before = loadedCount
            await more(model)
            spins += 1
            if loadedCount == before { break }
        }
    }

    /// Loads forward until `label` is on screen, then asks the list to scroll there.
    func jump(_ model: AppModel, label: String) async {
        let want = LetterBrowse.canonical(label)
        var spins = 0
        while spins < Self.flatPageCap {
            if let item = page?.items.first(where: { LetterBrowse.sortLetter($0) == want }) {
                scrollID = item.id
                return
            }
            guard hasMore else { return }
            await more(model)
            spins += 1
        }
    }

    /// Return key. Opens the selected browsable row and does not start playback.
    func activateSelection(_ model: AppModel) async {
        guard let selection, let items = page?.items, items.indices.contains(selection) else { return }
        let item = items[selection]
        guard item.opensInBrowser else { return }
        await open(model, key: item.browseKey, push: true, title: item.text)
    }

    func search(_ model: AppModel) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let token = generation
        selection = nil
        scrollID = nil
        if text.isEmpty {
            stack = []
            loading = false
            await loadInitial(model)
            return
        }
        loading = true
        defer { if token == generation { loading = false } }
        guard let page = await model.search(query: text) else {
            if token == generation, let message = model.lastError { error = message }
            return
        }
        guard token == generation else { return }
        error = nil
        present(page, title: page.serviceName, push: false)
        guard stack.last?.flat != nil else { return }
        await fillFlat(model, token: token, itemGoal: Self.flatFirstItems, pageGoal: Self.flatFirstPages)
    }

    private var loadedCount: Int {
        if let flat = stack.last?.flat { return flat.pages }
        return stack.last?.page.items.count ?? 0
    }

    private func clearStack() {
        generation += 1
        stack = []
        query = ""
        browseKey = ""
        loading = false
        error = nil
        selection = nil
        scrollID = nil
        hoveredID = nil
    }

    private func present(_ page: BrowsePage, title: String, push: Bool) {
        let frame: LibraryFrame
        if let plan = LetterBrowse.plan(for: page) {
            var flat = FlatBrowse(title: title.isEmpty ? (page.serviceName.isEmpty ? "Library" : page.serviceName) : title)
            if !plan.allKey.isEmpty {
                flat.queue = [plan.allKey]
            } else {
                flat.queue = plan.letters.map(\.key)
            }
            if !plan.indexNext.isEmpty, !flat.queue.contains(plan.indexNext) {
                flat.queue.append(plan.indexNext)
            }
            var labels: [String] = []
            for letter in plan.letters where !labels.contains(letter.label) {
                labels.append(letter.label)
            }
            flat.jumpLabels = labels
            flat.exhausted = flat.queue.isEmpty
            let shell = BrowsePage(serviceName: flat.title, searchKey: page.searchKey, type: "flat")
            frame = LibraryFrame(page: shell, flat: flat)
        } else {
            frame = LibraryFrame(page: page, flat: nil)
        }
        if push { stack.append(frame) } else { stack = [frame] }
    }

    private func fillFlat(_ model: AppModel, token: Int, itemGoal: Int, pageGoal: Int) async {
        var steps = 0
        while token == generation, steps < pageGoal {
            guard let flat = stack.last?.flat, !flat.exhausted, flat.items.count < itemGoal else { return }
            let progressed = await stepFlat(model, token: token)
            if !progressed { return }
            steps += 1
        }
    }

    /// Fetches one queued key. A nested letter index is queued, not shown.
    private func stepFlat(_ model: AppModel, token: Int) async -> Bool {
        let depth = stack.count
        guard depth > 0, var flat = stack[depth - 1].flat, !flat.exhausted else { return false }
        if flat.pages >= Self.flatPageCap {
            flat.exhausted = true
            stack[depth - 1].flat = flat
            return false
        }
        while let first = flat.queue.first, flat.seen.contains(first) {
            flat.queue.removeFirst()
        }
        guard let key = flat.queue.first else {
            flat.exhausted = true
            stack[depth - 1].flat = flat
            return false
        }
        flat.queue.removeFirst()
        flat.seen.insert(key)
        stack[depth - 1].flat = flat
        guard let fetched = await model.browse(key: key) else {
            guard token == generation, stack.count == depth else { return false }
            stack[depth - 1].flat?.exhausted = true
            if let message = model.lastError { error = message }
            return false
        }
        guard token == generation, stack.count == depth, var flat = stack[depth - 1].flat else { return false }
        flat.pages += 1
        if let nested = LetterBrowse.plan(for: fetched) {
            var next: [String] = []
            if !nested.allKey.isEmpty {
                next.append(nested.allKey)
            } else {
                next.append(contentsOf: nested.letters.map(\.key))
            }
            if !nested.indexNext.isEmpty { next.append(nested.indexNext) }
            let fresh = next.filter { !flat.seen.contains($0) && !flat.queue.contains($0) }
            flat.queue.insert(contentsOf: fresh, at: 0)
        } else {
            for item in fetched.items where !LetterBrowse.isIndexEntry(item) {
                if flat.known.insert(item.id).inserted {
                    flat.items.append(item)
                }
            }
            if !fetched.nextKey.isEmpty, !flat.seen.contains(fetched.nextKey), !flat.queue.contains(fetched.nextKey) {
                flat.queue.insert(fetched.nextKey, at: 0)
            }
        }
        flat.exhausted = flat.queue.isEmpty || flat.pages >= Self.flatPageCap
        stack[depth - 1].flat = flat
        return true
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = LibraryUI.shared
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if ui.depth > 1 {
                    SymbolButton(systemName: DeckSymbol.back, help: "Back", action: ui.back)
                }
                TextField("Search library", text: $ui.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await ui.search(model) } }
                SymbolButton(systemName: DeckSymbol.search, help: "Search", bordered: true) {
                    Task { await ui.search(model) }
                }
                if ui.loading { ProgressView().controlSize(.small) }
            }
            .padding(16)
            if let error = ui.error {
                Text(error).font(.callout).foregroundStyle(Theme.danger).padding(.horizontal, 16)
            }
            if let note = model.libraryNote {
                Text(note.text)
                    .font(.footnote)
                    .foregroundStyle(note.isFailure ? Theme.danger : Theme.fader)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(note.text)
            }
            HStack(alignment: .top, spacing: 0) {
                list(ui)
                if ui.jumpLabels.count > 1 {
                    jumpStrip(ui)
                }
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .task(id: "\(model.host):\(model.port):\(model.connected)") {
            ui.prepare(model)
            await ui.loadInitial(model)
        }
    }

    private func list(_ source: LibraryUI) -> some View {
        @Bindable var ui = source
        return ScrollViewReader { proxy in
            List(selection: $ui.selection) {
                if let page = ui.page {
                    ForEach(Array(page.items.enumerated()), id: \.offset) { index, item in
                        LibraryRow(
                            item: item,
                            connected: model.connected,
                            addCue: model.libraryAddCue(for: item),
                            playCue: model.libraryPlayCue(for: item)
                        ) {
                            Task { await ui.open(model, key: item.browseKey, push: true, title: item.text) }
                        } onPlay: {
                            model.addToQueue(item, now: true)
                        } onAdd: {
                            model.addToQueue(item, now: false)
                        }
                        .tag(index)
                        .id(item.id)
                        .onAppear {
                            guard index == page.items.count - 1, ui.hasMore else { return }
                            Task { await ui.more(model) }
                        }
                    }
                    if ui.hasMore {
                        Button("Load more") { Task { await ui.more(model) } }
                            .buttonStyle(.borderless)
                    }
                } else if !ui.loading {
                    Text(model.host.isEmpty ? "Choose a player" : "Library is empty")
                        .foregroundStyle(Theme.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: ui.scrollID) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
            }
            .onKeyPress(.return) {
                guard ui.selection != nil else { return .ignored }
                Task { await ui.activateSelection(model) }
                return .handled
            }
        }
    }

    private func jumpStrip(_ ui: LibraryUI) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ui.jumpLabels, id: \.self) { label in
                    Button(label) { Task { await ui.jump(model, label: label) } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 16, height: 14)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 16)
        .accessibilityLabel("Letters")
    }
}

private struct LibraryRow: View {
    var item: BrowseItem
    var connected: Bool
    var addCue: LibraryCue
    var playCue: LibraryCue
    var onOpen: () -> Void
    var onPlay: () -> Void
    var onAdd: () -> Void

    private var hovered: Bool { item.opensInBrowser && LibraryUI.shared.hoveredID == item.id }

    var body: some View {
        if item.type == "section" {
            Text(item.text2.isEmpty ? item.text : "\(item.text)  \(item.text2)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
        } else {
            HStack(spacing: 12) {
                if item.opensInBrowser {
                    Button(action: onOpen) {
                        HStack(spacing: 8) {
                            labels
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    labels
                    Spacer(minLength: 8)
                }
                if canQueue {
                    CueButton(
                        systemName: DeckSymbol.play,
                        help: "Play",
                        enabled: connected,
                        pending: playCue == .pending,
                        confirmed: false,
                        highlighted: playCue == .playing,
                        action: onPlay
                    )
                    CueButton(
                        systemName: DeckSymbol.add,
                        help: "Add",
                        enabled: connected,
                        pending: addCue == .pending,
                        confirmed: addCue == .added,
                        highlighted: false,
                        action: onAdd
                    )
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background { RowLabel(text: item.text.isEmpty ? item.type : item.text) }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? Theme.accent.opacity(0.14) : Color.clear)
            }
            .onHover { inside in
                guard item.opensInBrowser else { return }
                if inside {
                    LibraryUI.shared.hoveredID = item.id
                    NSCursor.pointingHand.set()
                } else if LibraryUI.shared.hoveredID == item.id {
                    LibraryUI.shared.hoveredID = nil
                    NSCursor.arrow.set()
                }
            }
            .onDisappear {
                if LibraryUI.shared.hoveredID == item.id {
                    LibraryUI.shared.hoveredID = nil
                    NSCursor.arrow.set()
                }
            }
            .accessibilityElement(children: .contain)
            .openRowAction(enabled: item.opensInBrowser, onOpen)
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text.isEmpty ? item.type : item.text).lineLimit(1)
            if !item.text2.isEmpty {
                Text(item.text2).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }

    private var canQueue: Bool {
        if item.type == "section" || item.type == "link" || item.type == "genre" { return false }
        if !item.playURL.isEmpty || !item.contextMenuKey.isEmpty { return true }
        return item.isContainer
    }
}

/// Plus becomes an amber check after a successful add. Play turns amber while that row is current.
private struct CueButton: View {
    var systemName: String
    var help: String
    var enabled: Bool
    var pending: Bool
    var confirmed: Bool
    var highlighted: Bool
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                if pending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: confirmed ? DeckSymbol.added : systemName)
                        .font(.body.weight(confirmed || highlighted ? .semibold : .regular))
                        .foregroundStyle(confirmed || highlighted ? Theme.fader : Theme.secondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(confirmed || highlighted ? Theme.fader : Theme.secondary)
        .disabled(!enabled || pending)
        .help(label)
        .accessibilityLabel(label)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
    }

    private var label: String {
        if confirmed { return "Added" }
        if highlighted { return "Playing" }
        return help
    }

    private var phase: String {
        if pending { return "pending" }
        if confirmed { return "added" }
        if highlighted { return "playing" }
        return "idle"
    }
}

/// AppKit list cells do not surface SwiftUI `Text` to accessibility until focused.
private struct RowLabel: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> RowLabelView {
        let view = RowLabelView()
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(text)
        return view
    }

    func updateNSView(_ view: RowLabelView, context: Context) {
        view.setAccessibilityLabel(text)
    }
}

/// Sits behind the row. It names the row for accessibility and does not take clicks.
private final class RowLabelView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension View {
    @ViewBuilder
    func openRowAction(enabled: Bool, _ action: @escaping () -> Void) -> some View {
        if enabled {
            accessibilityAction(named: Text("Open"), action)
        } else {
            self
        }
    }
}
