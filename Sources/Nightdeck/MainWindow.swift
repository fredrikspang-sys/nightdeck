import AppKit
import SwiftUI

enum MainWindowID {
    /// One scene. `openWindow(id:)` focuses this window instead of making another.
    static let value = "main"
}

/// The app keeps running with the window closed so the player link stays up.
enum NightdeckLifecycle {
    static let terminateAfterLastWindowClosed = false
}

struct WindowRecord: Equatable {
    var identifier: String?
    var miniaturized: Bool
    var visible: Bool
}

struct MainWindowSnapshot: Equatable {
    var exists: Bool
    var miniaturized: Bool
    var visible: Bool
}

enum MainWindowReopenAction: Equatable {
    /// On screen already. Bring it forward.
    case orderFront
    /// In the Dock. `deminiaturize`, do not create a second window.
    case deminiaturize
    /// Closed, or still allocated but not visible. `openWindow` on the single scene.
    case create
}

enum MainWindowReopen {
    static func snapshot(of windows: [WindowRecord], id: String = MainWindowID.value) -> MainWindowSnapshot {
        guard let window = windows.first(where: { $0.identifier == id }) else {
            return MainWindowSnapshot(exists: false, miniaturized: false, visible: false)
        }
        let miniaturized = window.miniaturized
        return MainWindowSnapshot(
            exists: true,
            miniaturized: miniaturized,
            visible: window.visible && !miniaturized
        )
    }

    /// Dock click, the Window menu, and the menu-bar item share this.
    /// A visible window is only focused, so a repeat cannot open a second one.
    static func action(for window: MainWindowSnapshot) -> MainWindowReopenAction {
        guard window.exists else { return .create }
        if window.miniaturized { return .deminiaturize }
        if window.visible { return .orderFront }
        return .create
    }
}

enum WindowPlacement {
    /// A frame that only touches a screen (a line, or less than a point of overlap)
    /// is treated as off-screen. A real sliver still counts as on-screen.
    static func isOnScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let hit = frame.intersection(screen)
            return !hit.isNull && hit.width > 1 && hit.height > 1
        }
    }

    /// Nil when `frame` already meets a screen, or when there is nowhere to put it.
    /// Otherwise the same size, clamped to `main`, centered on that screen.
    static func correction(for frame: CGRect, screens: [CGRect], main: CGRect) -> CGRect? {
        guard main.width > 1, main.height > 1, !screens.isEmpty else { return nil }
        guard !isOnScreen(frame, screens: screens) else { return nil }
        let width = min(max(frame.width, 0), main.width)
        let height = min(max(frame.height, 0), main.height)
        return CGRect(
            x: main.midX - width / 2,
            y: main.midY - height / 2,
            width: width,
            height: height
        )
    }
}

/// Marker installed in the main window. SwiftUI's own window identifier is left alone.
final class MainWindowAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var openWindow: OpenWindowAction?
    private var correctionGeneration = 0

    func register(_ action: OpenWindowAction) {
        openWindow = action
    }

    /// Show the one main window and activate the app.
    /// The Dock has no view environment, so it uses the action captured from the
    /// main scene. A caller may pass one when that capture has not happened yet.
    func reopen(using action: OpenWindowAction? = nil) {
        if openWindow == nil { openWindow = action }
        let opener = openWindow ?? action
        let windows = NSApp.windows
        let window = Self.mainWindow(in: windows)
        let decision = MainWindowReopen.action(for: MainWindowReopen.snapshot(of: Self.records(for: windows)))
        NSApp.activate()
        switch decision {
        case .deminiaturize:
            guard let window else {
                showSingleScene(opener)
                return
            }
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            // The frame while miniaturized can be the Dock tile. Correct after restore.
            scheduleCorrection()
        case .orderFront:
            guard let window else { return }
            window.makeKeyAndOrderFront(nil)
            scheduleCorrection()
        case .create:
            showSingleScene(opener, existing: window)
        }
    }

    private func showSingleScene(_ opener: OpenWindowAction?, existing: NSWindow? = nil) {
        if let opener {
            opener(id: MainWindowID.value)
        } else {
            existing?.makeKeyAndOrderFront(nil)
        }
        scheduleCorrection()
    }

    static func records(for windows: [NSWindow]) -> [WindowRecord] {
        windows.map { window in
            WindowRecord(
                identifier: isMain(window) ? MainWindowID.value : window.identifier?.rawValue,
                miniaturized: window.isMiniaturized,
                visible: window.isVisible
            )
        }
    }

    static func mainWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first(where: isMain)
    }

    static func isMain(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == MainWindowID.value { return true }
        guard let content = window.contentView else { return false }
        return content.containsSubview(of: MainWindowAnchorView.self)
    }

    /// Move an off-screen window onto the menu-bar screen. A minimized window is
    /// left alone: its frame is not the restored frame.
    func scheduleCorrection() {
        correctionGeneration += 1
        let generation = correctionGeneration
        applyCorrectionIfReady()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard generation == self.correctionGeneration else { return }
            self.applyCorrectionIfReady()
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard generation == self.correctionGeneration else { return }
            self.applyCorrectionIfReady()
        }
    }

    private func applyCorrectionIfReady() {
        guard let window = Self.mainWindow(in: NSApp.windows), !window.isMiniaturized else { return }
        // SwiftUI can report a placeholder frame before the restored one arrives.
        // Recentering that would stick a tiny window in the middle of the screen.
        let current = window.frame
        guard current.width >= 64, current.height >= 64 else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main = NSScreen.screens.first?.visibleFrame ?? .zero
        guard let frame = WindowPlacement.correction(for: current, screens: screens, main: main) else { return }
        window.setFrame(frame, display: true)
    }
}

private extension NSView {
    func containsSubview(of type: NSView.Type) -> Bool {
        if isKind(of: type) { return true }
        return subviews.contains { $0.containsSubview(of: type) }
    }
}

struct MainWindowInstall: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowAnchor()
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                MainWindowController.shared.register(openWindow)
                MainWindowController.shared.scheduleCorrection()
            }
    }
}

private struct MainWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowAnchorView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Cmd-N would otherwise ask a window group for another window.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .windowArrangement) {
            Button("Nightdeck") {
                MainWindowController.shared.reopen(using: openWindow)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}

struct OpenNightdeckButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            MainWindowController.shared.reopen(using: openWindow)
        } label: {
            HStack {
                Text("Open Nightdeck")
                Spacer(minLength: 8)
                Text("⌘0")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
    }
}
