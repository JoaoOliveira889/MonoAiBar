import SwiftUI

struct ProviderQuotaCard: View {
    let status: ProviderStatus

    @State private var didCopyCommand = false

    private var peak: Double { status.primaryUsagePercent ?? status.peakUsagePercent }
    private var isHighUsage: Bool { peak >= 80.0 }
    private var isCritical: Bool { peak >= 90.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider().opacity(0.3)

            if !status.windows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(status.windows) { window in
                        MiniProgressBar(
                            title: window.name,
                            percent: window.effectiveUsedPercent,
                            resetText: window.formattedReset(),
                            accentColor: status.provider.accentColor
                        )
                    }
                }
            } else if status.state.isError || status.errorMessage != nil {
                diagnostics
            } else {
                Text(status.actionSuggestion ?? "Waiting for the first reading...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(status.authSource)
                Spacer()
                if let lastUpdated = status.lastUpdated {
                    Text(lastUpdated, format: .dateTime.hour().minute().second())
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(status.provider.shortCode.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(status.provider.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(status.provider.rawValue)
                        .font(.system(size: 12, weight: .semibold))

                    if let detail = status.accountDetail {
                        Text(detail)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                Text(status.planName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openTerminal()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Launch `\(status.provider.launchTerminalCommand)` in Terminal")

            if isHighUsage {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text(isCritical ? "CRITICAL" : "HIGH")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(Color.usageColor(for: peak))
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(Color.usageColor(for: peak).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Text(status.state.statusBadgeTitle)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(status.state.statusBadgeColor)
        }
    }

    private func openTerminal() {
        let cmd = status.provider.launchTerminalCommand
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(status.state.statusBadgeColor)

                Text(status.errorMessage ?? "Service unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let suggestion = status.actionSuggestion {
                Text(suggestion)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if suggestion.contains("`") {
                    copyCommandButton
                }
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.06))
        .clipShape(.rect(cornerRadius: 6))
    }

    private var copyCommandButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(status.provider.loginCommand, forType: .string)
            didCopyCommand = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                didCopyCommand = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                Text(didCopyCommand ? "Copied!" : "Copy `\(status.provider.loginCommand)`")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(status.provider.accentColor)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var borderColor: Color {
        isHighUsage ? Color.usageColor(for: peak).opacity(0.35) : Color.primary.opacity(0.08)
    }
}
