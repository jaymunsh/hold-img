import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.applyDockPolicy()
        statusItem = StatusItemController()
        HotkeyManager.register()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
