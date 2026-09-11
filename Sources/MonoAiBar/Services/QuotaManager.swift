import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class QuotaManager {
    public static let shared = QuotaManager()

    public private(set) var statuses: [ProviderType: ProviderStatus]
    public private(set) var isRefreshing = false
    public private(set) var lastRefreshed: Date?

    @ObservationIgnored
    private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored
    private var wakeDebounce: Task<Void, Never>?
    @ObservationIgnored
    private var interval: TimeInterval = 300.0
    @ObservationIgnored
    private var previousPeakByWindow: [String: Double] = [:]

    private static let staleAfter: TimeInterval = 20.0

    private init() {
        statuses = Dictionary(
            uniqueKeysWithValues: ProviderType.allCases.map { ($0, .initial(for: $0)) }
        )
        interval = 300.0
    }

    public func start() {
        interval = SettingsStore.shared.refreshInterval
        observeSleepAndWake()
        startRefreshLoop()
        startFileWatcher()
        Task { await refreshAll() }
    }

    private func startFileWatcher() {
        Task {
            await FileWatcher.shared.start { [weak self] provider in
                Task { @MainActor [weak self] in
                    await self?.refresh(provider: provider)
                }
            }
        }
    }

    public func status(for provider: ProviderType) -> ProviderStatus {
        statuses[provider] ?? .initial(for: provider)
    }

    public func usageText(for provider: ProviderType) -> String {
        let status = status(for: provider)
        if let percent = status.primaryUsagePercent {
            return "\(Int(percent))%"
        }
        if status.state.isError { return "!" }
        return status.state == .idle || status.state == .healthy ? "0%" : "--%"
    }

    /// Opening the panel should feel instant and should not fire a network round trip for data
    /// that is seconds old.
    public func refreshAllIfStale() async {
        if let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < Self.staleAfter { return }
        await refreshAll()
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let active = SettingsStore.shared.enabledProviders
        let fetched = await withTaskGroup(of: (ProviderType, ProviderStatus).self) { group in
            for provider in active {
                group.addTask { (provider, await Self.fetch(provider)) }
            }
            var results: [(ProviderType, ProviderStatus)] = []
            results.reserveCapacity(active.count)
            for await result in group {
                results.append(result)
            }
            return results
        }

        for (provider, status) in fetched {
            let resolved = retainingLastKnownGood(status, for: provider)
            statuses[provider] = resolved
            let windows = resolved.windows
                .map { "\($0.name)=\(Int($0.effectiveUsedPercent))%" }
                .joined(separator: ", ")
            Log.quota.info(
                "\(provider.id, privacy: .public): \(String(describing: resolved.state), privacy: .public) via \(resolved.authSource, privacy: .public) [\(windows, privacy: .public)]"
            )
            checkWindowResets(resolved: resolved)
        }
        lastRefreshed = Date()
        notifyIfNearLimit()
        StatusItemController.shared.updateImage()
    }

    public func refresh(provider: ProviderType) async {
        let status = await Self.fetch(provider)
        let resolved = retainingLastKnownGood(status, for: provider)
        statuses[provider] = resolved
        checkWindowResets(resolved: resolved)
        lastRefreshed = Date()
        notifyIfNearLimit()
        StatusItemController.shared.updateImage()
    }

    private func checkWindowResets(resolved: ProviderStatus) {
        guard SettingsStore.shared.notificationsEnabled else { return }
        for window in resolved.windows {
            let key = "\(resolved.provider.id)|\(window.name)"
            let current = window.effectiveUsedPercent
            if let previous = previousPeakByWindow[key], previous >= 65.0, current <= 15.0 {
                Task {
                    await NotificationService.shared.notifyReset(status: resolved, window: window)
                }
            }
            previousPeakByWindow[key] = current
        }
    }

    func refreshIntervalChanged(to newInterval: TimeInterval) {
        interval = newInterval
        startRefreshLoop()
    }

    private static func fetch(_ provider: ProviderType) async -> ProviderStatus {
        switch provider {
        case .claude: await ClaudeUsageService.shared.fetchUsage()
        case .antigravity: await AntigravityUsageService.shared.fetchUsage()
        case .codex: await CodexUsageService.shared.fetchUsage()
        }
    }

    private func notifyIfNearLimit() {
        let snapshot = Array(statuses.values)
        let threshold = SettingsStore.shared.warningThreshold
        guard SettingsStore.shared.notificationsEnabled else { return }
        Task { await NotificationService.shared.notifyIfNeeded(statuses: snapshot, threshold: threshold) }
    }

    /// A transient failure, rate limit (429), or idle startup should not blank out a working reading.
    /// Keep the previous windows and retain the last known values.
    private func retainingLastKnownGood(
        _ incoming: ProviderStatus,
        for provider: ProviderType
    ) -> ProviderStatus {
        guard incoming.windows.isEmpty,
              let previous = statuses[provider],
              !previous.windows.isEmpty else { return incoming }

        var cached = previous
        if incoming.state.isError {
            cached.state = .warning("Offline (Cached)")
        } else if case .warning(let reason) = incoming.state {
            cached.state = .warning("\(reason) (Cached)")
        }
        cached.errorMessage = incoming.errorMessage
        cached.actionSuggestion = incoming.actionSuggestion
        return cached
    }

    private func startRefreshLoop() {
        refreshLoop?.cancel()
        let period = Duration.seconds(max(interval, 30.0))
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: period, tolerance: period / 10)
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshLoop?.cancel()
                    self?.refreshLoop = nil
                }
            }
        }

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
        }

        // Auto-detect when Antigravity IDE or app opens or closes without needing app restart
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let name = (app?.localizedName ?? "").lowercased()
                let bundle = (app?.bundleIdentifier ?? "").lowercased()
                if name.contains("antigravity") || bundle.contains("antigravity") {
                    Task { @MainActor [weak self] in
                        // Allow RPC socket a brief moment to initialize
                        try? await Task.sleep(for: .seconds(2.0))
                        await self?.refresh(provider: .antigravity)
                    }
                }
            }
        }
    }

    /// Both wake notifications can arrive together, and the network stack needs a moment before
    /// loopback and TLS sockets behave.
    private func handleWake() {
        wakeDebounce?.cancel()
        startRefreshLoop()
        wakeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.refreshAll()
        }
    }
}
