import Foundation
import Testing
@testable import Nightdeck
@testable import NightdeckCore

@Suite(.serialized)
@MainActor
struct OfflineRecoveryTests {
    @Test func offlineFailureThenStatusClearsTheError() async {
        let player = ScriptedPlayer()
        player.blockStatusAfter = 1
        player.statusResult = .success(playing())
        player.playlistResult = .success(songs(1))
        let model = AppModel()
        defer {
            player.hold.release()
            model.endPreview()
        }
        model.setRecoveryTiming(settle: 0.05, pauses: [0, 0.05, 0.05])
        model.attachClient(player, host: "127.0.0.1", port: 9)
        let ready = await wait {
            model.connected && model.queue.count == 1 && player.calls("status") >= 2
        }
        #expect(ready)
        guard ready else { return }
        player.playlistResult = .failure(URLError(.notConnectedToInternet))
        model.refreshQueue()
        let showed = await wait { model.lastError != nil }
        #expect(showed)
        #expect(model.connected)
        #expect(model.lastError == "Player not reachable (network not ready)")
        #expect(model.lastError?.localizedCaseInsensitiveContains("internet") == false)
        #expect(URLError(.notConnectedToInternet).code.rawValue == -1009)
        player.statusResult = .success(playing(title: "After"))
        player.hold.release()
        let cleared = await wait { model.status.title == "After" && model.lastError == nil }
        #expect(cleared)
        #expect(model.connected)
        #expect(model.queue.count == 1)
        #expect(player.writes.isEmpty)
    }

    @Test func queueEmptyErrorSurvivesTheNextStatus() async {
        let player = ScriptedPlayer()
        player.blockStatusAfter = 1
        player.statusResult = .success(playing(title: "Idle", song: -1))
        player.playlistResult = .success(Playlist(id: "pl", songs: []))
        let model = AppModel()
        defer {
            player.hold.release()
            model.endPreview()
        }
        model.setRecoveryTiming(settle: 0.05, pauses: [0, 0.05, 0.05])
        model.attachClient(player, host: "127.0.0.1", port: 9)
        let ready = await wait {
            model.connected && model.queue.isEmpty && player.calls("status") >= 2
        }
        #expect(ready)
        guard ready else { return }
        let saved = await model.saveQueue(named: "Night")
        #expect(!saved)
        #expect(model.lastError == "The queue is empty")
        player.statusResult = .success(playing(title: "After", song: -1))
        player.hold.release()
        let applied = await wait { model.status.title == "After" }
        #expect(applied)
        #expect(model.lastError == "The queue is empty")
        #expect(model.connected)
        #expect(player.writes.isEmpty)
    }

