import Foundation

public final class HTTPBluOSClient: BluOSClient, @unchecked Sendable {
    private let lock = NSLock()
    private var host: String
    private var port: Int
    private let session: URLSession

    public init(host: String, port: Int, session: URLSession? = nil) {
        self.host = host
        self.port = port
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 90
            cfg.timeoutIntervalForResource = 100
            cfg.waitsForConnectivity = false
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            cfg.httpShouldSetCookies = false
            cfg.httpCookieStorage = nil
            cfg.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: cfg)
        }
    }

    public func setEndpoint(host: String, port: Int) {
        lock.lock()
        self.host = host
        self.port = port
        lock.unlock()
    }

    public func status(timeout: Int?, etag: String?) async throws -> PlayerStatus {
        var items: [URLQueryItem] = []
        if let timeout, let etag, !etag.isEmpty {
            items.append(URLQueryItem(name: "timeout", value: String(timeout)))
            items.append(URLQueryItem(name: "etag", value: etag))
        }
        let limit: TimeInterval = items.isEmpty ? 8 : 75
        let data = try await request(path: "/Status", query: items, timeout: limit)
        guard let status = BluOSXML.parseStatus(text(data)) else { throw BluOSError.invalidResponse }
        return status
    }

    public func playlist() async throws -> Playlist {
        let data = try await request(path: "/Playlist", timeout: 8)
        guard let playlist = BluOSXML.parsePlaylist(text(data)) else { throw BluOSError.invalidResponse }
        return playlist
    }

    public func browse(key: String, query: String?) async throws -> BrowsePage {
        let data = try await request(path: BluOSURL.browsePath(key: key, query: query), timeout: 12)
        if let detail = BluOSXML.errorDetail(text(data)) { throw BluOSError.player(detail) }
        guard let page = BluOSXML.parseBrowse(text(data)) else { throw BluOSError.invalidResponse }
        return page
    }

    public func perform(_ path: String) async throws {
        let data = try await request(path: path, timeout: 8)
        if let detail = BluOSXML.errorDetail(text(data)) { throw BluOSError.player(detail) }
    }

    public func play(id: Int?) async throws {
        if let id { try await perform("/Play?id=\(id)") }
        else { try await perform("/Play") }
    }

    public func seek(_ seconds: Int) async throws {
        let clamped = max(0, seconds)
        try await perform("/Play?seek=\(clamped)")
    }

    public func pause(toggle: Bool) async throws {
        try await perform(toggle ? "/Pause?toggle=1" : "/Pause")
    }

    public func stop() async throws { try await perform("/Stop") }
    public func skip() async throws { try await perform("/Skip") }
    public func back() async throws { try await perform("/Back") }

    public func setVolume(level: Int) async throws -> VolumeState {
        let data = try await checked(path: "/Volume", query: [URLQueryItem(name: "level", value: String(level))], timeout: 8)
        return BluOSXML.parseVolume(text(data)) ?? VolumeState(level: level, db: "", mute: false, muteDB: "")
    }

    public func setMute(_ on: Bool) async throws -> VolumeState {
        let data = try await checked(
            path: "/Volume",
            query: [URLQueryItem(name: "mute", value: on ? "1" : "0")],
            timeout: 8
        )
        return BluOSXML.parseVolume(text(data)) ?? VolumeState(level: -1, db: "", mute: on, muteDB: "")
    }

    public func setShuffle(_ on: Bool) async throws {
        try await perform("/Shuffle?state=\(on ? 1 : 0)")
    }

    public func setRepeat(_ mode: RepeatMode) async throws {
        let raw = mode == .unknown ? RepeatMode.off.rawValue : mode.rawValue
        try await perform("/Repeat?state=\(raw)")
    }

    public func deleteSong(id: Int) async throws { try await perform("/Delete?id=\(id)") }
    public func clearQueue() async throws { try await perform("/Clear") }

    public func moveSong(from old: Int, to new: Int) async throws {
        try await perform("/Move?old=\(old)&new=\(new)")
    }

    public func sleep() async throws -> Int {
        let data = try await checked(path: "/Sleep", timeout: 8)
        let raw = BluOSXML.elementText(text(data), named: "sleep") ?? ""
        return max(0, Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    public func presets() async throws -> [Preset] {
        let data = try await checked(path: "/Presets", timeout: 8)
        return BluOSXML.parsePresets(text(data))
    }

    public func playPreset(id: String) async throws {
        let data = try await request(path: "/Preset", query: [URLQueryItem(name: "id", value: id)], timeout: 8)
        if let detail = BluOSXML.errorDetail(text(data)) { throw BluOSError.player(detail) }
    }

    public func savePlaylist(name: String) async throws -> Int {
        let data = try await request(path: "/Save", query: [URLQueryItem(name: "name", value: name)], timeout: 8)
        if let detail = BluOSXML.errorDetail(text(data)) { throw BluOSError.player(detail) }
        return Int(BluOSXML.elementText(text(data), named: "entries") ?? "") ?? 0
    }

    public func deletePlaylist(name: String) async throws {
        _ = try await checked(
            path: "/Delete",
            query: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "service", value: "BluOS")],
            timeout: 8
        )
    }

    public func fetchData(_ pathOrURL: String) async throws -> Data {
        let data = try await request(path: pathOrURL, timeout: 15)
        if let prefix = String(data: data.prefix(80), encoding: .utf8), prefix.contains("<error"),
           let detail = BluOSXML.errorDetail(text(data)) {
            throw BluOSError.player(detail)
        }
        return data
    }

    public func syncStatus() async throws -> SyncStatus {
        let data = try await checked(path: "/SyncStatus", timeout: 8)
        guard let status = BluOSXML.parseSyncStatus(text(data)) else { throw BluOSError.invalidResponse }
        return status
    }

    public func addSlave(host: String, port: Int) async throws {
        try await groupSlave(path: "/AddSlave", host: host, port: port)
    }

    public func removeSlave(host: String, port: Int) async throws {
        try await groupSlave(path: "/RemoveSlave", host: host, port: port)
    }

    private func groupSlave(path: String, host: String, port: Int) async throws {
        _ = try await checked(
            path: path,
            query: [
                URLQueryItem(name: "slave", value: host),
                URLQueryItem(name: "port", value: String(port)),
            ],
            timeout: 8
        )
    }

    private func checked(path: String, query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> Data {
        let data = try await request(path: path, query: query, timeout: timeout)
        if let detail = BluOSXML.errorDetail(text(data)) { throw BluOSError.player(detail) }
        return data
    }

    private func endpoint() -> (String, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (host, port)
    }

    private func request(path: String, query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> Data {
        let (host, port) = endpoint()
        guard !host.isEmpty, !host.contains("@") else { throw BluOSError.badURL }
        let url: URL?
        if query.isEmpty {
            url = BluOSURL.resolve(host: host, port: port, pathOrURL: path)
        } else {
            // URLComponents leaves "+" raw. BluOS decodes once, so "+" must be %2B.
            let encoded = query.map { item in
                BluOSURL.queryEncode(item.name) + "=" + BluOSURL.queryEncode(item.value ?? "")
            }.joined(separator: "&")
            let joiner = path.contains("?") ? "&" : "?"
            url = BluOSURL.resolve(host: host, port: port, pathOrURL: path + joiner + encoded)
        }
        guard let url else { throw BluOSError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Nightdeck/1.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw BluOSError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw BluOSError.http(http.statusCode) }
            return data
        } catch let error as BluOSError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            let (host, _) = endpoint()
            throw BluOSError.unreachable(PlayerMessages.text(for: error, host: host))
        }
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

}
