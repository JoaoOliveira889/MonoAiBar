import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfDuplicateInstance() else { return }

        NSApp.setActivationPolicy(.accessory)
        StatusItemController.shared.setup()
        QuotaManager.shared.start()

        if SettingsStore.shared.notificationsEnabled {
            Task { await NotificationService.shared.requestAuthorization() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StatusItemController.shared.showPopover()
        return true
    }

    /// A second copy would install a second status item, so every click would appear to open the
    /// panel twice. The newer process steps aside and hands focus back to the one already running.
    private func terminateIfDuplicateInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ownPID
        }
        guard let existing = others.first else { return false }

        Log.system.notice("another MonoAiBar instance is running; terminating this one")
        existing.activate()
        NSApp.terminate(nil)
        return true
    }
}
