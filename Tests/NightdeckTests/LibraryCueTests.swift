import Foundation
import Testing
@testable import Nightdeck
@testable import NightdeckCore

@Test func nowPlayingMatchUsesStatusSongAlbumAndFile() {
    let track = BrowseItem(
        type: "track",
        text: "01 Alpha t1",
        playURL: "/Add?playnow=1&file=/mnt/music/Alpha/01%20Alpha%20t1.flac"
    )
    let playing = PlayerStatus(
        state: .play,
        title: "Other title",
        artist: "Added Artist",
        album: "Added Album",
        file: "/mnt/music/Alpha/01 Alpha t1.flac"
    )
    #expect(NowPlayingMatch.matches(track, status: playing))

    let sameTitle = PlayerStatus(
        state: .play,
        title: "01 Alpha t1",
        file: "/mnt/music/Other/01 Alpha t1.flac"
    )
    #expect(!NowPlayingMatch.matches(track, status: sameTitle))

    let named = BrowseItem(type: "track", text: "Song", text2: "Artist")
    let byTitle = PlayerStatus(state: .pause, title: "Song", artist: "Artist", album: "Album")
    #expect(NowPlayingMatch.matches(named, status: byTitle))
    let wrongArtist = PlayerStatus(state: .play, title: "Song", artist: "Someone", album: "Album")
    #expect(!NowPlayingMatch.matches(named, status: wrongArtist))

    var stopped = byTitle
    stopped.state = .stop
    #expect(!NowPlayingMatch.matches(named, status: stopped))

    let album = BrowseItem(type: "album", text: "Alpha", text2: "Artist 0")
    let tagged = PlayerStatus(state: .play, title: "01 Alpha t1", artist: "Artist 0", album: "Alpha")
    #expect(NowPlayingMatch.matches(album, status: tagged))
    let otherArtist = PlayerStatus(state: .play, title: "01 Alpha t1", artist: "Someone", album: "Alpha")
    #expect(!NowPlayingMatch.matches(album, status: otherArtist))

    let fromFolder = PlayerStatus(
        state: .stream,
        title: "01 Alpha t1",
        artist: "Added Artist",
        album: "Added Album",
        file: "/mnt/music/Alpha/01 Alpha t1.flac"
    )
    #expect(NowPlayingMatch.matches(album, status: fromFolder))

    let artist = BrowseItem(type: "artist", text: "Artist 0")
    #expect(NowPlayingMatch.matches(artist, status: tagged))
    #expect(!NowPlayingMatch.matches(artist, status: fromFolder))
}

@Suite(.serialized)
@MainActor
struct LibraryCueTests {
    @Test func addSuccessShowsACheckThenReturnsToIdle() async throws {
        let harness = try await CueHarness.open()
        defer { harness.close() }
        let track = try await harness.track()
        let loaded = await harness.wait { harness.model.queue.count == 4 }
        #expect(loaded, "queue=\(harness.model.queue.count)")
        let before = harness.model.queue.count
        harness.model.addToQueue(track, now: false)
        #expect(harness.model.libraryAddCue(for: track) == .pending)
        harness.model.addToQueue(track, now: false)
        let added = await harness.wait {
            harness.model.libraryAddCue(for: track) == .added
        }
        #expect(added)
        #expect(harness.model.libraryNote == .confirmation("Added to queue: \(track.text)"))
        #expect(harness.model.libraryPlayCue(for: track) == .idle)
        #expect(harness.model.queue.count == before + 1)
        #expect(harness.addCount() == 1, "paths: \(harness.mock.loggedPaths().joined(separator: " "))")
        let cleared = await harness.wait(seconds: LibraryFeedbackTiming.addConfirmSeconds + 1.2) {
            harness.model.libraryAddCue(for: track) == .idle
        }
        #expect(cleared)
        #expect(harness.model.libraryNote == .confirmation("Added to queue: \(track.text)"))
        #expect(harness.addCount() == 1)
    }

    @Test func addFailureKeepsThePlusAndShowsTheError() async throws {
        let harness = try await CueHarness.open()
        defer { harness.close() }
        let track = try await harness.track()
        let loaded = await harness.wait { harness.model.queue.count == 4 }
        #expect(loaded, "queue=\(harness.model.queue.count)")
        let before = harness.model.queue.count
        try await harness.control("addfail=1")
        harness.model.addToQueue(track, now: false)
        #expect(harness.model.libraryAddCue(for: track) == .pending)
        let failed = await harness.wait {
            harness.model.libraryAddCue(for: track) == .idle
                && harness.model.libraryNote == .failure("add refused")
        }
        #expect(failed, "cue=\(harness.model.libraryAddCue(for: track)) note=\(String(describing: harness.model.libraryNote))")
        #expect(harness.model.queue.count == before)
        #expect(harness.model.lastError == "add refused")
    }

