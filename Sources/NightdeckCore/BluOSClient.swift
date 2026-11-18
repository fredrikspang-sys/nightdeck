import Foundation

public enum BluOSError: Error, Sendable, Equatable, CustomStringConvertible {
    case timeout
    case http(Int)
    case invalidResponse
    case player(String)
    case badURL
    /// The Mac could not reach the player. The text is already player-oriented.
    case unreachable(String)

    public var description: String {
        switch self {
        case .timeout: return "The player did not answer in time"
        case .http(let code): return "HTTP \(code)"
        case .invalidResponse: return "Unexpected response from the player"
        case .player(let detail): return detail.isEmpty ? "Player error" : detail
        case .badURL: return "Bad player address"
        case .unreachable(let detail): return detail.isEmpty ? "Player not reachable" : detail
        }
    }
}

/// Wording for the window. Transport failures never use macOS's Internet sentence.
public enum PlayerMessages {
    public static func describe(_ error: Error, host: String) -> String {
        if let blu = error as? BluOSError { return blu.description }
        if let url = urlError(error) { return text(for: url, host: host) }
        return error.localizedDescription
    }

    /// True for a dropped link or a timeout. A player refusal is not a network error.
    public static func isNetwork(_ error: Error) -> Bool {
        if let blu = error as? BluOSError {
            switch blu {
            case .timeout, .unreachable: return true
            case .http, .invalidResponse, .player, .badURL: return false
            }
        }
        return urlError(error) != nil
    }

    public static func text(for error: URLError, host: String) -> String {
        switch error.code {
        case .timedOut:
            return "Player timed out"
        case .notConnectedToInternet, .networkConnectionLost:
            return "Player not reachable (network not ready)"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return at(host)
        default:
            return host.isEmpty ? "Player not reachable (network not ready)" : at(host)
        }
    }

    private static func at(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Player not reachable" }
        return "Player not reachable at \(trimmed)"
    }

    private static func urlError(_ error: Error) -> URLError? {
        if let url = error as? URLError { return url }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        return URLError(_nsError: ns)
    }
}

public protocol BluOSClient: Sendable {
    func status(timeout: Int?, etag: String?) async throws -> PlayerStatus
    func playlist() async throws -> Playlist
    func browse(key: String, query: String?) async throws -> BrowsePage
    func perform(_ path: String) async throws
    func play(id: Int?) async throws
    func seek(_ seconds: Int) async throws
    func pause(toggle: Bool) async throws
    func stop() async throws
    func skip() async throws
    func back() async throws
    func setVolume(level: Int) async throws -> VolumeState
    func setMute(_ on: Bool) async throws -> VolumeState
    func setShuffle(_ on: Bool) async throws
    func setRepeat(_ mode: RepeatMode) async throws
    func deleteSong(id: Int) async throws
    func clearQueue() async throws
    func moveSong(from old: Int, to new: Int) async throws
    func sleep() async throws -> Int
    func presets() async throws -> [Preset]
    func playPreset(id: String) async throws
    func savePlaylist(name: String) async throws -> Int
    func deletePlaylist(name: String) async throws
    func fetchData(_ pathOrURL: String) async throws -> Data
    func syncStatus() async throws -> SyncStatus
    func addSlave(host: String, port: Int) async throws
    func removeSlave(host: String, port: Int) async throws
    func networkShares() async throws -> NetworkSharePage
    func addShareForm() async throws -> AddShareForm
    func addShare(name: String, username: String, password: String, form: AddShareForm) async throws -> NetworkSharePage
    func removeShares(_ paths: [String], from page: NetworkSharePage) async throws -> NetworkSharePage
    func reindex() async throws
}

public enum BluOSURL {
    /// Resolve a BluOS path or absolute URL. Keeps `%`, `&`, `=`, `?` so action URLs stay intact.
    public static func resolve(host: String, port: Int, pathOrURL: String) -> URL? {
        let raw = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let path = raw.hasPrefix("/") ? raw : "/" + raw
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/?&=%:+,;@!$'()*~-._")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "http://\(host):\(port)\(encoded)")
    }

    /// One query component. `%` and `+` are encoded so a single server decode restores the original key.
    /// Action URLs go through `resolve`, which leaves an existing `%XX` alone.
    public static func queryEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func browsePath(key: String, query: String?) -> String {
        var path = "/Browse?key=" + queryEncode(key)
        if let query, !query.isEmpty {
            path += "&q=" + queryEncode(query)
        }
        return path
    }
}
