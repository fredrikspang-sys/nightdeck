import Foundation
import Testing
@testable import NightdeckCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func shareFixturesUseNoPrivateLanAddresses() throws {
    for name in ["networkShares.xml", "addShare.xml", "library.xml"] {
        let text = try fixture(name)
        #expect(!text.contains("192.168."))
    }
}

@Test func networkShareFixtureDecodesPathsActionAndSubmit() throws {
    let page = try #require(ShareXML.parseSharePage(fixture("networkShares.xml")))
    #expect(page.shares.map(\.path) == [
        #"\\10.0.0.5\Media\Music"#,
        #"\\nas.example\Rock & Roll"#,
    ])
    #expect(page.shares[0].label == #"Media\Music on 10.0.0.5 (\\10.0.0.5\Media\Music)"#)
    #expect(page.shares[1].label == #"Rock & Roll on nas.example (\\nas.example\Rock & Roll)"#)
    #expect(page.actionURL == "http://10.0.0.42:80/findremoveshares")
    #expect(page.submitName == "remove")
    #expect(page.submitValue == "Remove selected shares")
}

@Test func emptyShareFormListsNothing() {
    let html = #"<style>.row{color:red}</style><form id="configshareform" method="POST" action="http://10.0.0.7:80/findremoveshares"><fieldset></fieldset><input type="submit" name="remove" value="Remove selected shares" /></form>"#
    let xml = """
    <settings><menuGroup id="networkShares"><setting id="shares" class="html" value="\(xmlAttr(html))"></setting></menuGroup></settings>
    """
    let page = ShareXML.parseSharePage(xml)
    #expect(page?.shares.isEmpty == true)
    #expect(page?.actionURL == "http://10.0.0.7:80/findremoveshares")
    #expect(page?.submitName == "remove")
    #expect(page?.submitValue == "Remove selected shares")
}

@Test func addShareFormReadsURLFieldsAndPattern() throws {
    let form = try #require(ShareXML.parseAddShareForm(fixture("addShare.xml")))
    #expect(form.url == "/cp/AddShare")
    #expect(form.shareField == "sharename")
    #expect(form.userField == "username")
    #expect(form.passwordField == "password")
    #expect(form.pattern == #"^\\\\(.*?)\\(.*)$"#)
    #expect(form.patternError == #"Share URL must be in the form \\computer\share"#)
    #expect(ShareName.matches(#"\\nas\Music"#, pattern: form.pattern))
    #expect(ShareName.matches(#"\\10.0.0.5\Media\Music"#, pattern: form.pattern))
    #expect(!ShareName.matches(#"nas\Music"#, pattern: form.pattern))
    #expect(!ShareName.matches("//nas/Music", pattern: form.pattern))
    #expect(!ShareName.matches(#"\\nas"#, pattern: form.pattern))
}

@Test func missingAddShareFieldsFallBack() {
    let xml = #"<settings><menuGroup id="addShare" class="form"></menuGroup></settings>"#
    let form = ShareXML.parseAddShareForm(xml)
    #expect(form == AddShareForm.fallback)
}

