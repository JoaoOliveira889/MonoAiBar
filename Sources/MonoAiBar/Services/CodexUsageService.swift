import Foundation

private struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let access_token: String?
        let account_id: String?
    }

    let auth_mode: String?
    let OPENAI_API_KEY: String?
    let tokens: Tokens?
}

private struct CodexUsageResponse: Decodable {
    struct RateLimit: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int64?
            let reset_after_seconds: Int64?
            let reset_at: Int64?
        }

        let primary_window: Window?
    }

    let plan_type: String?
    let rate_limit: RateLimit?
}

actor CodexUsageService {
    static let shared = CodexUsageService()

    private struct Auth {
        let accessToken: String?
        let accountID: String?
        let apiKey: String?
        let planName: String
        let source: String
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let userAgent = "MonoAiBar/0.0.1"

    private let http = HTTPClient(timeout: 6.0, resourceTimeout: 8.0)
    private let decoder = JSONDecoder()

    func fetchUsage() async -> ProviderStatus {
        guard let auth = await loadAuth() else {
            return ProviderStatus(
                provider: .codex,
                state: .notFound("Not Found"),
                planName: "OpenAI Codex",
                authSource: "Missing",
                errorMessage: "No credentials at ~/.codex/auth.json and no key in Settings.",
                actionSuggestion: "Run `codex login` in a terminal to connect your account.",
                lastUpdated: Date()
            )
        }

        guard let token = auth.accessToken, !token.isEmpty else {
            guard let apiKey = auth.apiKey, !apiKey.isEmpty else {
                return ProviderStatus(
                    provider: .codex,
                    state: .notFound("No Token"),
                    planName: "OpenAI Codex",
                    authSource: auth.source,
                    errorMessage: "The configuration holds no usable access token.",
                    actionSuggestion: "Run `codex login` in a terminal to generate credentials.",
                    lastUpdated: Date()
                )
            }

            // API-key billing is usage-metered, not windowed, so there is no quota to report.
            return ProviderStatus(
                provider: .codex,
                state: .healthy,
                planName: "OpenAI (API Key)",
                authSource: auth.source,
                errorMessage: nil,
                actionSuggestion: "API key billing has no rate-limit window to track.",
                lastUpdated: Date()
            )
        }

        var request = URLRequest.get(Self.usageURL, timeout: 6.0)
        request.setBearer(token)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await http.send(request)

            switch response.statusCode {
            case 200:
                return decodeUsage(data, auth: auth)

            case 401, 403:
                return ProviderStatus(
                    provider: .codex,
                    state: .expired("Token Expired"),
                    planName: auth.planName,
                    authSource: auth.source,
                    errorMessage: errorMessage(from: data) ?? "Session expired.",
                    actionSuggestion: "Run `codex login` in a terminal to re-authenticate.",
                    lastUpdated: Date()
                )

            default:
                return ProviderStatus(
                    provider: .codex,
                    state: .error("HTTP \(response.statusCode)"),
                    planName: auth.planName,
                    authSource: auth.source,
                    errorMessage: "The quota endpoint returned HTTP \(response.statusCode).",
                    lastUpdated: Date()
                )
            }
        } catch {
            Log.quota.debug("codex usage request failed: \(error.localizedDescription, privacy: .public)")
            return ProviderStatus(
                provider: .codex,
                state: .error("Network Failure"),
                planName: auth.planName,
                authSource: auth.source,
                errorMessage: error.localizedDescription,
                lastUpdated: Date()
            )
        }
    }

    private func decodeUsage(_ data: Data, auth: Auth) -> ProviderStatus {
        guard let decoded = try? decoder.decode(CodexUsageResponse.self, from: data) else {
            return ProviderStatus(
                provider: .codex,
                state: .error("Unreadable Response"),
                planName: auth.planName,
                authSource: auth.source,
                errorMessage: "The usage payload did not match the expected shape.",
                lastUpdated: Date()
            )
        }

        var windows: [QuotaWindow] = []
        if let window = decoded.rate_limit?.primary_window, let usedPercent = window.used_percent {
            let resetsAt = (window.reset_at).flatMap { seconds in
                seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
            }
            windows.append(QuotaWindow(
                name: (window.limit_window_seconds ?? 0) >= 86_400 ? "Primary Window" : "Quota Window",
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                resetAfterSeconds: window.reset_after_seconds,
                limitWindowSeconds: window.limit_window_seconds
            ))
        }

        var status = ProviderStatus(
            provider: .codex,
            state: .healthy,
            planName: decoded.plan_type.map { "ChatGPT \($0.capitalized)" } ?? auth.planName,
            authSource: auth.source,
            windows: windows,
            accountDetail: auth.accountID.map { "ID: \($0.prefix(8))..." },
            lastUpdated: Date()
        )
        status.state = ProviderStatus.nearLimitState(peak: status.peakUsagePercent)
        return status
    }

    private func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["detail", "error"] {
            if let nested = root[key] as? [String: Any], let message = nested["message"] as? String {
                return message
            }
        }
        return nil
    }

    private func loadAuth() async -> Auth? {
        let settingsKey = await CredentialStore.shared.codexAPIKey()
        if !settingsKey.isEmpty {
            let looksLikeJWT = settingsKey.hasPrefix("ey")
            return Auth(
                accessToken: looksLikeJWT ? settingsKey : nil,
                accountID: nil,
                apiKey: looksLikeJWT ? nil : settingsKey,
                planName: looksLikeJWT ? "ChatGPT (Settings)" : "OpenAI (Settings)",
                source: "Settings"
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".codex/auth.json"),
            home.appending(path: ".config/codex/auth.json"),
            home.appending(path: ".config/openai/auth.json")
        ]

        for url in candidates {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let file = try? decoder.decode(CodexAuthFile.self, from: data) else { continue }
            return Auth(
                accessToken: file.tokens?.access_token,
                accountID: file.tokens?.account_id,
                apiKey: file.OPENAI_API_KEY,
                planName: file.auth_mode == "chatgpt" ? "ChatGPT" : (file.auth_mode ?? "OpenAI Account"),
                source: url.lastPathComponent
            )
        }

        let environment = ProcessInfo.processInfo.environment
        if let token = environment["CODEX_ACCESS_TOKEN"], !token.isEmpty {
            return Auth(
                accessToken: token,
                accountID: nil,
                apiKey: nil,
                planName: "ChatGPT (Env)",
                source: "$CODEX_ACCESS_TOKEN"
            )
        }
        if let key = environment["OPENAI_API_KEY"], !key.isEmpty {
            return Auth(
                accessToken: nil,
                accountID: nil,
                apiKey: key,
                planName: "OpenAI API Key",
                source: "$OPENAI_API_KEY"
            )
        }

        return nil
    }
}
