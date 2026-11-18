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

/// Sheet and selection state for Music Library. The password lives only here, in memory,
/// and is cleared when the sheet closes. It is not written to UserDefaults or the Keychain.
@MainActor
@Observable
final class ShareSettingsUI {
    static let shared = ShareSettingsUI()
    var selected: Set<String> = []
    var showAdd = false
    var confirmRemove = false
    var confirmReindex = false
    var name = ""
    var username = ""
    var password = ""
    var errorText: String?
    var busy = false

    func closeAdd() {
        password = ""
        name = ""
        username = ""
        errorText = nil
        busy = false
        showAdd = false
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ui = SettingsUI.shared
        @Bindable var sharesUI = ShareSettingsUI.shared
        @Bindable var model = model
        ScrollView {
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
            Section("Music Library") {
                if model.status.indexing > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Indexing library…")
                    }
                }
                if libraryOff {
                    Text(model.host.isEmpty ? "No player selected" : "Player is offline")
                        .foregroundStyle(Theme.secondary)
                } else if model.sharesLoaded && model.shares.isEmpty {
                    Text("No network shares")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.shares) { share in
                    Toggle(isOn: shareSelected(sharesUI, share.path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(share.path)
                                .font(.body.monospaced())
                            if share.label != share.path {
                                Text(share.label)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(libraryOff || model.sharesBusy)
                }
                if let shareError = model.shareError {
                    Text(shareError)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Refresh") { Task { await model.reloadShares() } }
                    if model.sharesBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Add share…") { sharesUI.showAdd = true }
                    Button("Remove selected…") { sharesUI.confirmRemove = true }
                        .disabled(selectedSharePaths(sharesUI).isEmpty)
                    Button("Reindex library…") { sharesUI.confirmReindex = true }
                }
                .disabled(libraryOff || model.sharesBusy)
                Text("BluOS sends share passwords unencrypted on your local network. Nightdeck does not store them; the player never returns them, so to change a login remove the share and add it again.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .formStyle(.grouped)
        }
        .frame(width: 520, height: 720)
        .preferredColorScheme(.dark)
        .task { ui.seed(model) }
        .task(id: libraryToken) { await model.reloadShares() }
        .onChange(of: model.shares.map(\.path)) { _, paths in
            sharesUI.selected = sharesUI.selected.intersection(paths)
        }
        .sheet(isPresented: $sharesUI.showAdd) {
            AddShareSheet()
        }
        .alert("Remove selected shares?", isPresented: $sharesUI.confirmRemove) {
            Button("Remove", role: .destructive) {
                let paths = selectedSharePaths(sharesUI)
                sharesUI.selected = []
                Task { await model.removeShares(paths) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The player will stop indexing music from \(selectedSharePaths(sharesUI).joined(separator: ", ")).")
        }
        .alert("Reindex library?", isPresented: $sharesUI.confirmReindex) {
            Button("Reindex") { Task { await model.reindexLibrary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The player will scan its music library again.")
        }
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

    private var libraryOff: Bool { model.host.isEmpty || !model.connected }

    private var libraryToken: String { "\(model.host)|\(model.port)|\(model.connected)" }

    private func selectedSharePaths(_ sharesUI: ShareSettingsUI) -> [String] {
        model.shares.map(\.path).filter { sharesUI.selected.contains($0) }
    }

    private func shareSelected(_ sharesUI: ShareSettingsUI, _ path: String) -> Binding<Bool> {
        Binding(
            get: { sharesUI.selected.contains(path) },
            set: { on in
                var next = sharesUI.selected
                if on { next.insert(path) }
                else { next.remove(path) }
                sharesUI.selected = next
            }
        )
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

private struct AddShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var sheet = ShareSettingsUI.shared
        VStack(alignment: .leading, spacing: 12) {
            Text("Add share")
                .font(.headline)
            TextField("Share", text: $sheet.name, prompt: Text(#"\\server\share"#))
                .font(.body.monospaced())
            if let patternMessage {
                Text(patternMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            TextField("User name", text: $sheet.username)
            SecureField("Password", text: $sheet.password)
            if let errorText = sheet.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { close() }
                Spacer()
                if sheet.busy { ProgressView().controlSize(.small) }
                Button("Add") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(sheet.busy || !nameIsValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { ShareSettingsUI.shared.password = "" }
        .task { await model.loadAddShareForm() }
    }

    private var pattern: String {
        model.addShareForm.pattern.isEmpty ? AddShareForm.fallback.pattern : model.addShareForm.pattern
    }

    private var patternMessage: String? {
        let trimmed = ShareSettingsUI.shared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ShareName.matches(trimmed, pattern: pattern) else { return nil }
        let text = model.addShareForm.patternError
        return text.isEmpty ? AddShareForm.fallback.patternError : text
    }

    private var nameIsValid: Bool {
        let trimmed = ShareSettingsUI.shared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && ShareName.matches(trimmed, pattern: pattern)
    }

    private func close() {
        ShareSettingsUI.shared.closeAdd()
        dismiss()
    }

    private func submit() {
        let sheet = ShareSettingsUI.shared
        let share = sheet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = sheet.username
        let secret = sheet.password
        sheet.busy = true
        sheet.errorText = nil
        Task {
            do {
                try await model.addShare(name: share, username: user, password: secret)
                sheet.password = ""
                sheet.closeAdd()
                dismiss()
            } catch is CancellationError {
                sheet.busy = false
            } catch {
                var text = PlayerMessages.describe(error, host: model.host)
                text = ShareForm.redact(text, secret: secret)
                sheet.errorText = text
                sheet.busy = false
            }
        }
    }
}
