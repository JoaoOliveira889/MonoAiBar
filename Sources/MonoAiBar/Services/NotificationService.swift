import Foundation
import UserNotifications

actor NotificationService {
    static let shared = NotificationService()

    private static let cooldown: TimeInterval = 3600

    private let center = UNUserNotificationCenter.current()
    private var lastNotified: [String: Date] = [:]

    private init() {}

    /// `false` means macOS is holding the notification back — either the user has never been asked
    /// or alerts are switched off for MonoAiBar in System Settings. Requesting again cannot change
    /// that, so the answer is surfaced in Settings instead of retried.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.system.notice(
                "notifications are switched off for this app: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func alertsAllowed() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
    }

    func notifyIfNeeded(statuses: [ProviderStatus], threshold: Double) async {
        let now = Date()

        for status in statuses {
            for window in status.windows where window.effectiveUsedPercent >= threshold {
                let key = trackingKey(status: status, window: window, threshold: threshold)

                if let previous = lastNotified[key], now.timeIntervalSince(previous) < Self.cooldown {
                    continue
                }
                lastNotified[key] = now
                await post(status: status, window: window)
            }
        }

        lastNotified = lastNotified.filter { now.timeIntervalSince($0.value) < Self.cooldown * 2 }
    }

    /// Keyed on the reset instant so a fresh window can alert again, but a single window cannot
    /// alert twice within the cooldown.
    private func trackingKey(status: ProviderStatus, window: QuotaWindow, threshold: Double) -> String {
        let reset = window.resetsAt.map { "\($0.timeIntervalSince1970)" }
            ?? window.resetAfterSeconds.map { "secs_\($0)" }
            ?? "continuous"
        return "\(status.provider.id)|\(window.name)|\(reset)|\(Int(threshold))"
    }

    private func post(status: ProviderStatus, window: QuotaWindow) async {
        let percent = Int(window.effectiveUsedPercent)
        let content = UNMutableNotificationContent()
        content.title = "\(status.provider.rawValue) near limit (\(percent)%)"
        content.body = "\(window.name) is at \(percent)%. \(window.formattedReset())."
        content.sound = .default
        content.interruptionLevel = .active

        let identifier = "monoaibar.warning.\(status.provider.id).\(window.name)"
        do {
            try await center.add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            Log.system.error("notification delivery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func notifyReset(status: ProviderStatus, window: QuotaWindow) async {
        let content = UNMutableNotificationContent()
        content.title = "\(status.provider.rawValue) quota renewed"
        content.body = "\(window.name) has reset and is back at 100% capacity."
        content.sound = .default
        content.interruptionLevel = .active

        let identifier = "monoaibar.reset.\(status.provider.id).\(window.name)"
        do {
            try await center.add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
            Log.quota.notice("delivered reset notification for \(status.provider.id, privacy: .public) - \(window.name, privacy: .public)")
        } catch {
            Log.system.error("reset notification delivery failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
