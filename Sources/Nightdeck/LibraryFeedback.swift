import Foundation
import NightdeckCore

/// Shared timings so a row never needs its own timer.
enum LibraryFeedbackTiming {
    /// How long the add checkmark stays before the plus returns.
    static let addConfirmSeconds: TimeInterval = 1.5
    /// How long play stays amber if `/Status` never moves on.
    static let playHoldSeconds: TimeInterval = 2
}

/// What the library row should show for one add or play button.
enum LibraryCue: Equatable {
    case idle
    case pending
    case added
    case playing
}

/// The line under the library search field.
enum LibraryNote: Equatable {
    case confirmation(String)
    case failure(String)

    var text: String {
        switch self {
        case .confirmation(let text), .failure(let text): return text
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// Whether a library row is the song or album `/Status` is on.
enum NowPlayingMatch {
    static func matches(_ item: BrowseItem, status: PlayerStatus) -> Bool {
        guard status.state == .play || status.state == .stream || status.state == .pause else { return false }
        let title = trim(status.title)
        let album = trim(status.album)
        let artist = trim(status.artist)
        let file = trim(status.file)
        guard !title.isEmpty || !album.isEmpty || !file.isEmpty else { return false }
        let name = trim(item.text)
        switch item.type {
        case "track":
            return track(item, title: title, artist: artist, album: album, file: file)
        case "album":
            return named(name, subtitle: trim(item.text2), album: album, artist: artist, file: file)
        case "artist":
            return !name.isEmpty && !artist.isEmpty && same(name, artist)
        default:
            if !item.isContainer, !item.playURL.isEmpty {
                return track(item, title: title, artist: artist, album: album, file: file)
            }
            guard !name.isEmpty else { return false }
            if !album.isEmpty, same(name, album) { return true }
            if !artist.isEmpty, same(name, artist) { return true }
            if !title.isEmpty, same(name, title) { return true }
            return false
        }
    }

    private static func track(
        _ item: BrowseItem,
        title: String,
        artist: String,
        album: String,
        file: String
    ) -> Bool {
        if let wanted = fileParameter(item.playURL), !wanted.isEmpty, !file.isEmpty {
            return sameFile(wanted, file)
        }
        let name = trim(item.text)
        guard !name.isEmpty, !title.isEmpty, same(name, title) else { return false }
        let subtitle = trim(item.text2)
        if subtitle.isEmpty || (artist.isEmpty && album.isEmpty) { return true }
        return same(subtitle, artist) || same(subtitle, album) || same(subtitle, title)
    }

    /// Album name against `/Status` album, then the parent folder of `/Status` fn.
    private static func named(
        _ name: String,
        subtitle: String,
        album: String,
        artist: String,
        file: String
    ) -> Bool {
        guard !name.isEmpty else { return false }
        if !album.isEmpty, same(name, album) {
            if subtitle.isEmpty || artist.isEmpty || same(subtitle, artist) { return true }
            return false
        }
        let parts = file.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return false }
        return parts.dropLast().contains { same($0, name) }
    }

    private static func fileParameter(_ playURL: String) -> String? {
        guard let range = playURL.range(of: "file=") else { return nil }
        var raw = String(playURL[range.upperBound...])
        if let amp = raw.firstIndex(of: "&") { raw = String(raw[..<amp]) }
        let decoded = raw.removingPercentEncoding ?? raw
        let trimmed = trim(decoded)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        normalizeFile(lhs) == normalizeFile(rhs)
    }

    private static func normalizeFile(_ raw: String) -> String {
        var text = trim(raw)
        if let decoded = text.removingPercentEncoding, decoded != text { text = decoded }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
