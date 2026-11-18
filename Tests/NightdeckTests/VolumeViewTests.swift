import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Nightdeck
@testable import NightdeckCore

@Suite(.serialized)
@MainActor
struct VolumeAndStopSetupTests {
    @Test func viewSetupSendsNoVolume() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        let labels = harness.labels()
        #expect(harness.model.status.title == "Track 1")
        #expect(harness.model.status.volume == 40)
        #expect(labels.filter { $0 == "Volume" }.count == 2, "labels: \(labels.joined(separator: " | "))")
        let paths = harness.mock.loggedPaths()
        #expect(paths.contains { commandPath($0) == "/Status" }, "paths: \(paths.joined(separator: " "))")
        #expect(!paths.contains { commandPath($0) == "/Volume" }, "paths: \(paths.joined(separator: " "))")
        #expect(!paths.contains { commandPath($0) == "/Stop" }, "paths: \(paths.joined(separator: " "))")
        #expect(!paths.contains { commandPath($0) == "/AddSlave" }, "paths: \(paths.joined(separator: " "))")
        #expect(!paths.contains { commandPath($0) == "/RemoveSlave" }, "paths: \(paths.joined(separator: " "))")
        #expect(harness.model.host == "127.0.0.1")
    }

    @Test func stopActionSendsStopAndViewSetupDoesNot() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        let before = harness.mock.loggedPaths()
        #expect(!before.contains { commandPath($0) == "/Stop" }, "paths: \(before.joined(separator: " "))")
        #expect(!before.contains { commandPath($0) == "/Volume" }, "paths: \(before.joined(separator: " "))")
        #expect(harness.labels().filter { $0 == "Volume" }.count == 2)
        harness.model.stopPlayback()
        harness.model.stopPlayback()
        let sawStop = await harness.waitFor({ commandPath($0) == "/Stop" })
        #expect(sawStop)
        try await Task.sleep(nanoseconds: 250_000_000)
        let paths = harness.mock.loggedPaths()
        #expect(paths.filter { commandPath($0) == "/Stop" }.count == 1, "paths: \(paths.joined(separator: " "))")
        #expect(!paths.contains { commandPath($0) == "/Volume" }, "paths: \(paths.joined(separator: " "))")
    }

    @Test func oneWheelNotchRaisesVolumeByOne() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        #expect(harness.volumePaths().isEmpty)
        let fader = try harness.mainFader()
        fader.scrollWheel(with: scrollEvent(lines: 1))
        try await Task.sleep(nanoseconds: 400_000_000)
        let volume = harness.volumePaths()
        #expect(volume.count == 1, "paths: \(volume.joined(separator: " "))")
        #expect(volume.first?.contains("level=41") == true, "paths: \(volume.joined(separator: " "))")
        #expect(harness.model.status.volume == 41)
    }

    @Test func fastWheelBurstDoesNotFloodVolume() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        let fader = try harness.mainFader()
        for _ in 0..<30 {
            fader.scrollWheel(with: scrollEvent(lines: 1))
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let volume = harness.volumePaths()
        #expect(!volume.isEmpty, "a burst still commits")
        #expect(volume.count <= 3, "paths: \(volume.joined(separator: " "))")
        #expect(volume.contains { $0.contains("level=70") }, "paths: \(volume.joined(separator: " "))")
        #expect(harness.model.status.volume == 70)
    }

    @Test func scrollAwayFromTheFaderDoesNotChangeVolume() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        let window = harness.nowWindow
        guard let root = window.contentView else { throw VolumeTestError.missing("window") }
        root.layoutSubtreeIfNeeded()
        let fader = try harness.mainFader()
        let faderFrame = fader.convert(fader.bounds, to: root)
        let point = NSPoint(x: 28, y: root.bounds.midY)
        #expect(!faderFrame.contains(point), "fader covers the cover column \(faderFrame)")
        let hit = root.hitTest(root.superview?.convert(point, from: root) ?? point)
        #expect(!(hit is VolumeHitView))
        let center = NSPoint(x: faderFrame.midX, y: faderFrame.midY)
        let onFader = root.hitTest(root.superview?.convert(center, from: root) ?? center)
        #expect(onFader is VolumeHitView, "fader center hit \(String(describing: onFader.map { type(of: $0) }))")
        (hit ?? root).scrollWheel(with: scrollEvent(lines: 4))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(harness.volumePaths().isEmpty)
        #expect(harness.model.status.volume == 40)
    }

    @Test func dragClickScrollAndKeysSendVolume() async throws {
        let harness = try await PlayerHarness.open()
        defer {
            VolumeHitView.clearSharedFlagBeforeEnd = false
            harness.close()
        }
        try await harness.settle()
        #expect(harness.volumePaths().isEmpty)
        #expect(harness.model.status.volume == 40)
        let fader = try harness.mainFader()
        let window = try #require(fader.window)

        VolumeHitView.clearSharedFlagBeforeEnd = true
        try gesture(on: fader, window: window, from: 0.8, to: 0.8, drag: false)
        VolumeHitView.clearSharedFlagBeforeEnd = false
        let clicked = await harness.waitFor { $0.contains("level=80") }
        #expect(clicked, "paths: \(harness.volumePaths())")
        #expect(await harness.waitUntilStatus { $0.volume == 80 })

        try gesture(on: fader, window: window, from: 0.8, to: 0.55, drag: true)
        let dragged = await harness.waitFor { $0.contains("level=55") }
        #expect(dragged, "paths: \(harness.volumePaths())")
        #expect(await harness.waitUntilStatus { $0.volume == 55 })
        try await harness.layout()

        fader.scrollWheel(with: scrollEvent(lines: 1))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(harness.volumePaths().contains { $0.contains("level=56") }, "paths: \(harness.volumePaths())")
        #expect(await harness.waitUntilStatus { $0.volume == 56 })

        fader.keyDown(with: try keyEvent(.upArrow, window: window))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(harness.volumePaths().contains { $0.contains("level=57") }, "paths: \(harness.volumePaths())")
        #expect(harness.model.status.volume == 57)
    }

    @Test func volumeFailureShowsOnTheStatusLine() async throws {
        let harness = try await PlayerHarness.open()
        defer { harness.close() }
        try await harness.settle()
        #expect(harness.model.status.volume == 40)
        let arm = URL(string: "http://127.0.0.1:\(harness.mock.port)/_x?volfail=1")!
        _ = try await URLSession.shared.data(from: arm)
        let fader = try harness.mainFader()
        let window = try #require(fader.window)
        fader.keyDown(with: try keyEvent(.upArrow, window: window))
        let saw = await harness.waitUntilStatus { _ in
            harness.model.notice?.contains("Volume failed") == true && harness.model.status.volume == 40
        }
        #expect(saw, "notice=\(harness.model.notice ?? "") error=\(harness.model.lastError ?? "") volume=\(harness.model.status.volume)")
        #expect(harness.model.lastError?.contains("volume refused") == true)
        #expect(harness.volumePaths().contains { $0.contains("level=41") }, "paths: \(harness.volumePaths())")
        #expect(harness.model.notice == "Volume failed: volume refused")
    }

    @Test func faderTopsTheTitleAndStaysInsideAShortWindow() async throws {
        let harness = try await PlayerHarness.open(now: NSSize(width: 1100, height: 740))
        defer { harness.close() }
        try await harness.settle()
        try await harness.layout()
        try assertFader(in: harness.nowWindow, minTrack: 180)

        // Tighter than the 860×560 window after the 180 pt sidebar and the 28 pt padding.
        harness.resizeNow(NSSize(width: 600, height: 440))
        try await harness.layout()
        try assertFader(in: harness.nowWindow, minTrack: 80)
    }
}

