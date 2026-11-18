import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayerPickerMenu()
            HStack(alignment: .center, spacing: 10) {
                transport
                VolumeBlock(status: model.status, connected: model.connected, compact: true)
            }
            OpenNightdeckButton()
        }
        .preferredColorScheme(.dark)
        .padding(12)
        .frame(width: 364)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(model.lastError == nil ? Theme.secondary : Theme.danger)
                .lineLimit(1)
            HStack(spacing: 6) {
                SymbolButton(systemName: DeckSymbol.previous, help: "Previous", scale: .transport, prominent: true, bordered: true, enabled: model.connected, action: model.previous)
                SymbolButton(
                    systemName: model.status.state.isPlaying ? DeckSymbol.pause : DeckSymbol.play,
                    help: model.status.state.isPlaying ? "Pause" : "Play",
                    scale: .transport,
                    prominent: true,
                    bordered: true,
                    enabled: model.connected,
                    action: model.togglePlayPause
                )
                SymbolButton(
                    systemName: DeckSymbol.stop,
                    help: "Stop",
                    scale: .transport,
                    prominent: true,
                    bordered: true,
                    enabled: model.connected && model.status.state != .stop,
                    action: model.stopPlayback
                )
                SymbolButton(systemName: DeckSymbol.next, help: "Next", scale: .transport, prominent: true, bordered: true, enabled: model.connected, action: model.next)
            }
        }
    }

    private var title: String {
        if !model.status.title.isEmpty { return model.status.title }
        return model.connected ? "Nothing playing" : "Nightdeck"
    }

    private var subtitle: String {
        if let error = model.lastError { return error }
        if model.host.isEmpty { return "Choose a player" }
        if !model.connected { return "Connecting to \(model.host)…" }
        if let caption = model.sleepCaption { return caption }
        let line = [model.status.artist, model.status.album].filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? model.host : line
    }
}
