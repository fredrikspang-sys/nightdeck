import Foundation
import Testing
@testable import Nightdeck
@testable import NightdeckCore

@Suite(.serialized)
@MainActor
struct PlayerGroupTests {
    @Test func switchingLeavesTheOldPlayerAndDoesNotGroup() async throws {
        let snap = DefaultsSnap()
        defer { snap.restore() }
        let logA = FileManager.default.temporaryDirectory.appendingPathComponent("nd-a-\(UUID().uuidString).log")
        let logB = FileManager.default.temporaryDirectory.appendingPathComponent("nd-b-\(UUID().uuidString).log")
        let primary = try await MockServer.launch(logURL: logA)
        defer {
            primary.stop()
            try? FileManager.default.removeItem(at: logA)
        }
        let secondary = try await MockServer.launch(logURL: logB)
        defer {
            secondary.stop()
            try? FileManager.default.removeItem(at: logB)
        }
        let model = AppModel()
        defer { model.endPreview() }
        model.attachPreview(host: "127.0.0.1", port: primary.port)
        #expect(await wait { model.connected && model.status.title == "Track 1" })
        model.addManualPlayer("10.1.2.3")
        #expect(model.port == primary.port)
        #expect(model.manualPlayers.contains { $0.id == "10.1.2.3:11000" })
        model.addManualPlayer("  ")
        #expect(model.lastError == "Enter a host and port")
        await model.refreshPicker()
        model.removeManualPlayer(id: "10.1.2.3:11000")
        model.setPlayer(host: "127.0.0.1", port: secondary.port)
        let moved = await wait {
            model.port == secondary.port && model.connected && model.status.state == .play && !model.status.title.isEmpty
        }
        #expect(moved)
        var pause = URLRequest(url: URL(string: "http://127.0.0.1:\(primary.port)/_x?state=pause")!)
        pause.timeoutInterval = 2
        _ = try await URLSession.shared.data(for: pause)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(model.host == "127.0.0.1")
        #expect(model.port == secondary.port)
        #expect(model.status.state == .play)
        let paths = primary.loggedPaths() + secondary.loggedPaths()
        #expect(paths.contains { $0.hasPrefix("/SyncStatus") })
        #expect(paths.contains { $0.hasPrefix("/Status") })
        #expect(!paths.contains { $0.hasPrefix("/AddSlave") })
        #expect(!paths.contains { $0.hasPrefix("/RemoveSlave") })
        #expect(!paths.contains { $0.hasPrefix("/Volume") })
        #expect(!paths.contains { $0.hasPrefix("/Stop") })
        #expect(NightdeckDefaults.host.isEmpty)
        #expect(model.host == "127.0.0.1")
    }

    @Test func toggleGroupAddsAndRemovesTheOtherMock() async throws {
        let snap = DefaultsSnap()
        defer { snap.restore() }
        let logA = FileManager.default.temporaryDirectory.appendingPathComponent("nd-ga-\(UUID().uuidString).log")
        let logB = FileManager.default.temporaryDirectory.appendingPathComponent("nd-gb-\(UUID().uuidString).log")
        let primary = try await MockServer.launch(logURL: logA)
        defer {
            primary.stop()
            try? FileManager.default.removeItem(at: logA)
        }
        let secondary = try await MockServer.launch(logURL: logB)
        defer {
            secondary.stop()
            try? FileManager.default.removeItem(at: logB)
        }
        let model = AppModel()
        defer { model.endPreview() }
        model.attachPreview(host: "127.0.0.1", port: primary.port)
        #expect(await wait { model.connected })
        model.addManualPlayer("127.0.0.1:\(secondary.port)")
        let player = model.players.first { $0.port == secondary.port }
        #expect(player != nil)
        guard let player else { return }
        let before = primary.loggedPaths()
        #expect(!before.contains { $0.hasPrefix("/AddSlave") })
        model.toggleGroup(player)
        let added = await wait { model.slaves.contains { $0.host == "127.0.0.1" && $0.port == secondary.port } }
        #expect(added)
        #expect(model.groupCaption == "+ 127.0.0.1")
        #expect(model.playerIsGrouped(player))
        #expect(model.lastError == nil)
        model.toggleGroup(player)
        let removed = await wait { model.slaves.isEmpty }
        #expect(removed)
        #expect(model.groupCaption.isEmpty)
        let paths = primary.loggedPaths()
        #expect(paths.filter { $0.hasPrefix("/AddSlave") }.count == 1)
        #expect(paths.filter { $0.hasPrefix("/RemoveSlave") }.count == 1)
        #expect(paths.contains { $0.contains("slave=127.0.0.1") && $0.contains("port=\(secondary.port)") })
        #expect(!paths.contains { $0.hasPrefix("/Volume") })
        #expect(!paths.contains { $0.hasPrefix("/Stop") })
        #expect(secondary.loggedPaths().filter { $0.hasPrefix("/AddSlave") || $0.hasPrefix("/RemoveSlave") }.isEmpty)
    }

    @Test func groupErrorStaysVisibleAndDoesNotJoin() async throws {
        let snap = DefaultsSnap()
        defer { snap.restore() }
        let logA = FileManager.default.temporaryDirectory.appendingPathComponent("nd-ge-\(UUID().uuidString).log")
        let primary = try await MockServer.launch(logURL: logA)
        defer {
            primary.stop()
            try? FileManager.default.removeItem(at: logA)
        }
        let secondary = try await MockServer.launch()
        defer { secondary.stop() }
        let model = AppModel()
        defer { model.endPreview() }
        model.attachPreview(host: "127.0.0.1", port: primary.port)
        #expect(await wait { model.connected })
        var arm = URLRequest(url: URL(string: "http://127.0.0.1:\(primary.port)/_x?slavefail=1")!)
        arm.timeoutInterval = 2
        _ = try await URLSession.shared.data(for: arm)
        let player = KnownPlayer(name: "Kitchen", host: "127.0.0.1", port: secondary.port, manual: true)
        model.toggleGroup(player)
        let failed = await wait { model.lastError == "Group failed: refused" }
        #expect(failed)
        #expect(model.slaves.isEmpty)
        #expect(model.groupCaption.isEmpty)
        #expect(model.host == "127.0.0.1")
        #expect(model.port == primary.port)
        let sync = try await primary.client().syncStatus()
        #expect(sync.slaves.isEmpty)
    }

