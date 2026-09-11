import Foundation

private struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    let five_hour: Window?
    let seven_day: Window?
    let seven_day_sonnet: Window?
}

private struct OAuthRefreshRequest: Encodable {
    let grant_type = "refresh_token"
    let refresh_token: String
    let client_id: String
    let scope: String
}

private struct OAuthRefreshResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int64?
}

actor ClaudeUsageService {
    static let shared = ClaudeUsageService()

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let defaultScopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload"
    ]
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "MonoAiBar/0.0.2"

    private let http = HTTPClient(timeout: 6.0, resourceTimeout: 8.0)
    private let decoder = JSONDecoder()

    func fetchUsage() async -> ProviderStatus {
        guard var credential = await CredentialStore.shared.claudeCredential() else {
            return ProviderStatus(
                provider: .claude,
                state: .notFound("Credentials not found"),
                planName: "Claude Code",
                authSource: "Missing",
                errorMessage: "No Claude Code credentials in the macOS Keychain or ~/.claude.",
                actionSuggestion: "Run `claude` in a terminal to sign in.",
                lastUpdated: Date()
            )
        }

        if credential.isExpired, let refreshed = await refresh(credential) {
            credential = refreshed
        }

        return await requestUsage(with: credential, allowingRefresh: credential.refreshToken != nil)
    }

    private func requestUsage(with credential: ClaudeCredential, allowingRefresh: Bool) async -> ProviderStatus {
        var request = URLRequest.get(Self.usageURL, timeout: 6.0)
        request.setBearer(credential.accessToken)
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await http.send(request)

            switch response.statusCode {
            case 200:
                return decodeUsage(data, credential: credential)

            case 401, 403:
                if allowingRefresh, let refreshed = await refresh(credential) {
                    return await requestUsage(with: refreshed, allowingRefresh: false)
                }
                await CredentialStore.shared.invalidateClaudeCache()
                return ProviderStatus(
                    provider: .claude,
                    state: .expired("Session Expired"),
                    planName: credential.plan,
                    authSource: credential.sourceLabel,
                    errorMessage: "The OAuth token expired or was revoked.",
                    actionSuggestion: "Run `claude` in a terminal to sign in again.",
                    lastUpdated: Date()
                )

            case 429:
                if allowingRefresh, let refreshed = await refresh(credential) {
                    return await requestUsage(with: refreshed, allowingRefresh: false)
                }
                return ProviderStatus(
                    provider: .claude,
                    state: .warning("Rate Limit (429)"),
                    planName: credential.plan,
                    authSource: credential.sourceLabel,
                    errorMessage: "Anthropic is throttling quota lookups.",
                    actionSuggestion: "MonoAiBar will back off until the next refresh.",
                    accountDetail: credential.accountDetail,
                    lastUpdated: Date()
                )

            default:
                return ProviderStatus(
                    provider: .claude,
                    state: .error("HTTP \(response.statusCode)"),
                    planName: credential.plan,
                    authSource: credential.sourceLabel,
                    errorMessage: "Anthropic returned HTTP \(response.statusCode).",
                    lastUpdated: Date()
                )
            }
        } catch {
            Log.quota.debug("claude usage request failed: \(error.localizedDescription, privacy: .public)")
            return ProviderStatus(
                provider: .claude,
                state: .error("Network Failure"),
                planName: credential.plan,
                authSource: credential.sourceLabel,
                errorMessage: error.localizedDescription,
                lastUpdated: Date()
            )
        }
    }

    private func decodeUsage(_ data: Data, credential: ClaudeCredential) -> ProviderStatus {
        guard let decoded = try? decoder.decode(ClaudeUsageResponse.self, from: data) else {
            return ProviderStatus(
                provider: .claude,
                state: .error("Unreadable Response"),
                planName: credential.plan,
                authSource: credential.sourceLabel,
                errorMessage: "Anthropic's usage payload did not match the expected shape.",
                lastUpdated: Date()
            )
        }

        let windows = [
            ("Current Session", decoded.five_hour, Int64(5 * 3600)),
            ("Weekly Limits", decoded.seven_day, Int64(7 * 86_400)),
            ("Claude Sonnet (Weekly)", decoded.seven_day_sonnet, Int64(7 * 86_400))
        ].compactMap { name, window, span -> QuotaWindow? in
            guard let utilization = window?.utilization else { return nil }
            return QuotaWindow(
                name: name,
                usedPercent: utilization,
                resetsAt: ISO8601.date(from: window?.resets_at),
                limitWindowSeconds: span
            )
        }

        var status = ProviderStatus(
            provider: .claude,
            state: .healthy,
            planName: credential.plan,
            authSource: credential.sourceLabel,
            windows: windows,
            accountDetail: credential.accountDetail,
            lastUpdated: Date()
        )
        status.state = ProviderStatus.nearLimitState(peak: status.peakUsagePercent)
        return status
    }

    /// Rotates the OAuth pair and hands the result to `CredentialStore`, which writes it back into
    /// the very keychain item it was read from so Claude Code keeps working off the same tokens.
    private func refresh(_ credential: ClaudeCredential) async -> ClaudeCredential? {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else { return nil }

        let payload = OAuthRefreshRequest(
            refresh_token: refreshToken,
            client_id: credential.clientId ?? Self.clientID,
            scope: (credential.scopes ?? Self.defaultScopes).joined(separator: " ")
        )
        guard let body = try? JSONEncoder().encode(payload) else { return nil }

        var request = URLRequest.postJSON(Self.refreshURL, body: body, timeout: 10.0)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await http.send(request)
            guard response.statusCode == 200,
                  let decoded = try? decoder.decode(OAuthRefreshResponse.self, from: data) else {
                Log.credentials.notice("oauth refresh rejected with HTTP \(response.statusCode)")
                return nil
            }

            let expiresAt = Int64(Date().timeIntervalSince1970 * 1000)
                + (decoded.expires_in ?? 3600) * 1000

            return await CredentialStore.shared.persistRefreshedClaude(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token,
                expiresAtMilliseconds: expiresAt,
                previous: credential
            )
        } catch {
            Log.credentials.debug("oauth refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
