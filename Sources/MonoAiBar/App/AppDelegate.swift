import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        StatusItemController.shared.setup()
        QuotaManager.shared.start()

        if SettingsStore.shared.notificationsEnabled {
            Task { await NotificationService.shared.requestAuthorization() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StatusItemController.shared.statusItemClicked()
        return true
    }
}