    @Test func toggleGroupOnTheActivePlayerSendsNothing() async throws {
        let snap = DefaultsSnap()
        defer { snap.restore() }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("nd-self-\(UUID().uuidString).log")
        let primary = try await MockServer.launch(logURL: logURL)
        defer {
            primary.stop()
            try? FileManager.default.removeItem(at: logURL)
        }
        let model = AppModel()
        defer { model.endPreview() }
        model.attachPreview(host: "127.0.0.1", port: primary.port)
        #expect(await wait { model.connected })
        let active = KnownPlayer(name: "Here", host: "127.0.0.1", port: primary.port, manual: false)
        model.toggleGroup(active)
        try await Task.sleep(nanoseconds: 300_000_000)
        let paths = primary.loggedPaths()
        #expect(!paths.contains { $0.hasPrefix("/AddSlave") })
        #expect(!paths.contains { $0.hasPrefix("/RemoveSlave") })
        #expect(model.slaves.isEmpty)
    }

    @Test func switchDuringAddDoesNotContinueOnTheNewPlayer() async throws {
        let snap = DefaultsSnap()
        defer { snap.restore() }
        let logA = FileManager.default.temporaryDirectory.appendingPathComponent("nd-add-a-\(UUID().uuidString).log")
        let logB = FileManager.default.temporaryDirectory.appendingPathComponent("nd-add-b-\(UUID().uuidString).log")
        let primary = try await MockServer.launch(logURL: logA, environment: ["FAKE_LAT": "250"])
        defer {
            primary.stop()
            try? FileManager.default.removeItem(at: logA)
        }
        let secondary = try await MockServer.launch(logURL: logB)
        defer {
            secondary.stop()
            try? FileManager.default.removeItem(at: logB)
        }
        let model = AppModel()
        defer { model.endPreview() }
        model.attachPreview(host: "127.0.0.1", port: primary.port)
        #expect(await wait { model.connected })
        let album = BrowseItem(type: "album", text: "Alpha", browseKey: "ALB:0", contextMenuKey: "")
        model.addToQueue(album, now: false)
        let started = await wait {
            primary.loggedPaths().contains { $0.contains("ALB%3A0") }
        }
        #expect(started)
        model.setPlayer(host: "127.0.0.1", port: secondary.port)
        let moved = await wait(seconds: 8) {
            model.port == secondary.port && model.connected && !model.status.title.isEmpty
        }
        #expect(moved)
        try await Task.sleep(nanoseconds: 700_000_000)
        let paths = secondary.loggedPaths()
        #expect(!paths.contains { $0.hasPrefix("/Add") })
        #expect(!paths.contains { $0.hasPrefix("/Volume") })
        #expect(!paths.contains { $0.hasPrefix("/Stop") })
    }

    @Test func emptyQueueIsNotFetchedAgainOnTheNextStatus() async throws {
        let snap = DefaultsSnap()
        defer { snap.restore() }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("nd-q-\(UUID().uuidString).log")
        let mock = try await MockServer.launch(logURL: logURL)
        defer {
            mock.stop()
            try? FileManager.default.removeItem(at: logURL)
        }
        let model = AppModel()
        defer { model.endPreview() }
        model.attachPreview(host: "127.0.0.1", port: mock.port)
        #expect(await wait { model.connected && model.queue.count == 4 })
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?resetq=0")!)
        reset.timeoutInterval = 2
        _ = try await URLSession.shared.data(for: reset)
        let emptied = await wait { model.queue.isEmpty }
        #expect(emptied)
        guard emptied else { return }
        let afterEmpty = mock.loggedPaths().filter { $0.hasPrefix("/Playlist") }.count
        #expect(afterEmpty >= 1)
        try await Task.sleep(nanoseconds: 2_300_000_000)
        var pause = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?state=pause")!)
        pause.timeoutInterval = 2
        _ = try await URLSession.shared.data(for: pause)
        #expect(await wait { model.status.state == .pause })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(mock.loggedPaths().filter { $0.hasPrefix("/Playlist") }.count == afterEmpty)
    }

    @Test func missingSavedHostStaysDisconnected() async throws {
        let snap = DefaultsSnap()
        defer { snap.restore() }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "nightdeck.host")
        defaults.removeObject(forKey: "nightdeck.port")
        #expect(NightdeckDefaults.host.isEmpty)
        let model = AppModel()
        defer { model.endPreview() }
        #expect(model.host.isEmpty)
        #expect(!model.connected)
        guard model.host.isEmpty else { return }
        model.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(model.host.isEmpty)
        #expect(!model.connected)
    }

    private func wait(seconds: Double = 5, until body: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if body() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return body()
    }
}

private struct DefaultsSnap {
    let keys = [
        "nightdeck.host", "nightdeck.port", "nightdeck.manualPlayers",
        "nightdeck.menuBar", "nightdeck.sleepFade", "nightdeck.sleepFadeSeconds",
        "nightdeck.sleepEndStop",
    ]
    let values: [String: Any]

    init() {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        self.values = values
    }

    func restore() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}
