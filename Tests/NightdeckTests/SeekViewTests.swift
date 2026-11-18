import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Nightdeck
@testable import NightdeckCore

@Test func seekLatchHoldsAStalePollAndAcceptsTheDrop() {
    let asked = Date(timeIntervalSince1970: 1_000)
    let latch = SeekLatch(target: 100, anchor: 12, askedAt: asked, until: asked.addingTimeInterval(8))
    #expect(!latch.confirms(12, now: asked))
    #expect(!latch.confirms(14, now: asked.addingTimeInterval(2)))
    #expect(latch.confirms(100, now: asked))
    #expect(latch.confirms(103, now: asked.addingTimeInterval(3)))
    #expect(!latch.confirms(80, now: asked.addingTimeInterval(1)))
}

@Test func seekLatchDoesNotTreatTheOldSecondAsAShortSeek() {
    let asked = Date(timeIntervalSince1970: 1_000)
    let latch = SeekLatch(target: 42, anchor: 40, askedAt: asked, until: asked.addingTimeInterval(8))
    #expect(!latch.confirms(40, now: asked))
    #expect(!latch.confirms(41, now: asked.addingTimeInterval(1)))
    #expect(latch.confirms(42, now: asked))
    #expect(latch.confirms(43, now: asked.addingTimeInterval(1)))
}

extension VolumeAndStopSetupTests {
    @Test func dragMovesThePlayheadBeforeReleaseAndSeeksThere() async throws {
        let harness = try await PlayerHarness.open()
        defer {
            SeekHitView.clearSharedFlagBeforeEnd = false
            harness.close()
        }
        try await harness.settle()
        #expect(harness.model.status.seekable)
        #expect(harness.model.status.total == 200)
        #expect(harness.seekPaths().isEmpty, "opening the screen must not seek: \(harness.seekPaths())")
        let bar = try seekBar(in: harness.nowWindow)
        #expect(bar.bounds.height >= 28, "track hit \(bar.bounds)")
        #expect(bar.bounds.width >= 200, "track width \(bar.bounds)")
        let window = try #require(bar.window)

        // The old slider ignored this sample: seeking was still false, so the knob never moved.
        bar.mouseDown(with: mouseEvent(type: .leftMouseDown, at: seekPoint(0.5, on: bar), window: window))
        // The old slider dropped this sample: its setter ignored the drag until seeking
        // was already true, and a clock rebuild could clear the gesture before mouse-up.
        #expect(TransportUI.shared.seeking)
        #expect(abs(TransportUI.shared.seek - 100) < 1, "knob \(TransportUI.shared.seek)")
        #expect(bar.toolTip?.contains("Seek position") == true, "tip \(bar.toolTip ?? "")")
        #expect(bar.toolTip?.contains("1:40") == true, "tip \(bar.toolTip ?? "")")
        #expect(harness.seekPaths().isEmpty, "seek waits for mouse-up: \(harness.seekPaths())")
        SeekHitView.clearSharedFlagBeforeEnd = true
        bar.mouseUp(with: mouseEvent(type: .leftMouseUp, at: seekPoint(0.5, on: bar), window: window, number: 2))
        let sent = await harness.waitFor { $0.contains("seek=100") }
        #expect(sent, "paths: \(harness.seekPaths())")
        #expect(harness.seekPaths().count == 1, "paths: \(harness.seekPaths())")
        #expect(harness.model.status.seconds == 100)
        let player = try await playerSeconds(harness)
        #expect(player >= 100 && player < 110, "player secs \(player)")

        let heldAt = harness.model.status.receivedAt
        let polls = harness.mock.loggedPaths().filter { $0.hasPrefix("/Status") }.count
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?reportsec=4")!)
        let stale = await harness.waitUntilLogged { paths in
            paths.filter { $0.hasPrefix("/Status") }.count > polls
        }
        #expect(stale, "stale status did not return")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(harness.model.status.seconds == 100, "stale poll rewound to \(harness.model.status.seconds)")
        #expect(harness.model.status.receivedAt == heldAt)

        let beforeWake = harness.mock.loggedPaths().filter { $0.hasPrefix("/Status") }.count
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?wake=1")!)
        let confirmed = await harness.waitUntilStatus { $0.receivedAt > heldAt }
        #expect(confirmed, "status did not confirm the seek")
        #expect(harness.mock.loggedPaths().filter { $0.hasPrefix("/Status") }.count > beforeWake)
        #expect(harness.model.status.seconds >= 98 && harness.model.status.seconds < 120, "seconds \(harness.model.status.seconds)")
        #expect(harness.volumePaths().isEmpty)
    }