@Test func shareFormEncodesBackslashesSpacesAndAmpersands() {
    let add = ShareForm.body([
        ("sharename", #"\\nas\My Music"#),
        ("username", "a&b"),
        ("password", "p w"),
    ])
    #expect(add == "sharename=%5C%5Cnas%5CMy%20Music&username=a%26b&password=p%20w")
    let remove = ShareForm.body([
        (#"\\host\share"#, "on"),
        ("remove", "Remove selected shares"),
    ])
    #expect(remove == "%5C%5Chost%5Cshare=on&remove=Remove%20selected%20shares")
    let both = ShareForm.body([
        (#"\\host\share"#, "on"),
        (#"\\nas\Rock & Roll"#, "on"),
        ("remove", "Remove selected shares"),
    ])
    #expect(both == "%5C%5Chost%5Cshare=on&%5C%5Cnas%5CRock%20%26%20Roll=on&remove=Remove%20selected%20shares")
}

@Test func shareActionOnAnotherHostIsRewrittenToThePlayer() {
    let action = URL(string: "http://invalid.invalid:80/findremoveshares?x=1")!
    let pinned = ShareURL.pin(action, toHost: "127.0.0.1")
    #expect(pinned?.scheme == "http")
    #expect(pinned?.host == "127.0.0.1")
    #expect(pinned?.port == 80 || pinned?.port == nil)
    #expect(pinned?.path == "/findremoveshares")
    #expect(pinned?.query == "x=1")
    let same = ShareURL.pin(URL(string: "http://127.0.0.1:9/findremoveshares")!, toHost: "127.0.0.1")
    #expect(same?.host == "127.0.0.1")
    #expect(same?.port == 9)
    let dirty = URL(string: "http://user:secret@invalid.invalid:81/findremoveshares")!
    let clean = ShareURL.pin(dirty, toHost: "10.0.0.5")
    #expect(clean?.host == "10.0.0.5")
    #expect(clean?.port == 81)
    #expect(clean?.user == nil)
    #expect(clean?.password == nil)
    #expect(clean?.absoluteString.contains("secret") == false)
}

@Test func shareListAddRemoveReindexAndRedirectStayOnTheMock() async throws {
    let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("nightdeck-shares-\(UUID().uuidString).log")
    let mock = try await MockServer.launch(logURL: logURL, environment: ["FAKE_IDX_SECS": "1"])
    defer {
        mock.stop()
        try? FileManager.default.removeItem(at: logURL)
    }
    let client = mock.client()
    let password = "s3cret-share-pw"
    let page = try await client.networkShares()
    #expect(page.shares.map(\.path) == [
        #"\\10.0.0.5\Media\Music"#,
        #"\\nas.example\Rock & Roll"#,
    ])
    #expect(page.actionURL.contains("127.0.0.1"))
    #expect(page.actionURL.contains("/findremoveshares"))
    #expect(page.submitName == "remove")
    #expect(page.submitValue == "Remove selected shares")

    let form = try await client.addShareForm()
    let fileForm = try #require(ShareXML.parseAddShareForm(fixture("addShare.xml")))
    #expect(form.url == "/cp/AddShare")
    #expect(form.shareField == "sharename")
    #expect(form.userField == "username")
    #expect(form.passwordField == "password")
    #expect(form.pattern == fileForm.pattern)

    do {
        _ = try await client.addShare(name: "nas/Music", username: "alice", password: password, form: form)
        Issue.record("bad share name was accepted")
    } catch let error as BluOSError {
        #expect(error == .player(form.patternError))
        #expect(!error.description.contains(password))
    }

    let added = try await client.addShare(
        name: #"\\studio\My Music"#,
        username: "alice",
        password: password,
        form: form
    )
    #expect(added.shares.contains { $0.path == #"\\studio\My Music"# })

    do {
        _ = try await client.addShare(
            name: #"\\studio\My Music"#,
            username: "alice",
            password: password,
            form: form
        )
        Issue.record("duplicate share was accepted")
    } catch let error as BluOSError {
        #expect(error == .player("Share already exists"))
        #expect(!error.description.contains(password))
    }

    var arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?postredirect=1")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    let redirected = try await client.addShare(
        name: #"\\studio\Via Redirect"#,
        username: "",
        password: password,
        form: form
    )
    #expect(redirected.shares.contains { $0.path == #"\\studio\Via Redirect"# })

    // The real player answers the add form only on the API port; the mock's settings port gives 404 like it.
    let (_, settingsReply) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(mock.port)/Settings?id=addShare")!)
    let settingsPort = try #require(settingsReply.url?.port)
    #expect(settingsPort != mock.port)
    var onSettingsPort = form
    onSettingsPort.url = "http://127.0.0.1:\(settingsPort)/cp/AddShare"
    do {
        _ = try await client.addShare(name: #"\\studio\Wrong Port"#, username: "", password: password, form: onSettingsPort)
        Issue.record("add on the settings port was accepted")
    } catch let error as BluOSError {
        #expect(error == .http(404))
    }

    arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?addsharefail=1")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    do {
        _ = try await client.addShare(name: #"\\studio\Unreachable"#, username: "", password: password, form: form)
        Issue.record("failed mount was treated as success")
    } catch let error as BluOSError {
        #expect(error == .player("Addshare failed"))
    }
    #expect(try await client.networkShares().shares.contains { $0.path == #"\\studio\Unreachable"# } == false)

    arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?shareecho=1")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    do {
        _ = try await client.addShare(
            name: #"\\studio\Echo"#,
            username: "alice",
            password: password,
            form: form
        )
        Issue.record("echoed password was treated as success")
    } catch let error as BluOSError {
        #expect(error.description.contains("refused"))
        #expect(!error.description.contains(password))
    }

    arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?actionhost=invalid.invalid")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    let foreign = try await client.networkShares()
    #expect(foreign.actionURL.contains("invalid.invalid"))
    let removed = try await client.removeShares([#"\\10.0.0.5\Media\Music"#, #"\\nas.example\Rock & Roll"#], from: foreign)
    #expect(!removed.shares.contains { $0.path == #"\\10.0.0.5\Media\Music"# })
    #expect(!removed.shares.contains { $0.path == #"\\nas.example\Rock & Roll"# })
    #expect(removed.shares.contains { $0.path == #"\\studio\My Music"# })

    try await client.reindex()
    let started = try await client.status(timeout: nil, etag: nil)
    #expect(started.indexing == 1)
    let deadline = Date().addingTimeInterval(4)
    var indexing = started.indexing
    while Date() < deadline && indexing != 0 {
        try await Task.sleep(nanoseconds: 200_000_000)
        indexing = try await client.status(timeout: nil, etag: nil).indexing
    }
    #expect(indexing == 0)

    let log = mock.loggedPaths().joined(separator: "\n")
    #expect(log.contains("/cp/AddShareAccept"))
    #expect(log.contains("/findremoveshares"))
    #expect(!log.contains("/sharecfg"))
    #expect(log.contains("/Reindex"))
    #expect(!log.contains(password))
    #expect(!log.contains("password="))
    #expect(!log.contains("sharename="))
}

private func xmlAttr(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
