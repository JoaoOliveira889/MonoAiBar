import SwiftUI

struct SettingsView: View {
    let onClose: () -> Void

    @State private var settings = SettingsStore.shared
    @State private var credentialsExpanded = false
    @State private var customClaudeToken = ""
    @State private var codexAPIKey = ""
    @State private var syncMessage: String?
    @State private var didLoadSecrets = false
    @State private var alertsAllowed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    menuBarFormat
                    Divider()
                    refreshInterval
                    Divider()
                    providers
                    Divider()
                    systemPreferences
                    Divider()
                    credentials
                }
                .padding(12)
            }
            .frame(maxHeight: 480)
        }
        .task {
            guard !didLoadSecrets else { return }
            didLoadSecrets = true
            customClaudeToken = await CredentialStore.shared.customClaudeToken()
            codexAPIKey = await CredentialStore.shared.codexAPIKey()
            alertsAllowed = await NotificationService.shared.alertsAllowed()
        }
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Back")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Settings")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var menuBarFormat: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Menu Bar Format")

            HStack(spacing: 4) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    segment(
                        title: mode.rawValue,
                        isSelected: settings.displayMode == mode,
                        monospaced: false
                    ) {
                        settings.displayMode = mode
                    }
                }
            }
        }
    }

    private var refreshInterval: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                sectionTitle("Refresh Interval")
                Spacer()
                Text("\(Int(settings.refreshInterval / 60)) min")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(settings.availableIntervals, id: \.seconds) { interval in
                    segment(
                        title: interval.label,
                        isSelected: settings.refreshInterval == interval.seconds,
                        monospaced: true
                    ) {
                        settings.refreshInterval = interval.seconds
                    }
                }
            }
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Active AI Providers")
                Spacer()
                Text("Tap to toggle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.7))
            }

            VStack(spacing: 6) {
                ForEach(ProviderType.allCases) { provider in
                    providerRow(provider)
                }
            }
        }
    }

    private func providerRow(_ provider: ProviderType) -> some View {
        let isEnabled = settings.isProviderEnabled(provider)

        return Button {
            settings.toggleProvider(provider)
        } label: {
            HStack(spacing: 6) {
                BrandIcon(provider: provider, size: 13, tinted: isEnabled)

                Text(provider.shortCode.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isEnabled ? provider.accentColor : .secondary)

                Text(provider.rawValue)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.6)))
                    .lineLimit(1)

                Spacer()

                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(provider.accentColor) : AnyShapeStyle(.secondary.opacity(0.3)))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(isEnabled ? provider.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isEnabled ? provider.accentColor.opacity(0.35) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var systemPreferences: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("System & Preferences")

            VStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                )) {
                    toggleLabel("power", "Launch at Login")
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { isOn in
                        settings.notificationsEnabled = isOn
                        guard isOn else { return }
                        Task {
                            await NotificationService.shared.requestAuthorization()
                            alertsAllowed = await NotificationService.shared.alertsAllowed()
                        }
                    }
                )) {
                    toggleLabel("bell.badge", "Quota Notifications")
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if settings.notificationsEnabled && !alertsAllowed {
                    systemNotificationsDisabledNotice
                }

                if settings.notificationsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Warning Alert Threshold")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(settings.warningThreshold))%")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { settings.warningThreshold },
                                set: { settings.warningThreshold = $0 }
                            ),
                            in: 50...95,
                            step: 5
                        )
                        .controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.03))
            .clipShape(.rect(cornerRadius: 6))
        }
    }

    /// macOS delivers these notifications to the Notification Center either way, but without alert
    /// permission there is no banner and no sound — which reads as the feature being broken.
    private var systemNotificationsDisabledNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10))
                Text("Banners are turned off for MonoAiBar")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.2))

            Text("Alerts land in Notification Center but will not appear on screen until macOS is allowed to show them.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Text("Open Notification Settings")
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(.rect(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(red: 0.95, green: 0.65, blue: 0.2).opacity(0.10))
        .clipShape(.rect(cornerRadius: 6))
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Zero-Config CLI Connections")

            VStack(spacing: 6) {
                toolStatusRow(
                    name: "Claude Code CLI",
                    detail: "~/.claude/.credentials.json",
                    status: QuotaManager.shared.status(for: .claude)
                )

                toolStatusRow(
                    name: "Google Antigravity",
                    detail: "Local Language Server (127.0.0.1)",
                    status: QuotaManager.shared.status(for: .antigravity)
                )

                toolStatusRow(
                    name: "OpenAI Codex CLI",
                    detail: "~/.codex/auth.json",
                    status: QuotaManager.shared.status(for: .codex)
                )
            }

            HStack {
                Button {
                    Task {
                        _ = await CredentialStore.shared.resyncClaude()
                        await QuotaManager.shared.refreshAll()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                        Text("Re-scan Local Tools")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.top, 2)

            Divider().padding(.vertical, 4)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { credentialsExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9.5))
                    Text("Advanced: Manual Overrides")
                        .font(.system(size: 9.5, weight: .medium))
                    Spacer()
                    Image(systemName: credentialsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if credentialsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Manual tokens override auto-detected files. Leave empty for automatic zero-config.")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom Claude Token")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        SecureField("Optional OAuth or sk-ant-...", text: $customClaudeToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 9))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom Codex / OpenAI Key")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        SecureField("Optional sk-...", text: $codexAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 9))
                    }

                    Button(action: save) {
                        HStack {
                            Spacer()
                            Text("Save Custom Overrides")
                            Spacer()
                        }
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.vertical, 5)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private func toolStatusRow(name: String, detail: String, status: ProviderStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.state.statusBadgeColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(status.state.statusBadgeTitle)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(status.state.statusBadgeColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func save() {
        let claudeToken = customClaudeToken
        let codexKey = codexAPIKey
        Task {
            await CredentialStore.shared.setCustomClaudeToken(claudeToken)
            await CredentialStore.shared.setCodexAPIKey(codexKey)
            await QuotaManager.shared.refreshAll()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func toggleLabel(_ symbol: String, _ title: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
            Spacer()
        }
    }

    private func segment(
        title: String,
        isSelected: Bool,
        monospaced: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(
                    size: 10,
                    weight: isSelected ? .bold : .regular,
                    design: monospaced ? .monospaced : .default
                ))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