@Test func wheelNotchMapsToOneVolumeStep() {
    var scroll = VolumeScroll()
    let now = ContinuousClock.now
    scroll.note(deltaY: 1, precise: false, level: 40)
    #expect(scroll.take(now: now, flush: false) == 41)
    scroll.note(deltaY: -1, precise: false, level: 41)
    #expect(scroll.take(now: now.advanced(by: VolumeScroll.interval), flush: false) == 40)
}

@Test func preciseDeltasAccumulateToOneStep() {
    var scroll = VolumeScroll()
    let now = ContinuousClock.now
    scroll.note(deltaY: VolumeScroll.pointsPerStep - 1, precise: true, level: 40)
    #expect(scroll.take(now: now, flush: true) == nil)
    scroll.note(deltaY: 1, precise: true, level: 40)
    #expect(scroll.take(now: now, flush: true) == 41)
}

@Test func scrollClampsAndCoalescesABurst() {
    var up = VolumeScroll()
    let now = ContinuousClock.now
    up.note(deltaY: 8, precise: false, level: 97)
    #expect(up.take(now: now, flush: false) == 100)
    up.note(deltaY: 3, precise: false, level: 100)
    #expect(up.pending == nil)

    var down = VolumeScroll()
    down.note(deltaY: -9, precise: false, level: 4)
    #expect(down.take(now: now, flush: false) == 0)

    var burst = VolumeScroll()
    var sent: [Int] = []
    for _ in 0..<30 {
        burst.note(deltaY: 1, precise: false, level: sent.last ?? 40)
        if let next = burst.take(now: now, flush: false) {
            sent.append(next)
        }
    }
    #expect(sent == [41])
    #expect(burst.pending == 70)
    #expect(burst.take(now: now, flush: false) == nil)
    #expect(burst.take(now: now.advanced(by: VolumeScroll.interval), flush: false) == 70)
    #expect(burst.pending == nil)
}

