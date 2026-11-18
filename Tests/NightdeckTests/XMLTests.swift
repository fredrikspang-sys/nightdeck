import Foundation
import Testing
@testable import NightdeckCore

@Test func parsesRealStatusShape() {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <status etag="abc"><album>Aeternus</album><artist>Dynatron</artist><canMovePlayback>true</canMovePlayback><canSeek>0</canSeek><db>-35</db><fn>/music/song.flac</fn><image>/Artwork?service=LocalMusic&amp;fn=%2Fsong.flac</image><indexing>0</indexing><mute>0</mute><name>Towards the Island Universe</name><pid>1264</pid><quality>cd</quality><repeat>2</repeat><secs>12</secs><service>LocalMusic</service><shuffle>0</shuffle><sleep></sleep><song>16</song><state>stop</state><streamFormat>FLAC 24/96</streamFormat><title1>Towards the Island Universe</title1><title2>Dynatron</title2><title3>Aeternus</title3><totlen>275</totlen><volume>50</volume></status>
    """
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    let status = BluOSXML.parseStatus(xml, receivedAt: when)
    #expect(status?.etag == "abc")
    #expect(status?.title == "Towards the Island Universe")
    #expect(status?.artist == "Dynatron")
    #expect(status?.album == "Aeternus")
    #expect(status?.state == .stop)
    #expect(status?.volume == 50)
    #expect(status?.db == "-35")
    #expect(status?.seconds == 12)
    #expect(status?.total == 275)
    #expect(status?.song == 16)
    #expect(status?.playlistID == "1264")
    #expect(status?.repeatMode == .off)
    #expect(status?.shuffle == false)
    #expect(status?.sleepMinutes == 0)
    #expect(status?.canSeek == true)
    #expect(status?.seekable == true)
    #expect(status?.imagePath == "/Artwork?service=LocalMusic&fn=%2Fsong.flac")
    #expect(status?.formatText == "FLAC 24 bit 96 kHz")
    #expect(status?.receivedAt == when)
}

@Test func explicitCanSeekFalseIsNotSeekable() {
    let xml = "<status etag=\"e\"><state>stream</state><secs>3</secs><totlen>90</totlen><canSeek>0</canSeek><title1>Radio</title1></status>"
    let status = BluOSXML.parseStatus(xml)
    #expect(status?.canSeek == false)
    #expect(status?.total == 90)
    #expect(status?.seekable == false)
    let live = BluOSXML.parseStatus("<status etag=\"e\"><state>stream</state><secs>3</secs><canSeek>1</canSeek></status>")
    #expect(live?.canSeek == true)
    #expect(live?.seekable == false)
}

@Test func statusPrefersTitleFieldsAndRepeatQueue() {
    let xml = """
    <status etag="e"><state>play</state><title1>T</title1><name>N</name><title2>Ar</title2><artist>X</artist><title3>Al</title3><album>Y</album><repeat>0</repeat><shuffle>1</shuffle><mute>1</mute><muteDb>-20</muteDb><sleep>15</sleep><song></song><volume>-1</volume></status>
    """
    let status = BluOSXML.parseStatus(xml)
    #expect(status?.title == "T")
    #expect(status?.artist == "Ar")
    #expect(status?.album == "Al")
    #expect(status?.repeatMode == .queue)
    #expect(status?.shuffle == true)
    #expect(status?.mute == true)
    #expect(status?.muteDB == "-20")
    #expect(status?.sleepMinutes == 15)
    #expect(status?.song == -1)
    #expect(status?.volume == -1)
    #expect(status?.state == .play)
}

@Test func parsesPlaylistAndBrowseAndPresets() {
    let playlistXML = """
    <playlist length="2" id="9"><song id="0"><art>A</art><alb>B</alb><title>T</title><fn>/f</fn><time>12</time></song><song id="1"><title></title><art></art><alb></alb></song></playlist>
    """
    let playlist = BluOSXML.parsePlaylist(playlistXML)
    #expect(playlist?.id == "9")
    #expect(playlist?.songs.count == 2)
    #expect(playlist?.songs[0].title == "T")
    #expect(playlist?.songs[0].artist == "A")
    #expect(playlist?.songs[0].seconds == 12)
    #expect(playlist?.songs[1].title == "?")

    let browseXML = """
    <browse serviceName="Library" searchKey="LocalMusic:Search" nextKey="NEXT" type="menu"><item browseKey="ART:1" text="Artists" text2="4" type="link"/><item playURL="/Add?playnow=1&amp;file=a" text="Song" type="track" image="/Artwork?x=1"/></browse>
    """
    let page = BluOSXML.parseBrowse(browseXML)
    #expect(page?.serviceName == "Library")
    #expect(page?.searchKey == "LocalMusic:Search")
    #expect(page?.nextKey == "NEXT")
    #expect(page?.items.count == 2)
    #expect(page?.items[0].browseKey == "ART:1")
    #expect(page?.items[0].text2 == "4")
    #expect(page?.items[1].playURL == "/Add?playnow=1&file=a")
    #expect(page?.items[1].image == "/Artwork?x=1")

    let presets = BluOSXML.parsePresets(#"<presets><preset id="2" name="Jazz &amp; Blues"/></presets>"#)
    #expect(presets.count == 1)
    #expect(presets[0].id == "2")
    #expect(presets[0].name == "Jazz & Blues")
}

@Test func parsesVolumeMuteAndErrors() {
    let muted = BluOSXML.parseVolume(#"<volume db="-100" mute="1" muteVolume="40" muteDb="-40">0</volume>"#)
    #expect(muted?.mute == true)
    #expect(muted?.level == 40)
    #expect(muted?.db == "-100")
    #expect(muted?.muteDB == "-40")
    let open = BluOSXML.parseVolume(#"<volume db="-35">50</volume>"#)
    #expect(open?.level == 50)
    #expect(open?.mute == false)
    #expect(BluOSXML.errorDetail("<error><detail>search broke</detail></error>") == "search broke")
    #expect(BluOSXML.errorDetail("<status></status>") == nil)
    #expect(BluOSXML.elementText("<sleep></sleep>", named: "sleep") == "")
    #expect(BluOSXML.elementText("<saved><entries>4</entries></saved>", named: "entries") == "4")
    #expect(BluOSXML.parseStatus("<nope/>") == nil)
}

@Test func doctypeAndEntityDocumentsDoNotParse() {
    let bomb = "<!DOCTYPE status [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><status>&xxe;</status>"
    #expect(BluOSXML.parseStatus(bomb) == nil)
    #expect(BluOSXML.parseStatus("<status><title1>ok</title1><!ENTITY xxe \"hi\"></status>") == nil)
    #expect(BluOSXML.parsePlaylist("<!doctype playlist><playlist id=\"1\"></playlist>") == nil)
}

@Test func lengthOnlyPlaylistUsesChildID() {
    let playlist = BluOSXML.parsePlaylist("<playlist><length>25</length><id>1264</id></playlist>")
    #expect(playlist?.id == "1264")
    #expect(playlist?.songs.isEmpty == true)
}

@Test func parsesSyncStatusNameAndSlaves() {
    let xml = #"<SyncStatus name="Kitchen" modelName="FAKE"><slave id="10.0.0.2" port="11001"/><slave id="10.0.0.3"/><slave id="" port="11000"/><slave id="10.0.0.4" port="99999"/></SyncStatus>"#
    let sync = BluOSXML.parseSyncStatus(xml)
    #expect(sync?.name == "Kitchen")
    #expect(sync?.modelName == "FAKE")
    #expect(sync?.slaves == [
        GroupSlave(host: "10.0.0.2", port: 11001),
        GroupSlave(host: "10.0.0.3", port: 11000),
        GroupSlave(host: "10.0.0.4", port: 11000),
    ])
    #expect(BluOSXML.parseSyncStatus("<error><detail>refused</detail></error>") == nil)
}