    @Test func networkMessagesNeverSayInternet() {
        let host = "10.0.0.9"
        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "Player not reachable (network not ready)"),
            (.networkConnectionLost, "Player not reachable (network not ready)"),
            (.cannotConnectToHost, "Player not reachable at \(host)"),
            (.cannotFindHost, "Player not reachable at \(host)"),
            (.dnsLookupFailed, "Player not reachable at \(host)"),
            (.timedOut, "Player timed out"),
        ]
        for (code, expected) in cases {
            let error = URLError(code)
            let text = PlayerMessages.text(for: error, host: host)
            #expect(text == expected)
            #expect(!text.localizedCaseInsensitiveContains("internet"))
            #expect(PlayerMessages.describe(error, host: host) == expected)
            #expect(PlayerMessages.isNetwork(error))
        }
        let offline = URLError(.notConnectedToInternet)
        #expect(offline.code.rawValue == -1009)
        #expect(PlayerMessages.describe(offline, host: host) != offline.localizedDescription)
        let bridged = NSError(domain: NSURLErrorDomain, code: offline.code.rawValue)
        #expect(PlayerMessages.describe(bridged, host: host) == "Player not reachable (network not ready)")
        #expect(PlayerMessages.describe(BluOSError.player("refused"), host: host) == "refused")
        #expect(!PlayerMessages.isNetwork(BluOSError.player("refused")))
        #expect(PlayerMessages.describe(BluOSError.timeout, host: host) == "The player did not answer in time")
        #expect(PlayerMessages.isNetwork(BluOSError.timeout))
        #expect(PlayerMessages.isNetwork(BluOSError.unreachable("Player not reachable")))
        let timing = NetworkRecoveryTiming()
        #expect(timing.settle >= 1 && timing.settle <= 2)
        #expect(timing.pauses == [0, 2, 2])
    }

    @Test func clientMapsOfflineWithoutSayingInternet() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineURLProtocol.self]
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        let client = HTTPBluOSClient(host: "127.0.0.1", port: 9, session: session)
        OfflineURLProtocol.code = .notConnectedToInternet
        do {
            _ = try await client.status(timeout: nil, etag: nil)
            Issue.record("status reached a player")
        } catch let error as BluOSError {
            #expect(error == .unreachable("Player not reachable (network not ready)"))
            #expect(!error.description.localizedCaseInsensitiveContains("internet"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        OfflineURLProtocol.code = .cannotConnectToHost
        do {
            _ = try await client.playlist()
            Issue.record("playlist reached a player")
        } catch let error as BluOSError {
            #expect(error.description == "Player not reachable at 127.0.0.1")
            #expect(!error.description.localizedCaseInsensitiveContains("internet"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        OfflineURLProtocol.code = .timedOut
        do {
            _ = try await client.syncStatus()
            Issue.record("sync reached a player")
        } catch let error as BluOSError {
            #expect(error.description == "Player timed out")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func wakeAndPathSatisfiedReloadTheVisibleView() async {
        let previous = ShellUI.shared.section
        defer {
            ShellUI.shared.section = previous
            LibraryUI.shared.resetSession()
        }
        let player = ScriptedPlayer()
        player.blockStatusAfter = 10_000
        player.statusResult = .success(playing())
        player.playlistResult = .success(songs(2))
        player.browseResult = .success(BrowsePage(serviceName: "Library", items: [
            BrowseItem(type: "link", text: "Albums", browseKey: "LocalMusic:Albums"),
        ]))
        let model = AppModel()
        defer { model.endPreview() }
        model.setRecoveryTiming(settle: 0.05, pauses: [0, 0.05, 0.05])
        model.attachClient(player, host: "127.0.0.1", port: 9)
        let ready = await wait { model.connected && model.queue.count == 2 }
        #expect(ready)
        guard ready else { return }
        model.noteNetworkPath(satisfied: true)

        ShellUI.shared.section = .queue
        let playlists = player.calls("playlist")
        let statuses = player.calls("status")
        model.noteSystemWake()
        let woke = await wait {
            player.calls("playlist") > playlists && player.calls("status") > statuses
        }
        #expect(woke, "log=\(player.entries())")
        #expect(player.writes.isEmpty)

        LibraryUI.shared.resetSession()
        ShellUI.shared.section = .library
        let browses = player.calls("browse")
        model.noteNetworkPath(satisfied: false)
        model.noteNetworkPath(satisfied: true)
        let refreshed = await wait { player.calls("browse") > browses }
        #expect(refreshed, "log=\(player.entries())")
        #expect(player.writes.isEmpty)
        #expect(model.host == "127.0.0.1")
    }

    private func wait(seconds: Double = 4, until ready: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ready() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ready()
    }
}

private func playing(title: String = "Track", song: Int = 0) -> PlayerStatus {
    PlayerStatus(
        etag: "e1",
        state: .play,
        title: title,
        seconds: 3,
        total: 200,
        song: song,
        playlistID: "pl",
        canSeek: true
    )
}

private func songs(_ count: Int) -> Playlist {
    Playlist(
        id: "pl",
        songs: (0..<count).map { index in
            QueueSong(id: index, title: "Track \(index)", artist: "A", album: "B", file: "f\(index)", seconds: 200)
        }
    )
}

private final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    func wait() async {
        while !Task.isCancelled {
            if isOpen() { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func isOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func release() {
        lock.lock()
        open = true
        lock.unlock()
    }
}

/// Stand-in player. Records every call and never opens a socket.
private final class ScriptedPlayer: BluOSClient, @unchecked Sendable {
    let hold = Hold()
    var blockStatusAfter = 1
    var statusResult: Result<PlayerStatus, Error> = .success(PlayerStatus())
    var playlistResult: Result<Playlist, Error> = .success(Playlist(id: "", songs: []))
    var browseResult: Result<BrowsePage, Error> = .success(BrowsePage())

    private let lock = NSLock()
    private var log: [String] = []
    private let readNames: Set<String> = ["status", "playlist", "browse", "sync", "presets", "data"]

    func calls(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return log.filter { $0 == name }.count
    }

    func entries() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var writes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log.filter { !readNames.contains($0) }
    }

    func status(timeout: Int?, etag: String?) async throws -> PlayerStatus {
        let n = record("status")
        let block = locked { blockStatusAfter }
        if n > block { await hold.wait() }
        return try locked { statusResult }.get()
    }

    func playlist() async throws -> Playlist {
        record("playlist")
        return try locked { playlistResult }.get()
    }

    func browse(key: String, query: String?) async throws -> BrowsePage {
        record("browse")
        return try locked { browseResult }.get()
    }

    func perform(_ path: String) async throws { record("perform") }
    func play(id: Int?) async throws { record("play") }
    func seek(_ seconds: Int) async throws { record("seek") }
    func pause(toggle: Bool) async throws { record("pause") }
    func stop() async throws { record("stop") }
    func skip() async throws { record("skip") }
    func back() async throws { record("back") }
    func setVolume(level: Int) async throws -> VolumeState {
        record("volume")
        return VolumeState(level: level, db: "", mute: false, muteDB: "")
    }
    func setMute(_ on: Bool) async throws -> VolumeState {
        record("mute")
        return VolumeState(level: -1, db: "", mute: on, muteDB: "")
    }
    func setShuffle(_ on: Bool) async throws { record("shuffle") }
    func setRepeat(_ mode: RepeatMode) async throws { record("repeat") }
    func deleteSong(id: Int) async throws { record("delete") }
    func clearQueue() async throws { record("clear") }
    func moveSong(from old: Int, to new: Int) async throws { record("move") }
    func sleep() async throws -> Int { record("sleep"); return 0 }
    func presets() async throws -> [Preset] { record("presets"); return [] }
    func playPreset(id: String) async throws { record("preset") }
    func savePlaylist(name: String) async throws -> Int { record("save"); return 0 }
    func deletePlaylist(name: String) async throws { record("delete") }
    func fetchData(_ pathOrURL: String) async throws -> Data { record("data"); return Data() }
    func syncStatus() async throws -> SyncStatus { record("sync"); return SyncStatus() }
    func addSlave(host: String, port: Int) async throws { record("addSlave") }
    func removeSlave(host: String, port: Int) async throws { record("removeSlave") }

    @discardableResult
    private func record(_ name: String) -> Int {
        locked {
            log.append(name)
            return log.filter { $0 == name }.count
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var code: URLError.Code = .notConnectedToInternet

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(Self.code))
    }

    override func stopLoading() {}
}