@MainActor
struct PlayerHarness {
    let mock: MockServer
    let model: AppModel
    let windows: [NSWindow]
    let logURL: URL

    static func open(now size: NSSize = NSSize(width: 1100, height: 740)) async throws -> PlayerHarness {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nightdeck-\(UUID().uuidString).log")
        let mock = try await MockServer.launch(logURL: logURL)
        let model = AppModel()
        let ui = TransportUI.shared
        ui.adjustingVolume = false
        ui.seeking = false
        ui.volume = 0
        model.attachPreview(host: "127.0.0.1", port: mock.port)
        _ = NSApplication.shared
        let now = NSHostingView(rootView: NowPlayingView().environment(model).preferredColorScheme(.dark))
        let menu = NSHostingView(rootView: MenuBarView().environment(model).preferredColorScheme(.dark))
        let windows = [
            host(now, size: size),
            host(menu, size: NSSize(width: 340, height: 240)),
        ]
        return PlayerHarness(mock: mock, model: model, windows: windows, logURL: logURL)
    }

    var nowWindow: NSWindow { windows[0] }

    func volumePaths() -> [String] {
        mock.loggedPaths().filter { commandPath($0) == "/Volume" }
    }

    func mainFader() throws -> VolumeHitView {
        let found = windows.flatMap { findAll(VolumeHitView.self, in: $0.contentView) }
        guard let fader = found.max(by: { $0.bounds.height < $1.bounds.height }) else {
            throw VolumeTestError.missing("volume fader")
        }
        return fader
    }

