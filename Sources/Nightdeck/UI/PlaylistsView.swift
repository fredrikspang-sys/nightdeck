import SwiftUI
import NightdeckCore

@MainActor
@Observable
final class PlaylistUI {
    static let shared = PlaylistUI()
    var playlists: [BrowseItem] = []
    var presets: [Preset] = []
    var name = ""
    var loading = false
    var loaded = false

    func reload(_ model: AppModel) async {
        loading = true
        defer { loading = false; loaded = true }
        playlists = await model.savedPlaylists()
        presets = await model.loadPresets()
    }
}

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = PlaylistUI.shared
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Playlist name", text: $ui.name)
                    .textFieldStyle(.roundedBorder)
                SymbolButton(
                    systemName: DeckSymbol.save,
                    help: "Save queue",
                    caption: "Save",
                    bordered: true,
                    enabled: model.connected && !ui.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    let name = ui.name
                    Task {
                        if await model.saveQueue(named: name) {
                            ui.name = ""
                            await ui.reload(model)
                        }
                    }
                }
                if ui.loading { ProgressView().controlSize(.small) }
            }
            .padding(16)
            List {
                Section("Playlists") {
                    if ui.playlists.isEmpty {
                        Text(ui.loaded ? "No saved playlists" : "Loading…")
                            .foregroundStyle(Theme.secondary)
                    }
                    ForEach(Array(ui.playlists.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.text).lineLimit(1)
                            Spacer()
                            SymbolButton(systemName: DeckSymbol.play, help: "Play", enabled: model.connected) {
                                Task { await model.loadPlaylist(item) }
                            }
                            SymbolButton(systemName: DeckSymbol.delete, help: "Delete", destructive: true, enabled: model.connected) {
                                Task {
                                    await model.deletePlaylist(item)
                                    await ui.reload(model)
                                }
                            }
                        }
                    }
                }
                Section("Presets") {
                    if ui.presets.isEmpty {
                        Text(ui.loaded ? "No presets" : " ")
                            .foregroundStyle(Theme.secondary)
                    }
                    ForEach(ui.presets) { preset in
                        HStack {
                            Text(preset.name.isEmpty ? preset.id : preset.name)
                            Spacer()
                            SymbolButton(systemName: DeckSymbol.play, help: "Play", enabled: model.connected) {
                                model.playPreset(preset)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .task(id: "\(model.host):\(model.port):\(model.connected)") {
            ui.playlists = []
            ui.presets = []
            ui.loaded = false
            guard !model.host.isEmpty, model.connected else { return }
            await ui.reload(model)
        }
    }
}
