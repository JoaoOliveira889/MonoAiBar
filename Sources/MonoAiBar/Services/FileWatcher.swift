import Foundation

/// Monitors local CLI credential and session files using kernel file-system events (`DispatchSource`).
/// When a CLI runs in a terminal and touches its session file, MonoAiBar detects the change
/// within milliseconds and triggers a refresh with zero polling latency and zero idle CPU usage.
actor FileWatcher {
    static let shared = FileWatcher()

    private var sources: [any DispatchSourceFileSystemObject] = []
    private var debounceTasks: [ProviderType: Task<Void, Never>] = [:]
    private var onFileChange: (@Sendable (ProviderType) -> Void)?

    private init() {}

    func start(onFileChange: @escaping @Sendable (ProviderType) -> Void) {
        self.onFileChange = onFileChange
        stop()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let targets: [(ProviderType, URL)] = [
            (.claude, home.appending(path: ".claude")),
            (.codex, home.appending(path: ".codex")),
            (.antigravity, home.appending(path: ".gemini"))
        ]

        for (provider, folderURL) in targets {
            watch(directory: folderURL, provider: provider)
        }
    }

    func stop() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        for (_, task) in debounceTasks {
            task.cancel()
        }
        debounceTasks.removeAll()
    }

    private func watch(directory: URL, provider: ProviderType) {
        let path = directory.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.handleTrigger(for: provider)
            }
        }

        source.setCancelHandler {
            close(descriptor)
        }

        source.resume()
        sources.append(source)
    }

    private var lastTriggerTime: [ProviderType: Date] = [:]
    private let minimumReactiveInterval: TimeInterval = 30.0

    private func handleTrigger(for provider: ProviderType) {
        let now = Date()
        if let last = lastTriggerTime[provider], now.timeIntervalSince(last) < minimumReactiveInterval {
            return
        }

        debounceTasks[provider]?.cancel()
        debounceTasks[provider] = Task { [weak self] in
            // Debounce for 1.5s so multiple sequential file writes from a single CLI command coalesce
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.notifyFileChange(for: provider)
        }
    }

    private func notifyFileChange(for provider: ProviderType) {
        lastTriggerTime[provider] = Date()
        Log.quota.notice("file change detected for \(provider.id, privacy: .public); triggering reactive refresh")
        onFileChange?(provider)
    }
}
