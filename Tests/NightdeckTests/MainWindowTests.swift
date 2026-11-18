import CoreGraphics
import Testing
@testable import Nightdeck

@Test func missingWindowIsCreated() {
    let closed = MainWindowSnapshot(exists: false, miniaturized: false, visible: false)
    #expect(MainWindowReopen.action(for: closed) == .create)
    #expect(MainWindowReopen.action(for: MainWindowReopen.snapshot(of: [])) == .create)
}

@Test func anotherWindowDoesNotStandInForMain() {
    let windows = [
        WindowRecord(identifier: "settings", miniaturized: false, visible: true),
        WindowRecord(identifier: nil, miniaturized: false, visible: false),
    ]
    #expect(MainWindowReopen.action(for: MainWindowReopen.snapshot(of: windows)) == .create)
}

@Test func minimizedWindowIsRestoredNotDuplicated() {
    let minimized = MainWindowSnapshot(exists: true, miniaturized: true, visible: false)
    #expect(MainWindowReopen.action(for: minimized) == .deminiaturize)
    let listed = [
        WindowRecord(identifier: "main", miniaturized: true, visible: false),
        WindowRecord(identifier: "settings", miniaturized: false, visible: true),
    ]
    #expect(MainWindowReopen.action(for: MainWindowReopen.snapshot(of: listed)) == .deminiaturize)
}

@Test func visibleWindowIsOnlyOrderedFront() {
    let visible = MainWindowSnapshot(exists: true, miniaturized: false, visible: true)
    #expect(MainWindowReopen.action(for: visible) == .orderFront)
    #expect(MainWindowReopen.action(for: visible) == .orderFront)
}

@Test func hiddenMainWindowUsesTheSingleScene() {
    let hidden = MainWindowSnapshot(exists: true, miniaturized: false, visible: false)
    #expect(MainWindowReopen.action(for: hidden) == .create)
}

@Test func appStaysRunningAfterTheLastWindowCloses() {
    #expect(NightdeckLifecycle.terminateAfterLastWindowClosed == false)
}

@Test func onScreenFramesStayPut() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let placed = CGRect(x: 200, y: 80, width: 1100, height: 740)
    let onSecondary = CGRect(x: -1500, y: 120, width: 800, height: 600)
    let sliver = CGRect(x: 1438, y: 40, width: 800, height: 600)
    #expect(WindowPlacement.correction(for: placed, screens: [main], main: main) == nil)
    #expect(WindowPlacement.correction(for: onSecondary, screens: [main, secondary], main: main) == nil)
    #expect(WindowPlacement.correction(for: sliver, screens: [main, secondary], main: main) == nil)
}

@Test func offScreenFrameIsCenteredOnTheMainScreen() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let gone = CGRect(x: 5000, y: -4000, width: 1100, height: 740)
    let fixed = WindowPlacement.correction(for: gone, screens: [main, secondary], main: main)
    #expect(fixed == CGRect(x: 170, y: 80, width: 1100, height: 740))
    #expect(WindowPlacement.correction(for: fixed!, screens: [main, secondary], main: main) == nil)
}

@Test func offScreenFrameAboveTheMenuBarIsCentered() {
    let main = CGRect(x: 100, y: 50, width: 1440, height: 900)
    let above = CGRect(x: 180, y: 5000, width: 800, height: 600)
    let fixed = WindowPlacement.correction(for: above, screens: [main], main: main)
    #expect(fixed == CGRect(x: 420, y: 200, width: 800, height: 600))
}

@Test func offScreenFrameLargerThanTheScreenIsClamped() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let huge = CGRect(x: -100, y: 4000, width: 3000, height: 400)
    let fixed = WindowPlacement.correction(for: huge, screens: [main], main: main)
    #expect(fixed == CGRect(x: 0, y: 250, width: 1440, height: 400))
}

@Test func touchingAScreenEdgeIsOffScreen() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let edge = CGRect(x: 1439.5, y: 0, width: 800, height: 600)
    #expect(WindowPlacement.isOnScreen(edge, screens: [main]) == false)
    let fixed = WindowPlacement.correction(for: edge, screens: [main], main: main)
    #expect(fixed == CGRect(x: 320, y: 150, width: 800, height: 600))
}

@Test func correctionDoesNothingWithoutAScreen() {
    let frame = CGRect(x: 9000, y: 9000, width: 800, height: 600)
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    #expect(WindowPlacement.correction(for: frame, screens: [], main: main) == nil)
    #expect(WindowPlacement.correction(for: frame, screens: [main], main: .zero) == nil)
    #expect(WindowPlacement.correction(for: frame, screens: [.zero], main: .zero) == nil)
}
