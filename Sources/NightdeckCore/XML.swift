import Foundation

public enum BluOSXML {
    public static func parseStatus(_ xml: String, receivedAt: Date = Date()) -> PlayerStatus? {
        guard let root = parseRoot(xml), root.name == "status" else { return nil }
        func text(_ name: String) -> String { root.directText(name) }
        let title1 = text("title1")
        let name = text("name")
        let title2 = text("title2")
        let artist = text("artist")
        let title3 = text("title3")
        let album = text("album")
        let repeatText = text("repeat")
        var mode: RepeatMode = repeatText.isEmpty ? .unknown : (RepeatMode(rawValue: Int(repeatText) ?? -1) ?? .unknown)
        if mode.rawValue > 2 { mode = .unknown }
        let file = text("fn")
        let stream = text("streamFormat")
        let quality = text("quality")
        let canSeek = truthy(text("canSeek")) || truthy(text("canMovePlayback"))
        var sleep = Int(text("sleep")) ?? 0
        if sleep < 0 { sleep = 0 }
        var indexing = Int(text("indexing")) ?? 0
        if indexing < 0 { indexing = 0 }
        return PlayerStatus(
            etag: root.attrs["etag"] ?? "",
            state: PlaybackState(raw: text("state")),
            title: title1.isEmpty ? name : title1,
            artist: title2.isEmpty ? artist : title2,
            album: title3.isEmpty ? album : title3,
            volume: Int(text("volume")) ?? 0,
            db: text("db"),
            seconds: Int(text("secs")) ?? 0,
            total: Int(text("totlen")) ?? 0,
            song: text("song").isEmpty ? -1 : (Int(text("song")) ?? -1),
            playlistID: text("pid"),
            streamFormat: stream,
            quality: quality,
            formatText: bluosFormatText(file: file, streamFormat: stream, quality: quality),
            file: file,
            service: text("service"),
            imagePath: text("image"),
            shuffle: truthy(text("shuffle")),
            repeatMode: mode,
            mute: truthy(text("mute")),
            muteDB: text("muteDb"),
            sleepMinutes: sleep,
            indexing: indexing,
            canSeek: canSeek,
            receivedAt: receivedAt
        )
    }

    public static func parsePlaylist(_ xml: String) -> Playlist? {
        guard let root = parseRoot(xml), root.name == "playlist" else { return nil }
        let id = root.attrs["id"].flatMap({ $0.isEmpty ? nil : $0 }) ?? root.directText("id")
        var songs: [QueueSong] = []
        songs.reserveCapacity(root.children.count)
        for node in root.children where node.name == "song" {
            guard let idText = node.attrs["id"], let sid = Int(idText) else { continue }
            let title = node.directText("title")
            let seconds = Int(node.directText("time")) ?? 0
            songs.append(QueueSong(
                id: sid,
                title: title.isEmpty ? "?" : title,
                artist: node.directText("art"),
                album: node.directText("alb"),
                file: node.directText("fn"),
                seconds: seconds
            ))
        }
        return Playlist(id: id, songs: songs)
    }

    public static func parseBrowse(_ xml: String) -> BrowsePage? {
        guard let root = parseRoot(xml) else { return nil }
        if root.name == "error" { return nil }
        guard root.name == "browse" else { return nil }
        var items: [BrowseItem] = []
        items.reserveCapacity(root.children.count)
        for node in root.children where node.name == "item" {
            items.append(item(from: node))
        }
        return BrowsePage(
            serviceName: root.attrs["serviceName"] ?? "",
            searchKey: root.attrs["searchKey"] ?? "",
            nextKey: root.attrs["nextKey"] ?? "",
            type: root.attrs["type"] ?? "",
            items: items
        )
    }

    public static func parsePresets(_ xml: String) -> [Preset] {
        guard let root = parseRoot(xml) else { return [] }
        return root.children.compactMap { node in
            guard node.name == "preset" else { return nil }
            let id = node.attrs["id"] ?? node.directText("id")
            guard !id.isEmpty else { return nil }
            let name = node.attrs["name"] ?? node.directText("name")
            return Preset(id: id, name: name.isEmpty ? id : name)
        }
    }

    public static func parseSyncStatus(_ xml: String) -> SyncStatus? {
        guard let root = parseRoot(xml), root.name == "SyncStatus" else { return nil }
        var slaves: [GroupSlave] = []
        slaves.reserveCapacity(root.children.count)
        for node in root.children where node.name == "slave" {
            let host = (node.attrs["id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty { continue }
            let rawPort = (node.attrs["port"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let port: Int
            if let parsed = Int(rawPort), (1...65535).contains(parsed) {
                port = parsed
            } else {
                port = 11000
            }
            slaves.append(GroupSlave(host: host, port: port))
        }
        return SyncStatus(
            name: root.attrs["name"] ?? "",
            modelName: root.attrs["modelName"] ?? "",
            slaves: slaves
        )
    }

    public static func parseVolume(_ xml: String) -> VolumeState? {
        guard let root = parseRoot(xml), root.name == "volume" else { return nil }
        let mute = (root.attrs["mute"] ?? "") == "1"
        var level = Int(root.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if mute, let mv = root.attrs["muteVolume"], let n = Int(mv) { level = n }
        return VolumeState(
            level: level,
            db: root.attrs["db"] ?? "",
            mute: mute,
            muteDB: root.attrs["muteDb"] ?? ""
        )
    }

    /// Detail string when the document root is `<error>`, otherwise nil.
    public static func errorDetail(_ xml: String) -> String? {
        guard let root = parseRoot(xml), root.name == "error" else { return nil }
        let detail = root.directText("detail")
        return detail.isEmpty ? "error" : detail
    }

    public static func elementText(_ xml: String, named: String) -> String? {
        guard let root = parseRoot(xml) else { return nil }
        if root.name == named {
            return root.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if root.children.contains(where: { $0.name == named }) {
            return root.directText(named)
        }
        return nil
    }

    private static func item(from node: Node) -> BrowseItem {
        BrowseItem(
            type: node.attrs["type"] ?? "",
            text: node.attrs["text"] ?? "",
            text2: node.attrs["text2"] ?? "",
            browseKey: node.attrs["browseKey"] ?? "",
            contextMenuKey: node.attrs["contextMenuKey"] ?? "",
            playURL: node.attrs["playURL"] ?? "",
            actionURL: node.attrs["actionURL"] ?? "",
            image: node.attrs["image"] ?? ""
        )
    }

    private static func truthy(_ text: String) -> Bool {
        text == "1" || text == "true" || text == "True"
    }

    private static func parseRoot(_ xml: String) -> Node? {
        guard xml.utf8.count <= 8_000_000 else { return nil }
        if xml.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil { return nil }
        if xml.range(of: "<!ENTITY", options: .caseInsensitive) != nil { return nil }
        let collector = Collector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = collector.root else { return nil }
        return root
    }
}

private final class Node {
    var name: String
    var attrs: [String: String]
    var text: String = ""
    var children: [Node] = []

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func directText(_ name: String) -> String {
        children.first { $0.name == name }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class Collector: NSObject, XMLParserDelegate {
    var stack: [Node] = []
    var root: Node?

    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(Node(name: name, attrs: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement name: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let node = stack.popLast() else { return }
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
    }
}
