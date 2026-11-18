import Foundation

public enum NightdeckDefaults {
    /// No player until the user types one or picks one from Bonjour.
    public static let host = ""
    public static let port = 11000
    public static let statusLongPollSeconds = 60
}

public enum PlaybackState: String, Sendable, Equatable {
    case play, pause, stop, stream, connecting, unknown

    public var isPlaying: Bool { self == .play || self == .stream }

    public init(raw: String) {
        self = PlaybackState(rawValue: raw) ?? .unknown
    }
}

/// BluOS repeat: 0 queue, 1 track, 2 off. Cycle matches bluplay: off → queue → track → off.
public enum RepeatMode: Int, Sendable, Equatable {
    case queue = 0
    case track = 1
    case off = 2
    case unknown = -1

    public var next: RepeatMode {
        switch self {
        case .off, .unknown: return .queue
        case .queue: return .track
        case .track: return .off
        }
    }

    public var label: String {
        switch self {
        case .queue: return "Queue"
        case .track: return "Track"
        case .off: return "Off"
        case .unknown: return "Off"
        }
    }
}

public struct PlayerStatus: Sendable, Equatable {
    public var etag: String
    public var state: PlaybackState
    public var title: String
    public var artist: String
    public var album: String
    public var volume: Int
    public var db: String
    public var seconds: Int
    public var total: Int
    public var song: Int
    public var playlistID: String
    public var streamFormat: String
    public var quality: String
    public var formatText: String
    public var file: String
    public var service: String
    public var imagePath: String
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    public var mute: Bool
    public var muteDB: String
    public var sleepMinutes: Int
    public var indexing: Int
    public var canSeek: Bool
    public var receivedAt: Date

    public init(
        etag: String = "",
        state: PlaybackState = .unknown,
        title: String = "",
        artist: String = "",
        album: String = "",
        volume: Int = 0,
        db: String = "",
        seconds: Int = 0,
        total: Int = 0,
        song: Int = -1,
        playlistID: String = "",
        streamFormat: String = "",
        quality: String = "",
        formatText: String = "",
        file: String = "",
        service: String = "",
        imagePath: String = "",
        shuffle: Bool = false,
        repeatMode: RepeatMode = .unknown,
        mute: Bool = false,
        muteDB: String = "",
        sleepMinutes: Int = 0,
        indexing: Int = 0,
        canSeek: Bool = false,
        receivedAt: Date = Date()
    ) {
        self.etag = etag
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.volume = volume
        self.db = db
        self.seconds = seconds
        self.total = total
        self.song = song
        self.playlistID = playlistID
        self.streamFormat = streamFormat
        self.quality = quality
        self.formatText = formatText
        self.file = file
        self.service = service
        self.imagePath = imagePath
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.mute = mute
        self.muteDB = muteDB
        self.sleepMinutes = sleepMinutes
        self.indexing = indexing
        self.canSeek = canSeek
        self.receivedAt = receivedAt
    }

    /// Local progress. Playing time advances from the last /Status; paused time stays put.
    public func interpolatedSeconds(at now: Date) -> Double {
        guard state.isPlaying else { return Double(seconds) }
        let extra = now.timeIntervalSince(receivedAt)
        let value = Double(seconds) + max(0, extra)
        if total > 0 { return min(value, Double(total)) }
        return value
    }

    /// A radio stream often reports no duration, or `canSeek` 0. Either one means the playhead stays put.
    public var seekable: Bool { total > 0 && canSeek }
}

public struct VolumeState: Sendable, Equatable {
    public var level: Int
    public var db: String
    public var mute: Bool
    public var muteDB: String

    public init(level: Int, db: String, mute: Bool, muteDB: String) {
        self.level = level
        self.db = db
        self.mute = mute
        self.muteDB = muteDB
    }
}

