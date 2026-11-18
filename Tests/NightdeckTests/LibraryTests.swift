import AppKit
import SwiftUI
import Testing
@testable import Nightdeck
@testable import NightdeckCore

@Test func letterIndexPlanSkipsAnAlbumNamedA() {
    let index = BluOSXML.parseBrowse("""
    <browse serviceName="Albums" nextKey="MORE" type="sections">
    <item browseKey="ALL" text="All Albums" type="link"/>
    <item browseKey="SEC:A" text="A" text2="2" type="section"/>
    <item browseKey="SEC:#" text="#" text2="1" type="section"/>
    </browse>
    """)
    let plan = LetterBrowse.plan(for: index!)
    #expect(plan?.allKey == "ALL")
    #expect(plan?.indexNext == "MORE")
    #expect(plan?.letters.map(\.label) == ["A", "#"])

    let album = BluOSXML.parseBrowse("""
    <browse serviceName="Library">
    <item browseKey="ALB:1" playURL="/Add?album=1" text="A" type="album"/>
    </browse>
    """)
    #expect(LetterBrowse.plan(for: album!) == nil)

    let root = BluOSXML.parseBrowse("""
    <browse>
    <item browseKey="LocalMusic:bySection:Artist/x" text="Artists" type="link"/>
    <item browseKey="LocalMusic:bySection:Album/x" text="Albums" type="link"/>
    </browse>
    """)
    #expect(LetterBrowse.plan(for: root!) == nil)
}

@Suite(.serialized)
@MainActor
struct LibraryBrowseTests {
    @Test func albumsSkipTheLetterIndexAndPageWithNextKey() async throws {
        let harness = try await LibraryHarness.open()
        defer { harness.close() }
        let ui = LibraryUI.shared
        await ui.open(harness.model, key: "LocalMusic:", push: false, title: "Library")
        let root = try #require(ui.page)
        #expect(root.items.map(\.text) == ["Artists", "Albums"])
        let albums = try #require(root.items.first { $0.text == "Albums" })
        await ui.open(harness.model, key: albums.browseKey, push: true, title: albums.text)
        await ui.drain(harness.model)
        let names = try #require(ui.page).items.map(\.text)
        #expect(!names.isEmpty)
        #expect(ui.page?.items.contains { $0.type == "section" } == false)
        let alpha = try #require(names.firstIndex(of: "Alpha"))
        let bravo = try #require(names.firstIndex(of: "Bravo"))
        #expect(alpha < bravo)
        #expect(ui.page?.serviceName == "Albums")
        #expect(ui.jumpLabels.contains("A"))
        #expect(ui.jumpLabels.contains("B"))
        ui.back()
        #expect(ui.page?.items.map(\.text) == ["Artists", "Albums"])
    }

    @Test func bigSectionFollowsNextKeyUntilTheLastAlbum() async throws {
        let harness = try await LibraryHarness.open()
        defer { harness.close() }
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?bigsec=8")!)
        let ui = LibraryUI.shared
        await ui.open(harness.model, key: "LocalMusic:bySection:Album/x", push: false, title: "Albums")
        await ui.drain(harness.model)
        let names = try #require(ui.page).items.map(\.text)
        #expect(names.contains("Pzz 0001"))
        #expect(names.contains("Pzz 0008"))
        #expect(ui.page?.items.contains { $0.type == "section" } == false)
        #expect(ui.hasMore == false)
        let paths = harness.mock.loggedPaths()
        #expect(paths.contains { $0.contains("NEXT%3AP") }, "paths: \(paths.joined(separator: " "))")
    }

    @Test func repeatedNextKeyDoesNotLoopForever() async throws {
        let harness = try await LibraryHarness.open()
        defer { harness.close() }
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?loopsec=1")!)
        let ui = LibraryUI.shared
        await ui.open(harness.model, key: "LocalMusic:bySection:Album/x", push: false, title: "Albums")
        await ui.drain(harness.model)
        #expect(ui.hasMore == false)
        #expect(ui.page?.items.filter { $0.text == "Lima" }.count == 1)
    }

