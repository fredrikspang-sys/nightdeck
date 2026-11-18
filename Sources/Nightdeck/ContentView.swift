import SwiftUI

enum DeckSection: String, CaseIterable, Identifiable {
    case now = "Now Playing"
    case library = "Library"
    case queue = "Queue"
    case playlists = "Playlists"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .now: "music.note"
        case .library: "square.stack"
        case .queue: "list.number"
        case .playlists: "music.note.list"
        }
    }
}

@MainActor
@Observable
final class ShellUI {
    static let shared = ShellUI()
    var section: DeckSection = .now
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var shell = ShellUI.shared
        NavigationSplitView {
            List(selection: $shell.section) {
                ForEach(DeckSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Nightdeck")
            .toolbarTitleDisplayMode(.inline)
            .frame(minWidth: 180)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        PlayerWindowHeader()
                    }
                }
        }
        .toolbarRole(.editor)
        .background(Theme.bg)
        .task {
            // `start` is idempotent and the poll task is not this view's task.
            // Closing the window cancels this `.task` and does not reconnect.
            model.start()
            PlaybackKeys.attach(model)
        }
        .onChange(of: model.status.etag) { _, _ in
            PlaybackKeys.sync()
        }
        .onChange(of: model.connected) { _, _ in
            PlaybackKeys.sync()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch ShellUI.shared.section {
        case .now: NowPlayingView()
        case .library: LibraryView()
        case .queue: QueueView()
        case .playlists: PlaylistsView()
        }
    }
}
