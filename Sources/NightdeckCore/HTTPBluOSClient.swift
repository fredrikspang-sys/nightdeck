import Foundation

public final class HTTPBluOSClient: BluOSClient, @unchecked Sendable {
    private let lock = NSLock()
    private var host: String
    private var port: Int
    private let session: URLSession
    private let postSession: URLSession
    private let poster = FormPoster()

    public init(host: String, port: Int, session: URLSession? = nil) {
        self.host = host
        self.port = port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 100
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.httpMaximumConnectionsPerHost = 4
        if let session {
            self.session = session
        } else {
            self.session = URLSession(configuration: cfg)
        }
        let postCfg = cfg
        self.postSession = URLSession(configuration: postCfg, delegate: poster, delegateQueue: nil)
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

    public func networkShares() async throws -> NetworkSharePage {
        let xml = try await settingsXML(id: "networkShares")
        guard let page = ShareXML.parseSharePage(xml) else { throw BluOSError.invalidResponse }
        return page
    }

    public func addShareForm() async throws -> AddShareForm {
        let xml = try await settingsXML(id: "addShare")
        guard let form = ShareXML.parseAddShareForm(xml) else { throw BluOSError.invalidResponse }
        return form
    }

    public func addShare(
        name: String,
        username: String,
        password: String,
        form: AddShareForm
    ) async throws -> NetworkSharePage {
        let pattern = form.pattern.isEmpty ? AddShareForm.fallback.pattern : form.pattern
        let patternError = form.patternError.isEmpty ? AddShareForm.fallback.patternError : form.patternError
        guard ShareName.matches(name, pattern: pattern) else { throw BluOSError.player(patternError) }
        let shareField = form.shareField.isEmpty ? AddShareForm.fallback.shareField : form.shareField
        let userField = form.userField.isEmpty ? AddShareForm.fallback.userField : form.userField
        let passwordField = form.passwordField.isEmpty ? AddShareForm.fallback.passwordField : form.passwordField
        let encoded = ShareForm.body([
            (shareField, name),
            (userField, username),
            (passwordField, password),
        ])
        // The player serves /Settings on another port (11000 answers 301 to 11001), but the add form's
        // relative URL (/cp/AddShare) is answered on the API port: a NAD C390 (BluOS 4.18) gives 404 on 11001.
        let path = form.url.isEmpty ? AddShareForm.fallback.url : form.url
        guard let base = apiBase(), let url = join(base, path) else { throw BluOSError.badURL }
        let data = try await postForm(url: url, body: Data(encoded.utf8), timeout: 15)
        if let detail = playerError(data, secret: password) { throw BluOSError.player(detail) }
        return try await networkShares()
    }

    public func removeShares(_ paths: [String], from page: NetworkSharePage) async throws -> NetworkSharePage {
        let wanted = paths.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return try await networkShares() }
        guard let action = URL(string: page.actionURL) else { throw BluOSError.badURL }
        let (host, _) = endpoint()
        guard let url = ShareURL.pin(action, toHost: host) else { throw BluOSError.badURL }
        let submitName = page.submitName.isEmpty ? "remove" : page.submitName
        let submitValue = page.submitValue.isEmpty ? "Remove selected shares" : page.submitValue
        var fields = wanted.map { ($0, "on") }
        fields.append((submitName, submitValue))
        let encoded = ShareForm.body(fields)
        let data = try await postForm(url: url, body: Data(encoded.utf8), timeout: 15)
        if let detail = playerError(data, secret: "") { throw BluOSError.player(detail) }
        return try await networkShares()
    }

    public func reindex() async throws {
        try await perform("/Reindex")
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
        try await fetch(path: path, query: query, timeout: timeout).data
    }

    private func settingsXML(id: String) async throws -> String {
        let fetched = try await fetch(path: "/Settings?id=" + BluOSURL.queryEncode(id), timeout: 12)
        let xml = text(fetched.data)
        if let detail = BluOSXML.errorDetail(xml) { throw BluOSError.player(detail) }
        return xml
    }