    @Test func clickOnTheTrackSeeksThere() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        let bar = try seekBar(in: harness.nowWindow)
        let window = try #require(bar.window)
        bar.mouseDown(with: mouseEvent(type: .leftMouseDown, at: seekPoint(0.25, on: bar), window: window))
        #expect(abs(TransportUI.shared.seek - 50) < 1)
        bar.mouseUp(with: mouseEvent(type: .leftMouseUp, at: seekPoint(0.25, on: bar), window: window, number: 2))
        let sent = await harness.waitFor { $0.contains("seek=50") }
        #expect(sent, "paths: \(harness.seekPaths())")
        #expect(harness.model.status.seconds == 50)
        #expect(try await playerSeconds(harness) >= 50)
    }

    @Test func unseekableStreamShowsAHintAndDoesNotSeek() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?totlen=0&canseek=0")!)
        let quiet = await harness.waitUntilStatus { $0.total == 0 && !$0.canSeek }
        #expect(quiet)
        #expect(!harness.model.status.seekable)
        try await harness.layout()
        let bar = try seekBar(in: harness.nowWindow)
        #expect(bar.toolTip == "Can't seek this stream", "tip \(bar.toolTip ?? "")")
        let window = try #require(bar.window)
        let before = harness.seekPaths().count
        bar.mouseDown(with: mouseEvent(type: .leftMouseDown, at: seekPoint(0.5, on: bar), window: window))
        bar.mouseUp(with: mouseEvent(type: .leftMouseUp, at: seekPoint(0.5, on: bar), window: window, number: 2))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.seekPaths().count == before, "paths: \(harness.seekPaths())")
        #expect(!TransportUI.shared.seeking)
    }

    @Test func canSeekFalseDisablesTheScrubber() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?canseek=0")!)
        let disabled = await harness.waitUntilStatus { $0.total == 200 && !$0.canSeek }
        #expect(disabled)
        #expect(!harness.model.status.seekable)
        try await harness.layout()
        let bar = try seekBar(in: harness.nowWindow)
        #expect(bar.toolTip == "Can't seek this stream", "tip \(bar.toolTip ?? "")")
        let window = try #require(bar.window)
        bar.mouseDown(with: mouseEvent(type: .leftMouseDown, at: seekPoint(0.8, on: bar), window: window))
        bar.mouseUp(with: mouseEvent(type: .leftMouseUp, at: seekPoint(0.8, on: bar), window: window, number: 2))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(harness.seekPaths().isEmpty, "paths: \(harness.seekPaths())")
    }

    @Test func seekFailureShowsOnTheStatusLine() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        let before = harness.model.status.seconds
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?seekfail=1")!)
        let bar = try seekBar(in: harness.nowWindow)
        let window = try #require(bar.window)
        bar.mouseDown(with: mouseEvent(type: .leftMouseDown, at: seekPoint(0.5, on: bar), window: window))
        bar.mouseUp(with: mouseEvent(type: .leftMouseUp, at: seekPoint(0.5, on: bar), window: window, number: 2))
        let failed = await harness.waitUntilStatus { _ in
            harness.model.notice?.contains("Seek failed") == true && harness.model.status.seconds != 100
        }
        #expect(failed, "notice=\(harness.model.notice ?? "") error=\(harness.model.lastError ?? "") seconds=\(harness.model.status.seconds)")
        #expect(harness.model.notice == "Seek failed: seek refused")
        #expect(harness.model.lastError == "seek refused")
        #expect(harness.model.status.seconds == before || harness.model.status.seconds < 30)
        #expect(harness.seekPaths().contains { $0.contains("seek=100") })
        let player = try await playerSeconds(harness)
        #expect(player < 30, "player moved to \(player)")
    }
}

extension PlayerHarness {
    func seekPaths() -> [String] {
        mock.loggedPaths().filter { path in
            let head = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
            return head == "/Play" && path.contains("seek=")
        }
    }

    func waitUntilLogged(_ match: @escaping @MainActor ([String]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if match(mock.loggedPaths()) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return match(mock.loggedPaths())
    }
}

@MainActor
private func seekBar(in window: NSWindow) throws -> SeekHitView {
    window.contentView?.layoutSubtreeIfNeeded()
    let found = findAll(SeekHitView.self, in: window.contentView)
    guard let bar = found.first else { throw SeekTestError.missingBar }
    return bar
}

@MainActor
private func seekPoint(_ fraction: Double, on bar: SeekHitView) -> NSPoint {
    let local = NSPoint(x: bar.bounds.width * fraction, y: bar.bounds.midY)
    return bar.convert(local, to: nil)
}

@MainActor
private func playerSeconds(_ harness: PlayerHarness) async throws -> Int {
    let url = URL(string: "http://127.0.0.1:\(harness.mock.port)/Status")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let xml = String(decoding: data, as: UTF8.self)
    guard let status = BluOSXML.parseStatus(xml) else { throw SeekTestError.missingBar }
    return status.seconds
}

private enum SeekTestError: Error {
    case missingBar
}
