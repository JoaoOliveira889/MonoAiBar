import SwiftUI

struct PopoverContentView: View {
    static let width: CGFloat = 340

    private let quotaManager = QuotaManager.shared
    private let settings = SettingsStore.shared

    enum TabSelection: Hashable {
        case all
        case provider(ProviderType)
    }

    @State private var showingSettings = false
    @State private var selectedTab: TabSelection = .all

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "v\(version ?? "0.0.1")"
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingSettings {
                SettingsView { showingSettings = false }
            } else {
                quotaPanel
            }
        }
        .frame(width: Self.width)
    }

    private var activeProviders: [ProviderType] {
        settings.enabledProviders.isEmpty ? [.claude] : settings.enabledProviders
    }

    private var quotaPanel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            providerTabs
            Divider().opacity(0.3)

            Group {
                switch selectedTab {
                case .all:
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(activeProviders) { provider in
                                ProviderQuotaCard(status: quotaManager.status(for: provider))
                                    .id(provider)
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 400)

                case .provider(let provider):
                    let target = activeProviders.contains(provider) ? provider : (activeProviders.first ?? .claude)
                    ProviderQuotaCard(status: quotaManager.status(for: target))
                        .id(target)
                        .padding(10)
                }
            }

            Divider().opacity(0.3)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(healthColor)
                .frame(width: 6, height: 6)
                .animation(.easeInOut(duration: 0.2), value: healthColor)

            Text("MonoAiBar")
                .font(.system(size: 12, weight: .bold, design: .monospaced))

            Text(appVersion)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            Spacer()

            Button {
                Task { await quotaManager.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.rotate, options: .repeating, isActive: quotaManager.isRefreshing)
            }
            .buttonStyle(.plain)
            .help("Refresh quotas now")
            .disabled(quotaManager.isRefreshing)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var providerTabs: some View {
        HStack(spacing: 4) {
            allTabButton

            ForEach(activeProviders) { provider in
                providerTab(provider)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    private var allTabButton: some View {
        let isSelected = selectedTab == .all

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .all }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .medium))
                Text("ALL")
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .monospaced))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.2) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func providerTab(_ provider: ProviderType) -> some View {
        let isSelected = selectedTab == .provider(provider)
        let percent = quotaManager.status(for: provider).primaryUsagePercent

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .provider(provider) }
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: provider.brandIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)

                Text(provider.shortCode.uppercased())
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .monospaced))

                Text(percent.map { "\(Int($0))%" } ?? "--%")
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? provider.accentColor : .secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? provider.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            if let lastRefreshed = quotaManager.lastRefreshed {
                Text(lastRefreshed, format: .relative(presentation: .numeric))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Settings") { showingSettings = true }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text("·")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.5))

            Button("Quit") {
                StatusItemController.shared.closePopover()
                NSApplication.shared.terminate(nil)
                exit(0)
            }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private var healthColor: Color {
        let statuses = settings.enabledProviders.map { quotaManager.status(for: $0) }

        if statuses.contains(where: \.state.isError) {
            return Color(red: 0.95, green: 0.3, blue: 0.3)
        }
        let needsAttention = statuses.contains { status in
            if case .warning = status.state { return true }
            return status.peakUsagePercent >= 80.0
        }
        return needsAttention
            ? Color(red: 0.95, green: 0.65, blue: 0.2)
            : Color(red: 0.2, green: 0.8, blue: 0.4)
    }
}
