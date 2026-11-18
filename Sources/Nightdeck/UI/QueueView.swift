import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.queue.isEmpty ? "Queue" : "Queue · \(model.queue.count)")
                    .font(.headline)
                Spacer()
                SymbolButton(systemName: DeckSymbol.refresh, help: "Refresh", action: model.refreshQueue)
                SymbolButton(
                    systemName: DeckSymbol.clear,
                    help: "Clear",
                    destructive: true,
                    enabled: !model.queue.isEmpty && model.connected,
                    action: model.clearQueue
                )
            }
            .padding(16)
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if model.queue.isEmpty {
                Text(emptyCaption)
                    .foregroundStyle(Theme.secondary)
                    .padding(16)
                Spacer()
            } else {
                List {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, song in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).lineLimit(1)
                                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(song.title)
                            .accessibilityAction { model.playQueueSong(song) }
                            Spacer()
                            Text(song.seconds > 0 ? Clock.text(Double(song.seconds)) : "")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                            SymbolButton(systemName: DeckSymbol.up, help: "Move up", enabled: model.connected && index != 0) {
                                move(index, by: -1)
                            }
                            SymbolButton(systemName: DeckSymbol.down, help: "Move down", enabled: model.connected && index != model.queue.count - 1) {
                                move(index, by: 1)
                            }
                            SymbolButton(systemName: DeckSymbol.remove, help: "Remove", destructive: true, enabled: model.connected) {
                                model.removeQueueSong(song.id)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.playQueueSong(song) }
                        .listRowBackground(index == model.status.song ? Theme.accent.opacity(0.16) : Color.clear)
                    }
                    .onMove { indices, destination in
                        guard let from = indices.first else { return }
                        model.moveQueueSong(from: from, toOffset: destination)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private var emptyCaption: String {
        if model.host.isEmpty { return "Choose a player" }
        if model.connected { return "The queue is empty" }
        return model.lastError ?? "Connecting…"
    }

    /// `by` is -1 or +1. `moveQueueSong` expects a SwiftUI onMove destination.
    private func move(_ index: Int, by delta: Int) {
        let offset = delta > 0 ? index + 2 : index - 1
        model.moveQueueSong(from: index, toOffset: offset)
    }
}