public struct QueueSong: Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var artist: String
    public var album: String
    public var file: String
    public var seconds: Int

    public init(id: Int, title: String, artist: String, album: String, file: String, seconds: Int) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.file = file
        self.seconds = seconds
    }
}

public struct Playlist: Sendable, Equatable {
    public var id: String
    public var songs: [QueueSong]

    public init(id: String, songs: [QueueSong]) {
        self.id = id
        self.songs = songs
    }
}

public struct BrowseItem: Sendable, Equatable, Identifiable {
    public var type: String
    public var text: String
    public var text2: String
    public var browseKey: String
    public var contextMenuKey: String
    public var playURL: String
    public var actionURL: String
    public var image: String

    public var id: String {
        "\(type)|\(text)|\(text2)|\(browseKey)|\(playURL)|\(actionURL)"
    }

    public init(
        type: String = "",
        text: String = "",
        text2: String = "",
        browseKey: String = "",
        contextMenuKey: String = "",
        playURL: String = "",
        actionURL: String = "",
        image: String = ""
    ) {
        self.type = type
        self.text = text
        self.text2 = text2
        self.browseKey = browseKey
        self.contextMenuKey = contextMenuKey
        self.playURL = playURL
        self.actionURL = actionURL
        self.image = image
    }

    public var isContainer: Bool {
        !browseKey.isEmpty && type != "track"
    }
}

public struct BrowsePage: Sendable, Equatable {
    public var serviceName: String
    public var searchKey: String
    public var nextKey: String
    public var type: String
    public var items: [BrowseItem]

    public init(
        serviceName: String = "",
        searchKey: String = "",
        nextKey: String = "",
        type: String = "",
        items: [BrowseItem] = []
    ) {
        self.serviceName = serviceName
        self.searchKey = searchKey
        self.nextKey = nextKey
        self.type = type
        self.items = items
    }
}

public struct Preset: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DiscoveredPlayer: Sendable, Equatable, Identifiable {
    public var name: String
    public var host: String
    public var port: Int
    public var serviceType: String

    public var id: String { "\(host):\(port)" }

    public init(name: String, host: String, port: Int, serviceType: String) {
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
    }
}

public struct GroupSlave: Sendable, Equatable, Identifiable {
    public var host: String
    public var port: Int
    public var id: String { "\(host):\(port)" }
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public struct SyncStatus: Sendable, Equatable {
    public var name: String
    public var modelName: String
    public var slaves: [GroupSlave]
    public init(name: String = "", modelName: String = "", slaves: [GroupSlave] = []) {
        self.name = name
        self.modelName = modelName
        self.slaves = slaves
    }
}

public struct KnownPlayer: Sendable, Equatable, Identifiable {
    public var name: String
    public var host: String
    public var port: Int
    public var manual: Bool
    public var id: String { "\(host):\(port)" }
    public init(name: String, host: String, port: Int, manual: Bool) {
        self.name = name
        self.host = host
        self.port = port
        self.manual = manual
    }
}

public enum PlayerAddress {
    /// `host` or `host:port`. Strip a leading http:// or https:// and any path.
    /// One colon whose suffix is an integer is the port. Missing port -> defaultPort (11000).
    /// Nil if the host is empty, contains whitespace or `@`, has more than one colon, or the port is outside 1...65535.
    public static func parse(_ raw: String, defaultPort: Int = 11000) -> (host: String, port: Int)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http://") {
            text.removeFirst("http://".count)
        } else if text.hasPrefix("https://") {
            text.removeFirst("https://".count)
        }
        if let cut = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        if text.isEmpty || text.contains(where: \.isWhitespace) || text.contains("@") { return nil }
        let colons = text.filter { $0 == ":" }.count
        if colons > 1 { return nil }
        var host = text
        var port = defaultPort
        if colons == 1, let colon = text.lastIndex(of: ":") {
            let suffix = text[text.index(after: colon)...]
            guard let parsed = Int(suffix) else { return nil }
            host = String(text[..<colon])
            port = parsed
        }
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return (host, port)
    }
}

