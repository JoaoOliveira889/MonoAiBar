import Foundation

private struct QuotaSummaryResponse: Decodable {
    struct Payload: Decodable {
        struct Group: Decodable {
            struct Bucket: Decodable {
                let bucketId: String?
                let displayName: String?
                let window: String?
                let remainingFraction: Double?
                let resetTime: String?
            }

            let displayName: String?
            let buckets: [Bucket]?
        }

        let groups: [Group]?
    }

    let response: Payload?
}

private struct UserStatusResponse: Decodable {
    struct Status: Decodable {
        struct Tier: Decodable {
            let name: String?
        }
        struct Plan: Decodable {
            struct Info: Decodable {
                let planName: String?
            }
            let planInfo: Info?
        }

        let userTier: Tier?
        let planStatus: Plan?
    }

    let userStatus: Status?
}

actor AntigravityUsageService {
    static let shared = AntigravityUsageService()

    private struct Endpoint: Sendable {
        let port: Int
        let csrfToken: String?

        var baseURL: String { "http://127.0.0.1:\(port)" }
    }

    private static let quotaRPC = "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let statusRPC = "exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let executableFragments = ["Antigravity.app", "language_server"]
    private static let maximumProbes = 12
    private static let emptyBody = Data("{}".utf8)

    private let http = HTTPClient(timeout: 1.5, resourceTimeout: 2.5)
    private let decoder = JSONDecoder()

    private var lastWorkingPort: Int?
    private var lastServerPID: pid_t?

    func fetchUsage() async -> ProviderStatus {
        guard let server = locateServer() else {
            return offlineStatus(reason: "The Antigravity language server is not running.")
        }

        let csrfToken = server.value(forFlag: "--csrf_token")

        if let port = lastWorkingPort ?? AntigravityPortMemory.lastWorking,
           let status = await probe(Endpoint(port: port, csrfToken: csrfToken)) {
            remember(port)
            return status
        }

        for endpoint in candidateEndpoints(for: server, csrfToken: csrfToken) {
            if let status = await probe(endpoint) {
                remember(endpoint.port)
                return status
            }
        }

        return offlineStatus(reason: "No Antigravity RPC port answered on 127.0.0.1.")
    }

    /// Walking every PID and reading its arguments costs a `sysctl` per process. The last known
    /// PID is re-validated first, which is a single syscall on the common path.
    private func locateServer() -> ProcessInspector.Match? {
        if let pid = lastServerPID {
            if let match = ProcessInspector.languageServerMatch(pid: pid)
                ?? ProcessInspector.match(pid: pid, pathFragments: Self.executableFragments) {
                return match
            }
            lastServerPID = nil
            lastWorkingPort = nil
        }

        let found = ProcessInspector.findLanguageServer()
            ?? ProcessInspector.firstProcess(matchingPathFragments: Self.executableFragments)
        lastServerPID = found?.pid
        return found
    }

    /// The language server opens hundreds of loopback sockets, so scanning them is hopeless.
    /// `--client_port` or `--host_bridge_url` pins the allocation block, and the RPC port sits close by.
    private func candidateEndpoints(for server: ProcessInspector.Match, csrfToken: String?) -> [Endpoint] {
        let bridgePort = (server.value(forFlag: "--client_port").flatMap { Int($0) })
            ?? (server.value(forFlag: "--host_bridge_url").flatMap { URL(string: $0)?.port })

        var ordered: [Int] = []
        var seen: Set<Int> = []

        func append(_ port: Int) {
            guard (1024...65535).contains(port), seen.insert(port).inserted else { return }
            ordered.append(port)
        }

        if let bridgePort {
            for offset in [17, 18, 1, 2, 3, 4] {
                append(bridgePort + offset)
            }
        }

        let listening = ProcessInspector.listeningTCPPorts(of: server.pid)
        let byProximity = bridgePort.map { bridge in
            listening.sorted { abs($0 - bridge) < abs($1 - bridge) }
        } ?? listening.sorted()

        for port in byProximity {
            append(port)
        }

        return ordered.prefix(Self.maximumProbes).map { Endpoint(port: $0, csrfToken: csrfToken) }
    }

    private func probe(_ endpoint: Endpoint) async -> ProviderStatus? {
        guard let url = URL(string: "\(endpoint.baseURL)/\(Self.quotaRPC)") else { return nil }

        var request = URLRequest.postJSON(url, body: Self.emptyBody, timeout: 1.5)
        if let csrfToken = endpoint.csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }

        guard let (data, response) = try? await http.send(request),
              response.statusCode == 200,
              let groups = (try? decoder.decode(QuotaSummaryResponse.self, from: data))?.response?.groups,
              !groups.isEmpty else { return nil }

        var sessionWindows: [QuotaWindow] = []
        var weeklyWindows: [QuotaWindow] = []

        for group in groups {
            let groupName = group.displayName ?? "Models"
            for bucket in group.buckets ?? [] {
                guard let remaining = bucket.remainingFraction else { continue }

                let isWeekly = bucket.window == "weekly" || bucket.bucketId?.hasSuffix("weekly") == true
                let window = QuotaWindow(
                    name: Self.windowName(group: groupName, bucket: bucket, isWeekly: isWeekly),
                    usedPercent: (1.0 - remaining) * 100.0,
                    resetsAt: ISO8601.date(from: bucket.resetTime),
                    limitWindowSeconds: isWeekly ? 7 * 86_400 : 5 * 3600
                )

                if isWeekly {
                    weeklyWindows.append(window)
                } else if groupName.contains("Gemini") {
                    sessionWindows.insert(window, at: 0)
                } else {
                    sessionWindows.append(window)
                }
            }
        }

        var status = ProviderStatus(
            provider: .antigravity,
            state: .healthy,
            planName: await planName(for: endpoint),
            authSource: "Local RPC (127.0.0.1:\(endpoint.port))",
            windows: sessionWindows + weeklyWindows,
            lastUpdated: Date()
        )
        status.state = ProviderStatus.nearLimitState(peak: status.peakUsagePercent)
        return status
    }

    private static func windowName(
        group: String,
        bucket: QuotaSummaryResponse.Payload.Group.Bucket,
        isWeekly: Bool
    ) -> String {
        if group.contains("Gemini") {
            return isWeekly ? "Weekly Limits (Gemini)" : "Current Session (Gemini)"
        }
        if group.contains("Claude") || group.contains("GPT") {
            return isWeekly ? "Weekly Limits (Claude & GPT)" : "Current Session (Claude & GPT)"
        }
        return bucket.displayName ?? group
    }

    private func planName(for endpoint: Endpoint) async -> String {
        let fallback = "Google AI Pro"
        guard let url = URL(string: "\(endpoint.baseURL)/\(Self.statusRPC)") else { return fallback }

        var request = URLRequest.postJSON(url, body: Self.emptyBody, timeout: 1.5)
        if let csrfToken = endpoint.csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }

        guard let (data, response) = try? await http.send(request),
              response.statusCode == 200,
              let status = (try? decoder.decode(UserStatusResponse.self, from: data))?.userStatus else {
            return fallback
        }

        if let tier = status.userTier?.name, !tier.isEmpty { return tier }
        if let plan = status.planStatus?.planInfo?.planName, !plan.isEmpty { return plan }
        return fallback
    }

    private func remember(_ port: Int) {
        lastWorkingPort = port
        AntigravityPortMemory.lastWorking = port
    }

    private func offlineStatus(reason: String) -> ProviderStatus {
        lastWorkingPort = nil

        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".gemini/antigravity/antigravity_state.pbtxt")
        let everConfigured = FileManager.default.fileExists(atPath: stateFile.path(percentEncoded: false))

        return ProviderStatus(
            provider: .antigravity,
            state: everConfigured ? .idle : .notFound("Inactive"),
            planName: "Antigravity",
            authSource: "Local",
            errorMessage: reason,
            actionSuggestion: "Run `agy` in a terminal or open the Antigravity IDE.",
            lastUpdated: Date()
        )
    }
}
