import Darwin
import Foundation
import Testing
@testable import NightdeckCore

struct MockServer {
    let port: Int
    let process: Process
    let logURL: URL?

    static func launch(logURL: URL? = nil, environment: [String: String] = [:]) async throws -> MockServer {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/mock_bluos.py")
        let port = try reserveLoopbackPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if logURL != nil || !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            if let logURL { env["FAKE_LOG"] = logURL.path }
            for (key, value) in environment { env[key] = value }
            process.environment = env
        }
        try process.run()
        let server = MockServer(port: port, process: process, logURL: logURL)
        try await server.waitUntilUp()
        return server
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func client() -> HTTPBluOSClient {
        HTTPBluOSClient(host: "127.0.0.1", port: port)
    }

    func loggedPaths() -> [String] {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func waitUntilUp() async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/SyncStatus")!)
            request.timeoutInterval = 0.4
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return
            }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        stop()
        throw BluOSError.player("mock server did not start")
    }
}

private func reserveLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BluOSError.player("socket") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw BluOSError.player("bind") }
    var got = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &got) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }
    guard named == 0 else { throw BluOSError.player("getsockname") }
    return Int(UInt16(bigEndian: got.sin_port))
}

@Test func clientReadsStatusPlaylistBrowseAndPresets() async throws {
    let mock = try await MockServer.launch()
    defer { mock.stop() }
    let client = mock.client()
    let status = try await client.status(timeout: nil, etag: nil)
    #expect(status.state == .play)
    #expect(status.title == "Track 1")
    #expect(status.volume == 40)
    #expect(!status.etag.isEmpty)
    #expect(status.imagePath.contains("Artwork"))
    #expect(status.total == 200)
    let art = try await client.fetchData(status.imagePath)
    #expect(art.starts(with: Data("GIF89a".utf8)))
    let playlist = try await client.playlist()
    #expect(playlist.songs.count == 4)
    #expect(playlist.songs[0].title == "Track 1")
    let page = try await client.browse(key: "LocalMusic:", query: nil)
    #expect(page.searchKey == "LocalMusic:Search")
    #expect(page.items.contains { $0.text == "Artists" })
    let presets = try await client.presets()
    #expect(presets.count == 2)
    let volume = try await client.setVolume(level: 55)
    #expect(volume.level == 55)
    let again = try await client.status(timeout: nil, etag: nil)
    #expect(again.volume == 55)
}

@Test func errorDocumentIsNotASuccessfulSleepOrVolumeChange() async throws {
    let mock = try await MockServer.launch()
    defer { mock.stop() }
    let client = mock.client()
    var arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?failnext=1")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    do {
        _ = try await client.sleep()
        Issue.record("sleep accepted an error document")
    } catch let error as BluOSError {
        #expect(error == .player("refused"))
    }
    arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?failnext=1")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    do {
        _ = try await client.setVolume(level: 10)
        Issue.record("volume accepted an error document")
    } catch let error as BluOSError {
        #expect(error == .player("refused"))
    }
    let status = try await client.status(timeout: nil, etag: nil)
    #expect(status.volume == 40)
}

@Test func longPollWakesWhenTheMockChangesState() async throws {
    let mock = try await MockServer.launch()
    defer { mock.stop() }
    let client = mock.client()
    let first = try await client.status(timeout: nil, etag: nil)
    let pending = Task { try await client.status(timeout: 60, etag: first.etag) }
    try await Task.sleep(nanoseconds: 150_000_000)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?state=pause")!)
    request.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: request)
    let next = try await pending.value
    #expect(next.state == .pause)
    #expect(next.etag != first.etag)
}

@Test func emptyOrUserinfoHostFailsBeforeTheNetwork() async throws {
    let clock = ContinuousClock()
    let started = clock.now
    let client = HTTPBluOSClient(host: "", port: 11000)
    do {
        _ = try await client.status(timeout: 30, etag: nil)
        Issue.record("empty host made a request")
    } catch let error as BluOSError {
        #expect(error == .badURL)
    }
    #expect(clock.now - started < .seconds(1))
    let tagged = HTTPBluOSClient(host: "user@10.0.0.2", port: 11000)
    do {
        _ = try await tagged.status(timeout: 30, etag: nil)
        Issue.record("userinfo host made a request")
    } catch let error as BluOSError {
        #expect(error == .badURL)
    }
}

@Test func savePlaylistEncodesAPlus() async throws {
    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("nd-plus-\(UUID().uuidString).log")
    let mock = try await MockServer.launch(logURL: logURL)
    defer {
        mock.stop()
        try? FileManager.default.removeItem(at: logURL)
    }
    let entries = try await mock.client().savePlaylist(name: "C++")
    #expect(entries == 4)
    #expect(mock.loggedPaths().contains { $0.contains("name=C%2B%2B") })
}