public enum GroupLabel {
    /// `+ Kitchen` or `+ Kitchen, Office` in slave order. Empty name falls back to host. Empty slaves -> "".
    public static func caption(slaves: [GroupSlave], names: [String: String]) -> String {
        guard !slaves.isEmpty else { return "" }
        let parts = slaves.map { slave in
            let name = (names[slave.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? slave.host : name
        }
        return "+ " + parts.joined(separator: ", ")
    }
}

/// Rewrite a BluOS playURL the way bluplay does.
public enum QueueActions {
    public static func playNowURL(_ playURL: String) -> String {
        guard !playURL.isEmpty else { return "" }
        var url = playURL
        if !url.contains("clear=") { url += "&clear=0" }
        if !url.contains("where=") { url += "&where=next" }
        return url
    }

    public static func addLastURL(_ playURL: String) -> String {
        guard !playURL.isEmpty else { return "" }
        var url = playURL.replacingOccurrences(of: "playnow=1", with: "playnow=-1")
        if !url.contains("where=") { url += "&where=last" }
        return url
    }
}

/// SwiftUI onMove destination → index after removal. Matches BluOS `/Move?old&new`.
public func queueMoveDestination(from: Int, toOffset: Int) -> Int {
    var dest = toOffset
    if dest > from { dest -= 1 }
    return dest
}

/// Compact "FLAC 24 bit 96 kHz" label. Does not read local files.
public func bluosFormatText(file: String, streamFormat: String, quality: String) -> String {
    let sf = streamFormat.trimmingCharacters(in: .whitespacesAndNewlines)
    let q = quality.trimmingCharacters(in: .whitespacesAndNewlines)
    var codec = ""
    if let base = file.split(separator: "/").last, let dot = base.lastIndex(of: "."), dot != base.index(before: base.endIndex) {
        codec = String(base[base.index(after: dot)...]).uppercased()
    }
    var bits = 0
    var rateHz = 0
    var kbps = 0

    let parts = sf.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    if parts.count >= 2 {
        let word = parts[0]
        let rest = parts.dropFirst().joined(separator: " ")
        if let slash = rest.firstIndex(of: "/"), rest.prefix(upTo: slash).allSatisfy({ $0.isNumber }) {
            let bitText = rest[..<slash]
            let rateText = rest[rest.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if rateText.allSatisfy({ $0.isNumber || $0 == "." }), let b = Int(bitText), let f = Double(rateText), f > 0 {
                codec = word.uppercased()
                bits = b
                rateHz = f < 1000 ? Int((f * 1000).rounded()) : Int(f.rounded())
            }
        } else if rest.hasSuffix("kb/s") {
            let n = rest.replacingOccurrences(of: "kb/s", with: "").trimmingCharacters(in: .whitespaces)
            if let v = Int(n) {
                if codec.isEmpty { codec = word.uppercased() }
                kbps = v
            }
        }
    }
    if codec.isEmpty, !sf.isEmpty { codec = String(sf.prefix(12)).uppercased() }
    if kbps == 0, !q.isEmpty, q.allSatisfy({ $0.isNumber }), let v = Int(q), v > 0 {
        kbps = v >= 1000 ? v / 1000 : v
    }

    var out: [String] = []
    if !codec.isEmpty { out.append(codec) }
    if bits > 0 { out.append("\(bits) bit") }
    if rateHz > 0 {
        let k = Double(rateHz) / 1000
        var text = String(format: "%.3f", k)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        out.append("\(text) kHz")
    }
    if kbps > 0, !(bits > 0 && rateHz > 0) { out.append("\(kbps) kbps") }
    if bits == 0, rateHz == 0, kbps == 0, !q.isEmpty, !codec.isEmpty, !q.allSatisfy({ $0.isNumber }) {
        out.append("(\(q.prefix(12)))")
    }
    return out.joined(separator: " ")
}
