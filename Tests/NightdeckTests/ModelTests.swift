import Foundation
import Testing
@testable import NightdeckCore

@Test func repeatCyclesOffQueueTrack() {
    #expect(RepeatMode.off.next == .queue)
    #expect(RepeatMode.queue.next == .track)
    #expect(RepeatMode.track.next == .off)
    #expect(RepeatMode.unknown.next == .queue)
    #expect(RepeatMode.queue.label == "Queue")
}

@Test func seekableNeedsDurationAndPermission() {
    #expect(PlayerStatus(total: 200, canSeek: true).seekable)
    #expect(!PlayerStatus(total: 200, canSeek: false).seekable)
    #expect(!PlayerStatus(total: 0, canSeek: true).seekable)
    #expect(!PlayerStatus().seekable)
}

@Test func progressInterpolatesOnlyWhilePlaying() {
    let start = Date(timeIntervalSince1970: 100)
    var status = PlayerStatus(state: .play, seconds: 10, total: 30, receivedAt: start)
    #expect(status.interpolatedSeconds(at: start.addingTimeInterval(4)) == 14)
    #expect(status.interpolatedSeconds(at: start.addingTimeInterval(100)) == 30)
    status.state = .pause
    #expect(status.interpolatedSeconds(at: start.addingTimeInterval(4)) == 10)
}

@Test func queueURLRewritesMatchBluplay() {
    let play = "/Add?playnow=1&file=a"
    #expect(QueueActions.playNowURL(play) == "/Add?playnow=1&file=a&clear=0&where=next")
    #expect(QueueActions.addLastURL(play) == "/Add?playnow=-1&file=a&where=last")
    #expect(queueMoveDestination(from: 0, toOffset: 3) == 2)
    #expect(queueMoveDestination(from: 3, toOffset: 1) == 1)
}

@Test func formatLabelParsesStreamFormat() {
    #expect(bluosFormatText(file: "/m/a.flac", streamFormat: "FLAC 16/44.1", quality: "cd") == "FLAC 16 bit 44.1 kHz")
    #expect(bluosFormatText(file: "", streamFormat: "AAC 128 kb/s", quality: "") == "AAC 128 kbps")
    #expect(bluosFormatText(file: "/m/a.mp3", streamFormat: "", quality: "320") == "MP3 320 kbps")
}

@Test func browseKeyKeepsPercentEscapesAndPlus() {
    let key = "LocalMusic:Song/%2Flibrary/v1?expr=a+b"
    let path = BluOSURL.browsePath(key: key, query: "C++")
    let url = BluOSURL.resolve(host: "127.0.0.1", port: 11000, pathOrURL: path)
    let absolute = url?.absoluteString ?? ""
    let raw = absolute.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    #expect(!raw.contains("+"))
    #expect(raw.contains("%2B"))
    #expect(raw.contains("%252F"))
    func once(_ pair: String) -> String {
        let value = pair.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return value.removingPercentEncoding ?? value
    }
    let parts = raw.split(separator: "&").map(String.init)
    #expect(parts.contains { once($0) == key })
    #expect(parts.contains { once($0) == "C++" })
}

@Test func resolvesArtworkAndActionURLs() {
    let action = BluOSURL.resolve(host: "127.0.0.1", port: 11000, pathOrURL: "/Add?playnow=-1&file=%2Fsong.flac")
    #expect(action?.absoluteString == "http://127.0.0.1:11000/Add?playnow=-1&file=%2Fsong.flac")
    let space = BluOSURL.resolve(host: "10.0.0.2", port: 11000, pathOrURL: "/Artwork?fn=a b")
    #expect(space?.absoluteString.contains("a%20b") == true)
    let absolute = BluOSURL.resolve(host: "10.0.0.2", port: 11000, pathOrURL: "http://10.0.0.8:11004/art")
    #expect(absolute?.host == "10.0.0.8")
}
