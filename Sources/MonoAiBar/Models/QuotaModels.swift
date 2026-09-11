import AppKit
import Foundation
import SwiftUI

public enum ProviderType: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude = "Anthropic Claude"
    case antigravity = "Google Antigravity"
    case codex = "OpenAI Codex"

    public var id: String {
        switch self {
        case .claude: "claude"
        case .antigravity: "antigravity"
        case .codex: "codex"
        }
    }

    public var shortCode: String {
        switch self {
        case .claude: "cld"
        case .antigravity: "agy"
        case .codex: "cod"
        }
    }

    public var loginCommand: String {
        switch self {
        case .claude: "claude"
        case .antigravity: "agy"
        case .codex: "codex login"
        }
    }

    @MainActor
    public var brandIcon: NSImage {
        switch self {
        case .claude: OfficialBrandIcons.claude
        case .antigravity: OfficialBrandIcons.antigravity
        case .codex: OfficialBrandIcons.codex
        }
    }

    public var accentColor: Color {
        switch self {
        case .claude: Color(red: 0.88, green: 0.44, blue: 0.26)
        case .antigravity: Color(red: 0.26, green: 0.54, blue: 0.96)
        case .codex: Color(red: 0.10, green: 0.65, blue: 0.55)
        }
    }

    public var launchTerminalCommand: String {
        switch self {
        case .claude: "claude"
        case .antigravity: "agy"
        case .codex: "codex"
        }
    }
}

public enum ProviderState: Equatable, Sendable {
    case idle
    case loading
    case healthy
    case warning(String)
    case expired(String)
    case error(String)
    case notFound(String)

    public var isError: Bool {
        switch self {
        case .expired, .error, .notFound: true
        default: false
        }
    }

    public var statusBadgeTitle: String {
        switch self {
        case .idle: "waiting"
        case .loading: "updating..."
        case .healthy: "ok"
        case .warning: "warning"
        case .expired: "expired"
        case .error: "error"
        case .notFound: "inactive"
        }
    }

    public var statusBadgeColor: Color {
        switch self {
        case .idle, .loading, .notFound: .secondary
        case .healthy: Color(red: 0.2, green: 0.8, blue: 0.4)
        case .warning: Color(red: 0.95, green: 0.65, blue: 0.2)
        case .expired, .error: Color(red: 0.95, green: 0.3, blue: 0.3)
        }
    }
}

public struct QuotaWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetAfterSeconds: Int64?
    public let limitWindowSeconds: Int64?

    public init(
        name: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        resetAfterSeconds: Int64? = nil,
        limitWindowSeconds: Int64? = nil
    ) {
        self.id = name
        self.name = name
        self.usedPercent = usedPercent.clamped(to: 0.0...100.0)
        self.resetsAt = resetsAt
        self.resetAfterSeconds = resetAfterSeconds
        self.limitWindowSeconds = limitWindowSeconds
    }

    /// A window whose reset instant has already passed reads as empty until the next refresh
    /// confirms the new figure.
    public var effectiveUsedPercent: Double {
        if let resetsAt, resetsAt <= Date() { return 0.0 }
        return usedPercent
    }

    public func formattedReset(now: Date = Date()) -> String {
        if let resetsAt {
            let remaining = resetsAt.timeIntervalSince(now)
            guard remaining > 0 else { return "Renewing now" }

            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60

            if hours >= 24 {
                return "Resets in \(hours / 24)d \(hours % 24)h"
            }
            let clock = resetsAt.formatted(date: .omitted, time: .shortened)
            return hours > 0
                ? "Resets in \(hours)h \(minutes)m (\(clock))"
                : "Resets in \(minutes)m (\(clock))"
        }

        if let resetAfterSeconds, resetAfterSeconds > 0 {
            let hours = resetAfterSeconds / 3600
            let minutes = (resetAfterSeconds % 3600) / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
        }

        return "Continuous reset"
    }
}

public struct ProviderStatus: Identifiable, Equatable, Sendable {
    public var id: String { provider.id }
    public let provider: ProviderType
    public var state: ProviderState
    public var planName: String
    public var authSource: String
    public var windows: [QuotaWindow]
    public var errorMessage: String?
    public var actionSuggestion: String?
    public var accountDetail: String?
    public var lastUpdated: Date?

    public init(
        provider: ProviderType,
        state: ProviderState = .idle,
        planName: String = "Unknown",
        authSource: String = "Automatic",
        windows: [QuotaWindow] = [],
        errorMessage: String? = nil,
        actionSuggestion: String? = nil,
        accountDetail: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.provider = provider
        self.state = state
        self.planName = planName
        self.authSource = authSource
        self.windows = windows
        self.errorMessage = errorMessage
        self.actionSuggestion = actionSuggestion
        self.accountDetail = accountDetail
        self.lastUpdated = lastUpdated
    }

    /// The session window is what the menu bar shows, falling back to the first reported window.
    public var primaryUsagePercent: Double? {
        let session = windows.first { window in
            window.limitWindowSeconds == 5 * 3600 || window.name.localizedCaseInsensitiveContains("session")
        }
        return (session ?? windows.first)?.effectiveUsedPercent
    }

    public var peakUsagePercent: Double {
        windows.map(\.effectiveUsedPercent).max() ?? 0.0
    }

    public static func initial(for provider: ProviderType) -> ProviderStatus {
        ProviderStatus(provider: provider, state: .idle, planName: "Checking...", authSource: "Local")
    }

    public static func nearLimitState(peak: Double) -> ProviderState {
        peak >= 90.0 ? .warning("Near Limit (\(Int(peak))%)") : .healthy
    }
}

public extension Color {
    static func usageColor(for percent: Double) -> Color {
        switch percent {
        case 90.0...: Color(red: 0.95, green: 0.3, blue: 0.3)
        case 70.0..<90.0: Color(red: 0.95, green: 0.65, blue: 0.2)
        default: Color(red: 0.2, green: 0.8, blue: 0.4)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

enum ISO8601 {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return (try? fractional.parse(string)) ?? (try? whole.parse(string))
    }
}