    @Test func artistsStayAFlatListAndReturnOpensTheSelectedAlbum() async throws {
        let harness = try await LibraryHarness.open()
        defer { harness.close() }
        let ui = LibraryUI.shared
        await ui.open(harness.model, key: "LocalMusic:", push: false)
        let artists = try #require(ui.page?.items.first { $0.text == "Artists" })
        await ui.open(harness.model, key: artists.browseKey, push: true, title: "Artists")
        let artistPage = try #require(ui.page)
        #expect(!artistPage.items.isEmpty)
        #expect(artistPage.items.allSatisfy { $0.type == "artist" })
        ui.back()
        await ui.open(harness.model, key: "LocalMusic:bySection:Album/x", push: true, title: "Albums")
        await ui.drain(harness.model)
        let index = try #require(ui.page?.items.firstIndex { $0.text == "Alpha" })
        ui.selection = index
        await ui.activateSelection(harness.model)
        let tracks = try #require(ui.page)
        #expect(tracks.items.allSatisfy { $0.type == "track" })
        #expect(tracks.items.contains { $0.text.contains("Alpha") })
        ui.back()
        #expect(ui.page?.items.contains { $0.text == "Alpha" } == true)
        #expect(ui.page?.items.contains { $0.type == "section" } == false)
    }

    @Test func libraryRowsDoNotShowAnOpenButton() async throws {
        let harness = try await LibraryHarness.open()
        defer { harness.close() }
        let model = harness.model
        LibraryUI.shared.resetSession()
        let host = NSHostingView(rootView: LibraryView().environment(model).preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: -8000, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: 640, height: 480))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let ready = await waitUntil {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return labels(in: host).contains("Albums")
        }
        let found = labels(in: host)
        let titles = LibraryUI.shared.page?.items.map(\.text) ?? []
        #expect(ready, "page=\(titles) labels=\(found)")
        #expect(!found.contains("Open"), "labels=\(found)")
        #expect(titles == ["Artists", "Albums"])
        #expect(found.contains("Artists"))
        #expect(found.contains("Albums"))
    }
}

@MainActor
private struct LibraryHarness {
    let mock: MockServer
    let model: AppModel
    let logURL: URL

    static func open() async throws -> LibraryHarness {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nightdeck-lib-\(UUID().uuidString).log")
        let mock = try await MockServer.launch(logURL: logURL)
        let model = AppModel()
        model.attachPreview(host: "127.0.0.1", port: mock.port)
        LibraryUI.shared.resetSession()
        let connected = await waitUntil { model.connected }
        if !connected {
            mock.stop()
            throw LibraryTestError.offline
        }
        return LibraryHarness(mock: mock, model: model, logURL: logURL)
    }

    func close() {
        LibraryUI.shared.resetSession()
        model.endPreview()
        mock.stop()
        try? FileManager.default.removeItem(at: logURL)
    }
}

private enum LibraryTestError: Error {
    case offline
}

@MainActor
private func waitUntil(_ ready: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        if ready() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return ready()
}

@MainActor
private func labels(in root: NSView) -> [String] {
    var labels: [String] = []
    var pending: [NSObject] = [root]
    var seen = Set<ObjectIdentifier>()
    while let item = pending.popLast() {
        if !seen.insert(ObjectIdentifier(item)).inserted { continue }
        if let label = axString(item, "accessibilityLabel") { labels.append(label) }
        if let value = axString(item, "accessibilityValue") { labels.append(value) }
        if let title = axString(item, "title") { labels.append(title) }
        if let tip = axString(item, "toolTip") { labels.append(tip) }
        if let field = item as? NSTextField, !field.stringValue.isEmpty { labels.append(field.stringValue) }
        pending.append(contentsOf: axChildren(item))
        if let view = item as? NSView { pending.append(contentsOf: view.subviews) }
    }
    return labels
}

private func axString(_ object: NSObject, _ name: String) -> String? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    guard let value = object.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty else { return nil }
    return value
}

private func axChildren(_ object: NSObject) -> [NSObject] {
    let selector = NSSelectorFromString("accessibilityChildren")
    guard object.responds(to: selector) else { return [] }
    guard let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return [] }
    return children.compactMap { $0 as? NSObject }
}
