# MonoAiBar — Security & Privacy

This document describes how MonoAiBar handles credentials, what it puts on the network, and what
it deliberately does not do. It reflects the v0.0.1 architecture.

---

## Summary

| Audit vector | Status | Detail |
| :--- | :---: | :--- |
| Hardcoded keys / credentials | None | No API keys, tokens, or client secrets in the repository. The Claude OAuth client ID is a public identifier, not a secret. |
| Secrets at rest | Secure | Keychain generic password items (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and private Application Support cache with strict 0600 POSIX permissions. No plaintext leaks in `UserDefaults`. |
| External telemetry / analytics | Zero | No tracking libraries. `Package.swift` declares no dependencies. |
| User data collection | Zero | No machine identifiers, IP addresses, prompt history, repository names, or file contents are collected or transmitted. |
| Token consumption | Zero | MonoAiBar never calls an inference endpoint. Checking quota costs nothing against your plan. |
| Network boundaries | Strict | Only `api.anthropic.com`, `platform.claude.com`, and `chatgpt.com`. Antigravity is queried exclusively on `127.0.0.1`. |
| Subprocesses | None | No `Process` invocation anywhere in the codebase. Process inspection uses `libproc` and `sysctl`. |
| HTTP session isolation | Ephemeral | `URLSessionConfiguration.ephemeral`, cookies refused, no URL cache, response size capped. |
| Logging | Privacy-aware | `OSLog` only. No log statement accepts a token. No `print` calls remain. |

---

## Credential storage

Secrets are stored securely in the macOS Keychain and a private, user-isolated cache:

| Item / File | Contents |
| :--- | :--- |
| `com.joaooliveira889.monoaibar.claude` | MonoAiBar's own private Keychain item caching the Claude OAuth payload |
| `~/Library/Application Support/MonoAiBar/claude_credentials.json` | Private non-interactive cache (0600 permissions) eliminating foreign Keychain dialogs |
| `com.joaooliveira889.monoaibar.claude.custom` | Optional custom Claude token typed into Settings |
| `com.joaooliveira889.monoaibar.codex` | Optional Codex API key or token typed into Settings |

### Eliminating foreign Keychain prompts

Reading foreign Keychain items (such as `Claude Code-credentials` created by the CLI) requires interactive macOS authorization prompts whenever code signatures or ad-hoc builds change.

MonoAiBar reads credentials directly from `~/.claude/.credentials.json` and its own private cache (`0600` permissions), completely eliminating repetitive system authorization dialogs. When the access token expires, MonoAiBar refreshes it using Anthropic's OAuth endpoint and updates both its private cache and `~/.claude/.credentials.json` so Claude Code CLI stays in sync.

## Token lifecycle

Access tokens last about an hour, so refreshing is unavoidable for a background monitor. When the
token MonoAiBar holds has expired, it calls Anthropic's OAuth refresh endpoint and writes
the rotated pair back into its private cache and `~/.claude/.credentials.json`, merging only `accessToken`,
`refreshToken`, and `expiresAt` into the original JSON object. Every other key is preserved
byte-for-byte.

## Provider access

### Anthropic Claude
Reads `~/.claude/.credentials.json` and MonoAiBar's private cache, then the `env` block of
`~/.claude/settings.json` and `~/.claude.json`, then the environment. When several are present the one
with the latest expiry wins. Usage comes from `https://api.anthropic.com/api/oauth/usage`.

### Google Antigravity
The language server runs locally while the IDE or the `agy` CLI is open.
MonoAiBar finds its process through `ProcessInspector`, reads arguments via `sysctl(KERN_PROCARGS2)`,
and queries `127.0.0.1:<validated port>`. Last known quota windows are retained during transitions.
Process discovery avoids invoking `/usr/sbin/lsof` and instead uses direct in-process inspection with
`libproc` and `sysctl`.

### OpenAI Codex
Reads `~/.codex/auth.json` (or a key from Settings, or the environment) and queries
`https://chatgpt.com/backend-api/wham/usage`. Read-only; MonoAiBar never writes to `~/.codex`.

## Concurrency

The project builds in Swift 6 language mode with strict concurrency checking. Provider services are
actors, UI state is `@MainActor @Observable`, and every value crossing an isolation boundary is
`Sendable`. There is no lock, no `DispatchQueue`, and no unchecked shared mutable state outside two
narrowly documented `nonisolated(unsafe)` font constants in the menu bar renderer.

## Notifications

Quota warnings are posted through `UNUserNotificationCenter` with no attachments and no user info,
and the body carries only the provider name, the window name, and a percentage. When macOS has
alerts switched off for MonoAiBar the notification is still recorded in Notification Center but no
banner or sound is produced; Settings detects that state and links to the system Notification pane
rather than silently doing nothing.

## Open source

MonoAiBar is MIT licensed. All networking, credential handling, and process inspection code is
readable in `Sources/MonoAiBar/Services/`.
