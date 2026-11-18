import AppKit
import SwiftUI

@main
struct NightdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Held for the process lifetime. @State is a SwiftUI macro whose plugin
    // is not shipped with Command Line Tools, so the model lives here instead.
    private let model = AppModel.shared

    var body: some Scene {
        let menuBarExtra = model.menuBarExtra
        Window("Nightdeck", id: MainWindowID.value) {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 860, minHeight: 560)
                .background(alignment: .topLeading) {
                    MainWindowInstall()
                }
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            MainWindowCommands()
        }

        MenuBarExtra(
            "Nightdeck",
            systemImage: "music.note",
            isInserted: Binding(
                get: { menuBarExtra },
                set: { model.menuBarExtra = $0; model.saveSettings() }
            )
        ) {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The poller belongs to the process. Closing the window must not
        // drop the player or require a new connection when it is shown again.
        AppModel.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        NightdeckLifecycle.terminateAfterLastWindowClosed
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The menu-bar scene can make `flag` true while the main window is
        // closed or minimized. Show that window ourselves.
        _ = (sender, flag)
        MainWindowController.shared.reopen()
        return false
    }
}
