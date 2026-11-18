import Foundation
import Testing
@testable import NightdeckCore

@Test func groupCaptionUsesNamesInSlaveOrder() {
    let kitchen = GroupSlave(host: "10.0.0.2", port: 11000)
    let office = GroupSlave(host: "10.0.0.3", port: 11001)
    let names = [kitchen.id: "Kitchen", office.id: "Office"]
    #expect(GroupLabel.caption(slaves: [kitchen], names: names) == "+ Kitchen")
    #expect(GroupLabel.caption(slaves: [], names: names) == "")
    #expect(GroupLabel.caption(slaves: [kitchen], names: [:]) == "+ 10.0.0.2")
    #expect(GroupLabel.caption(slaves: [kitchen], names: [kitchen.id: ""]) == "+ 10.0.0.2")
    #expect(GroupLabel.caption(slaves: [kitchen, office], names: names) == "+ Kitchen, Office")
    #expect(GroupLabel.caption(slaves: [office, kitchen], names: names) == "+ Office, Kitchen")
}

@Test func playerAddressParsesHostAndPort() {
    #expect(PlayerAddress.parse("127.0.0.1:11001")?.host == "127.0.0.1")
    #expect(PlayerAddress.parse("127.0.0.1:11001")?.port == 11001)
    let plain = PlayerAddress.parse("127.0.0.1")
    #expect(plain?.host == "127.0.0.1")
    #expect(plain?.port == 11000)
    let http = PlayerAddress.parse("http://host/x")
    #expect(http?.host == "host")
    #expect(http?.port == 11000)
    let https = PlayerAddress.parse("https://ex.ample:11001/p")
    #expect(https?.host == "ex.ample")
    #expect(https?.port == 11001)
    #expect(PlayerAddress.parse("host", defaultPort: 12000)?.port == 12000)
    #expect(PlayerAddress.parse("") == nil)
    #expect(PlayerAddress.parse("   ") == nil)
    #expect(PlayerAddress.parse("bad:port") == nil)
    #expect(PlayerAddress.parse("a:b:c") == nil)
    #expect(PlayerAddress.parse("has space") == nil)
    #expect(PlayerAddress.parse("host:0") == nil)
    #expect(PlayerAddress.parse("host:65536") == nil)
    #expect(PlayerAddress.parse("user@10.0.0.2") == nil)
}

@Test func addSlaveThenRemoveSlaveUpdatesSyncStatus() async throws {
    let logA = FileManager.default.temporaryDirectory.appendingPathComponent("nd-grp-a-\(UUID().uuidString).log")
    let logB = FileManager.default.temporaryDirectory.appendingPathComponent("nd-grp-b-\(UUID().uuidString).log")
    let primary = try await MockServer.launch(logURL: logA)
    defer {
        primary.stop()
        try? FileManager.default.removeItem(at: logA)
    }
    let secondary = try await MockServer.launch(logURL: logB)
    defer {
        secondary.stop()
        try? FileManager.default.removeItem(at: logB)
    }
    let client = primary.client()
    let before = try await client.syncStatus()
    #expect(before.slaves.isEmpty)
    #expect(before.name == "Fake Player")
    #expect(before.modelName == "FAKE")
    try await client.addSlave(host: "127.0.0.1", port: secondary.port)
    let grouped = try await client.syncStatus()
    #expect(grouped.slaves.contains { $0.host == "127.0.0.1" && $0.port == secondary.port })
    try await client.removeSlave(host: "127.0.0.1", port: secondary.port)
    let cleared = try await client.syncStatus()
    #expect(cleared.slaves.isEmpty)
    let paths = primary.loggedPaths() + secondary.loggedPaths()
    #expect(paths.contains { $0.contains("slave=127.0.0.1") && $0.contains("port=\(secondary.port)") })
    #expect(NightdeckDefaults.host.isEmpty)
    #expect(secondary.loggedPaths().filter { $0.hasPrefix("/AddSlave") || $0.hasPrefix("/RemoveSlave") }.isEmpty)
}

@Test func syncStatusNameCanBeRenamed() async throws {
    let mock = try await MockServer.launch()
    defer { mock.stop() }
    var arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?name=Kitchen%20%26%20Bar")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    let named = try await mock.client().syncStatus()
    #expect(named.name == "Kitchen & Bar")
    #expect(named.modelName == "FAKE")
}

@Test func slaveFailRefusesAddAndLeavesTheGroupEmpty() async throws {
    let mock = try await MockServer.launch()
    defer { mock.stop() }
    let client = mock.client()
    var arm = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?slavefail=1")!)
    arm.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: arm)
    let status = try await client.status(timeout: nil, etag: nil)
    #expect(status.state == .play)
    let peeked = try await client.syncStatus()
    #expect(peeked.slaves.isEmpty)
    do {
        try await client.addSlave(host: "127.0.0.1", port: 11001)
        Issue.record("addSlave accepted a refused group")
    } catch let error as BluOSError {
        #expect(error == .player("refused"))
    }
    let sync = try await client.syncStatus()
    #expect(sync.slaves.isEmpty)
}

@Test func missingSlaveIsAnErrorAndDoesNotChangeTheGroup() async throws {
    let mock = try await MockServer.launch()
    defer { mock.stop() }
    let client = mock.client()
    try await client.addSlave(host: "10.0.0.8", port: 11001)
    do {
        try await client.addSlave(host: "", port: 11000)
        Issue.record("empty slave was accepted")
    } catch let error as BluOSError {
        #expect(error == .player("missing slave"))
    }
    var raw = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/AddSlave?port=11000")!)
    raw.timeoutInterval = 2
    let (body, response) = try await URLSession.shared.data(for: raw)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: body, as: UTF8.self).contains("<detail>missing slave</detail>"))
    var remove = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/RemoveSlave")!)
    remove.timeoutInterval = 2
    let (removed, _) = try await URLSession.shared.data(for: remove)
    #expect(String(decoding: removed, as: UTF8.self).contains("<detail>missing slave</detail>"))
    let sync = try await client.syncStatus()
    #expect(sync.slaves == [GroupSlave(host: "10.0.0.8", port: 11001)])
}
