import Foundation
import Observation
import ServiceManagement

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case textAbove = "Stacked Text"
    case inlineText = "Single Line"
    case icons = "Icons"

    public var id: String { rawValue }
}

@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()

    private enum Key {
        static let refreshInterval = "monoaibar_refresh_interval"
        static let displayMode = "monoaibar_display_mode"
        static let enabledProviders = "monoaibar_enabled_providers"
        static let notificationsEnabled = "monoaibar_notifications_enabled"
        static let warningThreshold = "monoaibar_warning_threshold"
        static let lastWorkingAntigravityPort = "monoaibar_last_antigravity_port"

        static let legacyPrefix = "monobar_"
    }

    public let availableIntervals: [(label: String, seconds: TimeInterval)] = [
        ("1m", 60),
        ("5m", 300),
        ("15m", 900),
        ("30m", 1800)
    ]

    public var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = oldValue
                Log.system.error("launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    public var warningThreshold: Double {
        didSet { defaults.set(warningThreshold, forKey: Key.warningThreshold) }
    }

    public var refreshInterval: TimeInterval {
        didSet {
            guard refreshInterval != oldValue else { return }
            defaults.set(refreshInterval, forKey: Key.refreshInterval)
            QuotaManager.shared.refreshIntervalChanged(to: refreshInterval)
        }
    }

    public var displayMode: MenuBarDisplayMode {
        didSet {
            defaults.set(displayMode.rawValue, forKey: Key.displayMode)
            StatusItemController.shared.updateImage()
        }
    }

    public var enabledProviders: [ProviderType] {
        didSet {
            defaults.set(enabledProviders.map(\.id), forKey: Key.enabledProviders)
            StatusItemController.shared.updateImage()
        }
    }

    @ObservationIgnored
    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard

        // Migrate legacy settings if new settings don't exist yet
        let legacyMap: [(String, String)] = [
            ("monobar_notifications_enabled", Key.notificationsEnabled),
            ("monobar_warning_threshold", Key.warningThreshold),
            ("monobar_refresh_interval", Key.refreshInterval),
            ("monobar_display_mode", Key.displayMode),
            ("monobar_enabled_providers", Key.enabledProviders),
            ("monobar_last_antigravity_port", Key.lastWorkingAntigravityPort)
        ]
        for (oldKey, newKey) in legacyMap {
            if defaults.object(forKey: newKey) == nil, let val = defaults.object(forKey: oldKey) {
                defaults.set(val, forKey: newKey)
                defaults.removeObject(forKey: oldKey)
            }
        }

        launchAtLogin = SMAppService.mainApp.status == .enabled
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true

        let storedThreshold = defaults.double(forKey: Key.warningThreshold)
        warningThreshold = storedThreshold > 0 ? storedThreshold : 80.0

        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = storedInterval > 0 ? storedInterval : 300.0

        displayMode = defaults.string(forKey: Key.displayMode)
            .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .textAbove

        let storedProviders = (defaults.stringArray(forKey: Key.enabledProviders) ?? [])
            .compactMap { id in ProviderType.allCases.first { $0.id == id } }
        enabledProviders = storedProviders.isEmpty ? [.claude, .antigravity] : storedProviders
    }

    public func isProviderEnabled(_ provider: ProviderType) -> Bool {
        enabledProviders.contains(provider)
    }

    public func toggleProvider(_ provider: ProviderType) {
        if let index = enabledProviders.firstIndex(of: provider) {
            guard enabledProviders.count > 1 else { return }
            enabledProviders.remove(at: index)
        } else {
            enabledProviders.append(provider)
        }
    }
}

/// Antigravity's language server picks a fresh port per launch. The last working one is worth
/// remembering, and the services that need it run off the main actor.
enum AntigravityPortMemory {
    private static let key = "monoaibar_last_antigravity_port"
    private static let legacyKey = "monobar_last_antigravity_port"

    static var lastWorking: Int? {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            if stored > 0 { return stored }
            let legacy = UserDefaults.standard.integer(forKey: legacyKey)
            return legacy > 0 ? legacy : nil
        }
        set {
            if let newValue, (1024...65535).contains(newValue) {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
