import Foundation

struct ClaudeCredential: Sendable {
    enum Origin: Sendable, Equatable {
        case monoAiBarKeychain
        case userSuppliedToken
        case file(URL)
        case environment(String)
    }

    let accessToken: String
    let refreshToken: String?
    let expiresAtMilliseconds: Int64?
    let plan: String
    let sourceLabel: String
    let scopes: [String]?
    let clientId: String?
    let origin: Origin
    let rawJSON: Data?
    let accountDetail: String?

    init(
        accessToken: String,
        refreshToken: String?,
        expiresAtMilliseconds: Int64?,
        plan: String,
        sourceLabel: String,
        scopes: [String]?,
        clientId: String?,
        origin: Origin,
        rawJSON: Data?,
        accountDetail: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.plan = plan
        self.sourceLabel = sourceLabel
        self.scopes = scopes
        self.clientId = clientId
        self.origin = origin
        self.rawJSON = rawJSON
        self.accountDetail = accountDetail
    }

    var isExpired: Bool {
        guard let expiresAtMilliseconds else { return false }
        return expiresAtMilliseconds <= Int64(Date().timeIntervalSince1970 * 1000)
    }
}

actor CredentialStore {
    static let shared = CredentialStore()

    enum Service {
        static let claudeCache = "com.joaooliveira889.monoaibar.claude"
        static let customClaudeToken = "com.joaooliveira889.monoaibar.claude.custom"
        static let codexAPIKey = "com.joaooliveira889.monoaibar.codex"
    }

    private static let account = NSUserName()

    private static var claudeCredentialsFile: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "MonoAiBar", directoryHint: .isDirectory)
            .appending(path: "claude_credentials.json")
    }

    private var cachedClaude: ClaudeCredential?
    private var didMigrateLegacyStorage = false

    private init() {}

    private func saveToLocalFile(text: String) {
        guard let url = Self.claudeCredentialsFile, let data = text.data(using: .utf8) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path(percentEncoded: false)
        )
        writeProtected(data, to: url)
    }

    /// Refuses to follow a symlink: an attacker who can create one inside the target directory
    /// would otherwise redirect an OAuth payload to a path of their choosing.
    private func writeProtected(_ data: Data, to url: URL) {
        let path = url.path(percentEncoded: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let type = attributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            Log.credentials.error("refusing to write credentials through a symlink at \(url.lastPathComponent, privacy: .public)")
            return
        }

        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            Log.credentials.error("credential write failed for \(url.lastPathComponent, privacy: .public)")
        }
    }

    private func claudeCredentialFromLocalFile() -> ClaudeCredential? {
        guard let url = Self.claudeCredentialsFile,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(secret: text, sourceLabel: "MonoAiBar Cache", origin: .file(url))
    }

    // MARK: - Claude

    /// Returns the freshest Claude credential available, preferring a token the user typed in
    /// Settings, then whichever stored payload expires latest.
    func claudeCredential() -> ClaudeCredential? {
        migrateLegacyStorageIfNeeded()

        if let cachedClaude, !cachedClaude.isExpired {
            return cachedClaude
        }

        if let userSupplied = userSuppliedClaudeCredential() {
            cachedClaude = userSupplied
            return userSupplied
        }

        if let cachedClaude, cachedClaude.refreshToken != nil {
            return cachedClaude
        }

        let candidates = discoverClaudeCredentials()
        let freshest = candidates.max { lhs, rhs in
            (lhs.expiresAtMilliseconds ?? 0) < (rhs.expiresAtMilliseconds ?? 0)
        }
        cachedClaude = freshest
        return freshest
    }

    /// Persists a refreshed OAuth payload back into the same keychain item it came from, so
    /// MonoAiBar and Claude Code keep sharing one authoritative token and refresh-token rotation
    /// stays consistent. Read-only origins (files, environment) fall back to MonoAiBar's own item.
    func persistRefreshedClaude(
        accessToken: String,
        refreshToken: String?,
        expiresAtMilliseconds: Int64,
        previous: ClaudeCredential
    ) -> ClaudeCredential {
        let merged = mergedPayload(
            base: previous.rawJSON,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMilliseconds: expiresAtMilliseconds,
            scopes: previous.scopes,
            clientId: previous.clientId
        )

        // 1. MonoAiBar's own private store, which never triggers a keychain prompt on read.
        saveToLocalFile(text: merged.text)
        Keychain.write(service: Service.claudeCache, account: Self.account, secret: merged.text)

        // 2. Whichever CLI file the payload came from, plus the standard path, so the CLI and the
        //    app keep sharing one rotating refresh token. Files that do not already exist are left
        //    alone rather than created.
        var targets: [URL] = []
        if case .file(let url) = previous.origin, url != Self.claudeCredentialsFile {
            targets.append(url)
        }
        let standardClaudeFile = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json")
        if !targets.contains(standardClaudeFile) {
            targets.append(standardClaudeFile)
        }
        for url in targets
        where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            writeProtected(merged.data, to: url)
        }


        let refreshed = ClaudeCredential(
            accessToken: accessToken,
            refreshToken: refreshToken ?? previous.refreshToken,
            expiresAtMilliseconds: expiresAtMilliseconds,
            plan: previous.plan,
            sourceLabel: "MonoAiBar Cache",
            scopes: previous.scopes,
            clientId: previous.clientId,
            origin: .monoAiBarKeychain,
            rawJSON: merged.data,
            accountDetail: previous.accountDetail
        )
        cachedClaude = refreshed
        return refreshed
    }

    func invalidateClaudeCache() {
        cachedClaude = nil
    }

    func customClaudeToken() -> String {
        Keychain.read(service: Service.customClaudeToken)?.secret ?? ""
    }

    func setCustomClaudeToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(service: Service.customClaudeToken)
        } else {
            Keychain.write(service: Service.customClaudeToken, account: Self.account, secret: trimmed)
        }
        cachedClaude = nil
    }

    /// Imports whatever Claude Code has stored right now, so the popover can show a result without
    /// waiting for the next refresh tick.
    func resyncClaude() -> Bool {
        cachedClaude = nil
        return claudeCredential() != nil
    }

    // MARK: - Codex

    func codexAPIKey() -> String {
        migrateLegacyStorageIfNeeded()
        return Keychain.read(service: Service.codexAPIKey)?.secret ?? ""
    }

    func setCodexAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(service: Service.codexAPIKey)
        } else {
            Keychain.write(service: Service.codexAPIKey, account: Self.account, secret: trimmed)
        }
    }

    // MARK: - Discovery

    private func userSuppliedClaudeCredential() -> ClaudeCredential? {
        let token = customClaudeToken()
        guard !token.isEmpty else { return nil }

        let looksLikeOAuth = token.hasPrefix("sk-ant-sso") || token.count > 60
        return ClaudeCredential(
            accessToken: token,
            refreshToken: nil,
            expiresAtMilliseconds: nil,
            plan: looksLikeOAuth ? "Claude OAuth (Custom)" : "Claude API Key",
            sourceLabel: "Settings",
            scopes: nil,
            clientId: nil,
            origin: .userSuppliedToken,
            rawJSON: nil
        )
    }

    private func discoverClaudeCredentials() -> [ClaudeCredential] {
        var found: [ClaudeCredential] = []

        // 1. MonoAiBar's own private file cache (NEVER prompts Keychain)
        if let fromLocalFile = claudeCredentialFromLocalFile() {
            found.append(fromLocalFile)
        }

        // 2. MonoAiBar's own Keychain item (NEVER prompts Keychain dialog)
        if let item = Keychain.read(service: Service.claudeCache),
           let credential = parse(
                secret: item.secret,
                sourceLabel: "MonoAiBar Keychain",
                origin: .monoAiBarKeychain
           ) {
            found.append(credential)
        }

        // 3. Claude CLI credentials on disk (NEVER prompts Keychain dialog)
        let home = FileManager.default.homeDirectoryForCurrentUser
        for url in [
            home.appending(path: ".claude/.credentials.json"),
            home.appending(path: ".claude/credentials.json")
        ] {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(data: data, encoding: .utf8),
                  let credential = parse(
                    secret: text,
                    sourceLabel: url.lastPathComponent,
                    origin: .file(url)
                  ) else { continue }
            found.append(credential)
        }

        // 4. Claude CLI settings files (NEVER prompts Keychain dialog)
        if found.isEmpty, let fromSettingsFiles = claudeCredentialFromSettingsFiles() {
            found.append(fromSettingsFiles)
        }

        // 5. Environment variables (NEVER prompts Keychain dialog)
        if found.isEmpty, let fromEnvironment = claudeCredentialFromEnvironment() {
            found.append(fromEnvironment)
        }

        return found
    }

    private func claudeCredentialFromSettingsFiles() -> ClaudeCredential? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [
            home.appending(path: ".claude/settings.json"),
            home.appending(path: ".claude.json")
        ]

        for url in files {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let environment = root["env"] as? [String: Any] else { continue }

            for key in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_TOKEN"] {
                guard let raw = environment[key] as? String else { continue }
                let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { continue }
                return ClaudeCredential(
                    accessToken: token,
                    refreshToken: nil,
                    expiresAtMilliseconds: nil,
                    plan: key == "CLAUDE_CODE_OAUTH_TOKEN" ? "Claude OAuth (Long-Lived)" : "Claude Token",
                    sourceLabel: "\(url.lastPathComponent) (env)",
                    scopes: nil,
                    clientId: nil,
                    origin: .file(url),
                    rawJSON: nil
                )
            }
        }
        return nil
    }

    /// Only reachable when MonoAiBar is launched from a shell; a bundle launched by Finder or as a
    /// login item inherits none of these.
    private func claudeCredentialFromEnvironment() -> ClaudeCredential? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            ("CLAUDE_CODE_OAUTH_TOKEN", "Claude OAuth (Long-Lived)"),
            ("CLAUDE_CODE_TOKEN", "Claude Token"),
            ("ANTHROPIC_API_KEY", "Claude API Key")
        ]

        for (key, plan) in candidates {
            guard let raw = environment[key] else { continue }
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            return ClaudeCredential(
                accessToken: token,
                refreshToken: nil,
                expiresAtMilliseconds: nil,
                plan: plan,
                sourceLabel: "$\(key)",
                scopes: nil,
                clientId: nil,
                origin: .environment(key),
                rawJSON: nil
            )
        }
        return nil
    }

    // MARK: - Payload handling

    private func parse(secret: String, sourceLabel: String, origin: ClaudeCredential.Origin) -> ClaudeCredential? {
        guard let data = secret.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard secret.hasPrefix("sk-ant-") else { return nil }
            return ClaudeCredential(
                accessToken: secret,
                refreshToken: nil,
                expiresAtMilliseconds: nil,
                plan: "Claude OAuth",
                sourceLabel: sourceLabel,
                scopes: nil,
                clientId: nil,
                origin: origin,
                rawJSON: nil
            )
        }

        let oauth = root["claudeAiOauth"] as? [String: Any]
        guard let accessToken = (oauth?["accessToken"] as? String ?? root["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty else { return nil }

        let plan: String
        if let subscription = oauth?["subscriptionType"] as? String, !subscription.isEmpty {
            plan = "Claude \(subscription.capitalized)"
        } else {
            plan = "Claude Account"
        }

        let tier = (oauth?["rateLimitTier"] as? String)?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        let detail = tier != nil ? "Tier: \(tier!)" : nil

        return ClaudeCredential(
            accessToken: accessToken,
            refreshToken: oauth?["refreshToken"] as? String,
            expiresAtMilliseconds: (oauth?["expiresAt"] as? NSNumber)?.int64Value,
            plan: plan,
            sourceLabel: sourceLabel,
            scopes: oauth?["scopes"] as? [String],
            clientId: oauth?["clientId"] as? String,
            origin: origin,
            rawJSON: data,
            accountDetail: detail
        )
    }

    /// Rewrites only the three rotating fields and leaves every other key Claude Code stored
    /// untouched, so a re-encode never drops data MonoAiBar does not model.
    private func mergedPayload(
        base: Data?,
        accessToken: String,
        refreshToken: String?,
        expiresAtMilliseconds: Int64,
        scopes: [String]?,
        clientId: String?
    ) -> (text: String, data: Data) {
        var root: [String: Any] = [:]
        if let base, let parsed = try? JSONSerialization.jsonObject(with: base) as? [String: Any] {
            root = parsed
        }

        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        oauth["expiresAt"] = expiresAtMilliseconds
        if let refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if oauth["scopes"] == nil, let scopes {
            oauth["scopes"] = scopes
        }
        if oauth["clientId"] == nil, let clientId {
            oauth["clientId"] = clientId
        }
        root["claudeAiOauth"] = oauth
        root.removeValue(forKey: "accessToken")

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return (text: "{}", data: Data("{}".utf8))
        }
        return (text: text, data: data)
    }

    // MARK: - Legacy cleanup

    /// Migrates any legacy plaintext file tokens and API keys in UserDefaults into the keychain
    /// once, then erases the plaintext originals.
    private func migrateLegacyStorageIfNeeded() {
        guard !didMigrateLegacyStorage else { return }
        didMigrateLegacyStorage = true

        let defaults = UserDefaults.standard
        let legacyDefaults = [
            ("monobar_custom_claude_token", Service.customClaudeToken),
            ("monobar_codex_api_key", Service.codexAPIKey)
        ]
        for (defaultsKey, service) in legacyDefaults {
            guard let value = defaults.string(forKey: defaultsKey) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

            // Drop the plaintext copy only once the keychain holds the secret, so a failed write
            // cannot lose the user's key.
            guard trimmed.isEmpty || Keychain.write(service: service, account: Self.account, secret: trimmed) else {
                Log.credentials.error("keeping \(defaultsKey, privacy: .public): keychain write failed")
                continue
            }
            defaults.removeObject(forKey: defaultsKey)
            Log.credentials.notice("migrated \(defaultsKey, privacy: .public) out of UserDefaults")
        }

        for obsoleteKey in [
            "monobar_grok_api_key",
            "monobar_deepseek_api_key",
            "monobar_mint_api_key",
            "monobar_kimi_api_key"
        ] where defaults.object(forKey: obsoleteKey) != nil {
            defaults.removeObject(forKey: obsoleteKey)
            Log.credentials.notice("removed obsolete \(obsoleteKey, privacy: .public) from UserDefaults")
        }

        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "MonoAiBar", directoryHint: .isDirectory)

        guard let legacyFile = supportDirectory?.appending(path: "claude_credentials.json"),
              let data = try? Data(contentsOf: legacyFile),
              let text = String(data: data, encoding: .utf8) else { return }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyFile.path(percentEncoded: false))

        _ = Keychain.write(service: Service.claudeCache, account: Self.account, secret: text)
        Log.credentials.notice("synced private credential file with keychain cache")
    }
}
