import NightdeckCore
import SwiftUI

@MainActor
@Observable
final class SettingsUI {
    static let shared = SettingsUI()
    var host = ""
    var port = ""
    var manual = ""
    var seeded = false

    func seed(_ model: AppModel) {
        guard !seeded else { return }
        seeded = true
        host = model.host
        port = String(model.port)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = SettingsUI.shared
        @Bindable var model = model
        Form {
            Section("Player") {
                TextField("Host", text: $ui.host)
                TextField("Port", text: $ui.port)
                HStack {
                    Button("Connect") { connect(ui) }
                        .buttonStyle(.borderedProminent)
                    if model.discovering { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(model.lastError ?? (model.connected ? "Connected" : "Not connected"))
                        .font(.caption)
                        .foregroundStyle(model.lastError == nil && model.connected ? Theme.secondary : Theme.danger)
                }
                Text("No player is selected until you connect or choose one. Port 11000 is the BluOS default. The header and the menu bar list Bonjour players and saved ones. Choosing a player switches to it. Find players looks for _musc._tcp, _musp._tcp and _musz._tcp.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            Section("On this Mac") {
                Toggle("Menu bar controls", isOn: $model.menuBarExtra)
                Toggle("Fade volume when sleep reaches zero", isOn: $model.sleepFadeEnabled)
                LabeledContent("Fade length") {
                    HStack {
                        Slider(value: $model.sleepFadeSeconds, in: 2...300, step: 1)
                        Text("\(Int(model.sleepFadeSeconds))s")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!model.sleepFadeEnabled)
                Toggle("End sleep with stop", isOn: $model.sleepEndStop)
                Text(model.sleepEndStop ? "Sleep ends by stopping playback." : "Sleep ends by pausing playback.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            Section("Found players") {
                Button("Find players") { Task { await model.discover() } }
                    .disabled(model.discovering)
                if model.discovered.isEmpty {
                    Text("None yet").foregroundStyle(Theme.secondary)
                }
                ForEach(model.discovered) { player in
                    let known = KnownPlayer(
                        name: player.name.isEmpty ? player.host : player.name,
                        host: player.host,
                        port: player.port,
                        manual: false
                    )
                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            ui.host = player.host
                            ui.port = String(player.port)
                            model.selectPlayer(known)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(known.name)
                                    if model.isActive(known) {
                                        Text("Active").font(.caption).foregroundStyle(Theme.accent)
                                    } else if model.playerIsGrouped(known) {
                                        Text("In group").font(.caption).foregroundStyle(Theme.accent)
                                    }
                                }
                                Text("\(player.host):\(player.port)  \(player.serviceType)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        if !model.isActive(known) {
                            Button(model.playerIsGrouped(known) ? "Ungroup" : "Group") {
                                model.toggleGroup(known)
                            }
                            .disabled(!model.connected)
                            .accessibilityLabel(
                                model.playerIsGrouped(known) ? "Ungroup \(known.name)" : "Group \(known.name)"
                            )
                        }
                    }
                }
            }
            Section("Saved players") {
                TextField("host or host:port", text: $ui.manual)
                    .onSubmit { addManual(ui) }
                Button("Add player") { addManual(ui) }
                if model.manualPlayers.isEmpty {
                    Text("None saved").foregroundStyle(Theme.secondary)
                }
                ForEach(model.manualPlayers) { player in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.name)
                            Text("\(player.host):\(player.port)")
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.removeManualPlayer(id: player.id) }
                    }
                }
                Text("Adding saves the player. It does not connect until you choose it. The active player is the group master.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .preferredColorScheme(.dark)
        .task { ui.seed(model) }
        .onChange(of: model.menuBarExtra) { _, _ in model.saveSettings() }
        .onChange(of: model.sleepFadeEnabled) { _, _ in model.saveSettings() }
        .onChange(of: model.sleepFadeSeconds) { _, _ in model.saveSettings() }
        .onChange(of: model.sleepEndStop) { _, _ in model.saveSettings() }
    }

    private func connect(_ ui: SettingsUI) {
        let raw = ui.port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(raw), (1...65535).contains(port) else {
            model.setPlayer(host: ui.host, port: 0)
            return
        }
        model.setPlayer(host: ui.host, port: port)
        ui.host = model.host
        ui.port = String(model.port)
    }

    private func addManual(_ ui: SettingsUI) {
        let text = ui.manual
        guard PlayerAddress.parse(text) != nil else {
            model.addManualPlayer(text)
            return
        }
        model.addManualPlayer(text)
        ui.manual = ""
    }
}