    func layout() async throws {
        for _ in 0..<4 {
            for window in windows {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func resizeNow(_ size: NSSize) {
        guard let view = nowWindow.contentView else { return }
        nowWindow.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        nowWindow.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    func settle() async throws {
        let connected = await waitUntil(seconds: 4) { model.connected }
        #expect(connected)
        for _ in 0..<8 {
            for window in windows {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    func waitUntilStatus(_ match: @escaping (PlayerStatus) -> Bool) async -> Bool {
        await waitUntil(seconds: 3) { match(model.status) }
    }

    func waitFor(_ match: @escaping (String) -> Bool) async -> Bool {
        await waitUntil(seconds: 3) {
            mock.loggedPaths().contains(where: match)
        }
    }

    func labels() -> [String] {
        windows.flatMap { window in
            guard let view = window.contentView else { return [String]() }
            return accessibilityText(in: view)
        }
    }

    func close() {
        model.endPreview()
        mock.stop()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        try? FileManager.default.removeItem(at: logURL)
    }

    private static func host(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func waitUntil(seconds: Double, _ ready: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ready() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ready()
    }

    private func accessibilityText(in root: NSView) -> [String] {
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
}

func commandPath(_ line: String) -> String {
    guard let query = line.firstIndex(of: "?") else { return line }
    return String(line[..<query])
}

private enum VolumeTestError: Error, CustomStringConvertible {
    case missing(String)
    var description: String { "missing \(message)" }
    private var message: String {
        switch self {
        case .missing(let value): value
        }
    }
}

private func scrollEvent(lines: Int32) -> NSEvent {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
    return NSEvent(cgEvent: event!)!
}

@Test @MainActor func disconnectedVolumeIsReportedAndNotApplied() {
    let model = AppModel()
    model.setVolume(25)
    #expect(model.notice == "Volume was not sent")
    #expect(model.status.volume != 25)
}

@MainActor
private func gesture(on fader: VolumeHitView, window: NSWindow, from start: Double, to end: Double, drag: Bool) throws {
    let down = mouseEvent(type: .leftMouseDown, at: point(forFraction: start, on: fader), window: window)
    fader.mouseDown(with: down)
    if drag {
        let moved = mouseEvent(type: .leftMouseDragged, at: point(forFraction: (start + end) / 2, on: fader), window: window, number: 2)
        fader.mouseDragged(with: moved)
    }
    let up = mouseEvent(type: .leftMouseUp, at: point(forFraction: end, on: fader), window: window, number: 3)
    fader.mouseUp(with: up)
}

@MainActor
private func point(forFraction fraction: Double, on fader: VolumeHitView) -> NSPoint {
    let unit = fader.isFlipped ? 1 - fraction : fraction
    let local = NSPoint(x: fader.bounds.midX, y: fader.bounds.height * unit)
    return fader.convert(local, to: nil)
}

@MainActor
private func keyEvent(_ key: NSEvent.SpecialKey, window: NSWindow) throws -> NSEvent {
    let scalar = UnicodeScalar(UInt32(key.rawValue))!
    let chars = String(scalar)
    let code: UInt16
    if key == .downArrow { code = 125 }
    else if key == .rightArrow { code = 124 }
    else if key == .leftArrow { code = 123 }
    else { code = 126 }
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: chars,
        charactersIgnoringModifiers: chars,
        isARepeat: false,
        keyCode: code
    )
    return try #require(event)
}

@MainActor
func mouseEvent(type: NSEvent.EventType, at point: NSPoint, window: NSWindow, number: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: number,
        clickCount: 1,
        pressure: 1
    )!
}

@MainActor
private func assertFader(in window: NSWindow, minTrack: CGFloat) throws {
    guard let root = window.contentView else { throw VolumeTestError.missing("window") }
    root.layoutSubtreeIfNeeded()
    let faders = findAll(VolumeHitView.self, in: root)
    #expect(faders.count == 1)
    guard let fader = faders.first else { throw VolumeTestError.missing("fader") }
    let faderFrame = fader.convert(fader.bounds, to: root)
    #expect(fader.bounds.height >= minTrack, "track height \(fader.bounds.height) frame \(faderFrame)")
    #expect(fader.bounds.width >= 36, "hit width \(fader.bounds.width)")
    #expect(faderFrame.minX >= -1 && faderFrame.minY >= -1, "origin \(faderFrame)")
    #expect(faderFrame.maxX <= root.bounds.width + 1, "right \(faderFrame.maxX) of \(root.bounds.width)")
    #expect(faderFrame.maxY <= root.bounds.height + 1, "top \(faderFrame.maxY) of \(root.bounds.height)")
    #expect(faderFrame.midX > root.bounds.width * 0.62, "fader should sit on the right \(faderFrame)")
    let topInset = root.isFlipped ? faderFrame.minY : root.bounds.height - faderFrame.maxY
    #expect(topInset > 12 && topInset < 48, "fader top inset \(topInset) frame \(faderFrame)")
}

@MainActor
func findAll<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
    guard let root else { return [] }
    var found: [T] = []
    func walk(_ view: NSView) {
        if let match = view as? T { found.append(match) }
        for child in view.subviews { walk(child) }
    }
    walk(root)
    return found
}