    @Test func nothingQueuedIsAFailureWithoutACheck() async throws {
        let harness = try await CueHarness.open()
        defer { harness.close() }
        let ghost = BrowseItem(type: "track", text: "Ghost")
        let adds = harness.addCount()
        harness.model.addToQueue(ghost, now: false)
        let failed = await harness.wait {
            harness.model.libraryAddCue(for: ghost) == .idle
                && harness.model.libraryNote == .failure("Nothing was added")
        }
        #expect(failed, "note=\(String(describing: harness.model.libraryNote))")
        #expect(harness.model.lastError == nil)
        #expect(harness.addCount() == adds)
    }

    @Test func playSuccessStaysAmberWhileThatSongIsCurrent() async throws {
        let harness = try await CueHarness.open()
        defer { harness.close() }
        let track = try await harness.track()
        let current = BrowseItem(type: "album", text: "Queue Album", text2: "Queue Artist")
        #expect(harness.model.status.album == "Queue Album")
        #expect(harness.model.libraryPlayCue(for: current) == .playing)
        #expect(harness.model.libraryPlayCue(for: track) == .idle)
        harness.model.addToQueue(track, now: true)
        #expect(harness.model.libraryPlayCue(for: track) == .pending)
        let playing = await harness.wait {
            harness.model.status.title == track.text && harness.model.libraryPlayCue(for: track) == .playing
        }
        #expect(playing, "title=\(harness.model.status.title) cue=\(harness.model.libraryPlayCue(for: track))")
        #expect(harness.model.libraryNote?.isFailure != true)
        let hold = LibraryFeedbackTiming.playHoldSeconds + 0.5
        try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        #expect(harness.model.status.title == track.text)
        #expect(harness.model.libraryPlayCue(for: track) == .playing)
        #expect(harness.model.libraryPlayCue(for: current) == .idle)
        try await harness.control("song=0")
        let reverted = await harness.wait {
            harness.model.status.title == "Track 1" && harness.model.libraryPlayCue(for: track) == .idle
        }
        #expect(reverted, "title=\(harness.model.status.title) cue=\(harness.model.libraryPlayCue(for: track))")
        #expect(harness.model.libraryPlayCue(for: current) == .playing)
    }

    @Test func playFailureLeavesTheSymbolAndShowsTheError() async throws {
        let harness = try await CueHarness.open()
        defer { harness.close() }
        let track = try await harness.track()
        try await harness.control("addfail=1")
        harness.model.addToQueue(track, now: true)
        #expect(harness.model.libraryPlayCue(for: track) == .pending)
        let failed = await harness.wait {
            harness.model.libraryPlayCue(for: track) == .idle
                && harness.model.libraryNote == .failure("add refused")
        }
        #expect(failed, "cue=\(harness.model.libraryPlayCue(for: track)) note=\(String(describing: harness.model.libraryNote))")
        #expect(harness.model.libraryAddCue(for: track) == .idle)
        #expect(harness.model.status.title == "Track 1")
    }
}

@MainActor
private struct CueHarness {
    let mock: MockServer
    let model: AppModel
    let logURL: URL

    static func open() async throws -> CueHarness {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nightdeck-cue-\(UUID().uuidString).log")
        let mock = try await MockServer.launch(logURL: logURL)
        let model = AppModel()
        model.attachPreview(host: "127.0.0.1", port: mock.port)
        let connected = await wait(seconds: 4) { model.connected && model.status.title == "Track 1" }
        if !connected {
            model.endPreview()
            mock.stop()
            throw CueTestError.offline
        }
        return CueHarness(mock: mock, model: model, logURL: logURL)
    }

    func close() {
        model.endPreview()
        mock.stop()
        try? FileManager.default.removeItem(at: logURL)
    }

    func track() async throws -> BrowseItem {
        let page = try #require(await model.browse(key: "ALB:0"))
        return try #require(page.items.first { $0.type == "track" })
    }

    func control(_ query: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?\(query)")!)
        request.timeoutInterval = 2
        _ = try await URLSession.shared.data(for: request)
    }

    func addCount() -> Int {
        mock.loggedPaths().filter { path in
            path.split(separator: "?", maxSplits: 1).first.map(String.init) == "/Add"
        }.count
    }

    func wait(seconds: Double = 5, until ready: @MainActor () -> Bool) async -> Bool {
        await Self.wait(seconds: seconds, until: ready)
    }

    private static func wait(seconds: Double, until ready: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ready() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ready()
    }
}

private enum CueTestError: Error {
    case offline
}
