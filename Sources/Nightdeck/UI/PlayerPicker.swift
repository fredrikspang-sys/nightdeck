import NightdeckCore
import SwiftUI

@MainActor
@Observable
final class PlayerPickerUI {
    static let shared = PlayerPickerUI()
    var draft = ""
    var menuOpen = false
    var windowOpen = false
}

/// Window-header control. The list is built only while the popover is open.
struct PlayerPickerButton: View {
    @Environment(AppModel.self) private var model

    private var address: String {
        model.host.isEmpty ? "" : "\(model.host):\(model.port)"
    }

    private var label: String { model.playerMenuTitle }

    var body: some View {
        @Bindable var ui = PlayerPickerUI.shared
        Button {
            ui.windowOpen.toggle()
        } label: {
            Text(label)
                .lineLimit(1)
                .truncationMode(model.host.isEmpty || label == address ? .middle : .tail)
                .frame(maxWidth: model.host.isEmpty || label == address ? 200 : 150, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .help("Players")
        .accessibilityLabel("Player \(model.playerMenuTitle)")
        .accessibilityValue(address)
        .popover(isPresented: $ui.windowOpen, arrowEdge: .bottom) {
            PlayerPickerList()
                .environment(model)
        }
    }
}

/// Trailing window-header cluster. The title stays on the leading edge; this truncates instead of covering it.
struct PlayerWindowHeader: View {
    @Environment(AppModel.self) private var model

    private var address: String {
        model.host.isEmpty ? "" : "\(model.host):\(model.port)"
    }

    private var titleIsAddress: Bool {
        model.host.isEmpty || model.playerMenuTitle == address
    }

    var body: some View {
        HStack(spacing: 8) {
            PlayerPickerButton()
            if !titleIsAddress {
                Text(address)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 168, alignment: .trailing)
                    .help(address)
                    .accessibilityLabel("Address \(address)")
            }
        }
        .frame(maxWidth: 360, alignment: .trailing)
    }
}

/// Menu-bar control. The list expands in place; a nested popover is clipped there.
struct PlayerPickerMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = PlayerPickerUI.shared
        VStack(alignment: .leading, spacing: 4) {
            Button {
                ui.menuOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(model.playerMenuTitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ui.menuOpen ? "Hide" : "Players")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Player \(model.playerMenuTitle)")
            if model.connected, model.lastError == nil, !model.groupCaption.isEmpty {
                Text(model.groupCaption)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .accessibilityLabel("Group \(model.groupCaption)")
            }
            if ui.menuOpen {
                PlayerPickerList(framed: false)
            }
        }
    }
}

struct PlayerPickerList: View {
    var framed = true
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = PlayerPickerUI.shared
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Players")
                    .font(.headline)
                Spacer()
                if model.discovering {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.players) { player in
                        PlayerRow(player: player)
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack(spacing: 6) {
                TextField("host or host:port", text: $ui.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(ui) }
                Button("Add") { add(ui) }
            }
            if framed {
                Text("Adding saves the player. Choose it to connect. Group uses this player as the master.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(framed ? 12 : 0)
        .frame(width: framed ? 320 : nil)
        .frame(maxWidth: framed ? 320 : .infinity, alignment: .leading)
        .background(framed ? Theme.bg : Color.clear)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .task { await model.refreshPicker() }
    }

    private func add(_ ui: PlayerPickerUI) {
        let text = ui.draft
        guard PlayerAddress.parse(text) != nil else {
            model.addManualPlayer(text)
            return
        }
        model.addManualPlayer(text)
        ui.draft = ""
    }
}

private struct PlayerRow: View {
    @Environment(AppModel.self) private var model
    let player: KnownPlayer

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                let switching = !model.isActive(player)
                model.selectPlayer(player)
                if switching {
                    PlayerPickerUI.shared.windowOpen = false
                    PlayerPickerUI.shared.menuOpen = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(player.name)
                            .lineLimit(1)
                        if model.isActive(player) {
                            Text("Active")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        } else if model.playerIsGrouped(player) {
                            Text("In group")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("\(player.host):\(player.port)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch to \(player.name)")
            if !model.isActive(player) {
                Button(model.playerIsGrouped(player) ? "Ungroup" : "Group") {
                    model.toggleGroup(player)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.connected)
                .accessibilityLabel(
                    model.playerIsGrouped(player) ? "Ungroup \(player.name)" : "Group \(player.name)"
                )
            }
        }
    }
}