    private func apiBase() -> URL? {
        let (host, port) = endpoint()
        guard !host.isEmpty, !host.contains("@") else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host
        parts.port = port
        return parts.url
    }

    private func join(_ base: URL, _ path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let raw = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let pieces = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let relative = pieces.first.map(String.init) ?? ""
        parts.path = "/" + relative
        parts.percentEncodedQuery = pieces.count == 2 ? String(pieces[1]) : nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// POSTs the body. On 307/308, and on a 301/302/303 that only moves the request to another port
    /// or host (11000 -> 11001), it POSTs the same body to Location (at most three hops). A 301/302/303
    /// to another path is the web form's "done" page (post-redirect-get): the POST was accepted, so it
    /// returns no data and does not fetch that page. The body is not copied into errors or logs.
    private func postForm(url: URL, body: Data, timeout: TimeInterval, hopsLeft: Int = 3) async throws -> Data {
        let (host, _) = endpoint()
        guard let pinned = ShareURL.pin(url, toHost: host) else { throw BluOSError.badURL }
        var req = URLRequest(url: pinned)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Nightdeck/1.1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await poster.send(session: postSession, request: req)
        } catch let error as BluOSError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw BluOSError.unreachable(PlayerMessages.text(for: error, host: host))
        }
        if (300..<400).contains(http.statusCode) {
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: pinned)?.absoluteURL else {
                throw BluOSError.http(http.statusCode)
            }
            let keepsPost = http.statusCode == 307 || http.statusCode == 308
            let samePath = next.path == pinned.path && next.query == pinned.query
            guard keepsPost || samePath else { return Data() }
            guard hopsLeft > 0 else { throw BluOSError.http(http.statusCode) }
            return try await postForm(url: next, body: body, timeout: timeout, hopsLeft: hopsLeft - 1)
        }
        guard (200..<300).contains(http.statusCode) else { throw BluOSError.http(http.statusCode) }
        return data
    }

    private func playerError(_ data: Data, secret: String) -> String? {
        let xml = text(data)
        guard xml.range(of: "<error", options: .caseInsensitive) != nil else { return nil }
        let detail = BluOSXML.errorDetail(xml) ?? "Player error"
        return ShareForm.redact(detail, secret: secret)
    }

    private struct Fetch {
        var data: Data
        var url: URL?
    }

    private func fetch(path: String, query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> Fetch {
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
        req.setValue("Nightdeck/1.1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw BluOSError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw BluOSError.http(http.statusCode) }
            return Fetch(data: data, url: http.url)
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

/// Stops URLSession from turning a 301/302 POST into a GET. The redirect response is
/// returned to the caller, which POSTs the same body itself. Bodies are not logged.
private final class FormPoster: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private var buffers: [Int: Data] = [:]
    private var responses: [Int: HTTPURLResponse] = [:]

    func send(session: URLSession, request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = FormTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: request)
                box.set(task)
                lock.lock()
                waits[task.taskIdentifier] = cont
                buffers[task.taskIdentifier] = Data()
                lock.unlock()
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            box.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let method = task.originalRequest?.httpMethod ?? request.httpMethod ?? ""
        if method == "POST" {
            lock.lock()
            responses[task.taskIdentifier] = response
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            lock.lock()
            responses[dataTask.taskIdentifier] = http
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock()
        let cont = waits.removeValue(forKey: id)
        let data = buffers.removeValue(forKey: id) ?? Data()
        let response = responses.removeValue(forKey: id)
        lock.unlock()
        guard let cont else { return }
        if let response, error == nil || (300..<400).contains(response.statusCode) {
            cont.resume(returning: (data, response))
            return
        }
        if let error {
            cont.resume(throwing: error)
            return
        }
        cont.resume(throwing: BluOSError.invalidResponse)
    }
}

private final class FormTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
