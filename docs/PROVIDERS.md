# MonoAiBar — Supported AI Providers

How MonoAiBar discovers and monitors quota for each provider.

---

## Overview

| Provider | Code | Authentication source | Tracked quotas | Endpoint |
| :--- | :---: | :--- | :--- | :--- |
| **Claude Code** | `CLD` | macOS Keychain, `~/.claude/.credentials.json`, or Settings | 5-hour session · weekly general · weekly Sonnet | `api.anthropic.com/api/oauth/usage` |
| **Google Antigravity** | `AGY` | Local language server (no credential needed) | Gemini session &amp; weekly · Claude/GPT session &amp; weekly | `http://127.0.0.1:<port>` RPC |
| **OpenAI Codex** | `COD` | `~/.codex/auth.json` or Settings | Primary request window | `chatgpt.com/backend-api/wham/usage` |

---

## 1. Anthropic Claude (`CLD`)

Claude Code stores OAuth credentials in `~/.claude/.credentials.json` and macOS Keychain. MonoAiBar prioritizes the local credential file and its own private cache, completely eliminating repetitive Keychain authorization popups.

Lookup order, with the freshest payload winning:

1. A custom token entered in Settings (overrides everything below)
2. MonoAiBar's own private cache (`~/Library/Application Support/MonoAiBar/claude_credentials.json` and Keychain `com.joaooliveira889.monoaibar.claude`)
3. `~/.claude/.credentials.json` and `~/.claude/credentials.json`
4. The `env` block of `~/.claude/settings.json` or `~/.claude.json`
5. `$CLAUDE_CODE_OAUTH_TOKEN`, `$CLAUDE_CODE_TOKEN`, `$ANTHROPIC_API_KEY`

**5-hour rolling session:** Anthropic applies limits across a 5-hour window that starts at your
first prompt. MonoAiBar shows live utilization and a countdown to the reset.

**Token refresh:** Access tokens last about an hour. When the token has expired, MonoAiBar calls
Anthropic's OAuth refresh endpoint using the refresh token, and updates both its private cache and
`~/.claude/.credentials.json`, keeping MonoAiBar and Claude Code CLI in sync without Keychain prompts.

**Connect:**
```bash
claude
```

**First launch:** macOS asks once whether MonoAiBar may read Claude Code's keychain item. Choose
**Always Allow**. Because the app is signed with a stable certificate, that grant survives every
subsequent rebuild.

---

## 2. Google Antigravity (`AGY`)

While the Antigravity IDE or the `agy` CLI is open, a language server listens on loopback. It needs
no credential from MonoAiBar — the running server is already authenticated.

Finding it is the hard part: on a working machine that process holds several hundred listening
sockets. MonoAiBar therefore reads the server's own command line:

- `--csrf_token` supplies the `x-codeium-csrf-token` header
- `--host_bridge_url` pins the port block; the RPC port sits a step or two above it

Candidates are probed in proximity order, with the process's listening sockets as a fallback, and
the winning port is remembered for next time. Every URL is constructed as
`http://127.0.0.1:<validated port>`, so a request can never leave the machine.

**Tracked windows:** Gemini models (5-hour and weekly) and the bundled Claude and GPT models
(5-hour and weekly).

**Connect:**
```bash
agy
```

---

## 3. OpenAI Codex (`COD`)

The Codex CLI writes session metadata to `~/.codex/auth.json`. MonoAiBar reads it and queries the
ChatGPT usage endpoint.

Lookup order: a key entered in Settings, then `~/.codex/auth.json`,
`~/.config/codex/auth.json`, `~/.config/openai/auth.json`, then `$CODEX_ACCESS_TOKEN` and
`$OPENAI_API_KEY`.

If the credential is an API key rather than a ChatGPT session token, MonoAiBar reports the provider
as healthy with no progress bar: key billing is metered per request and has no rate-limit window to
display.

**Connect:**
```bash
codex login
```

---

## Entering credentials in Settings

1. Click the gear icon in the popover.
2. Expand **AI Credentials & API Keys**.
3. Enter a custom Claude token or a Codex key. Inputs are masked (`SecureField`).
4. Click **Save & Refresh Providers**.

Values are written to the macOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
and `kSecAttrSynchronizable = false` — device-local, unreadable before first unlock, and never
written to a file or to `UserDefaults`.

---

## Unsupported Providers

Cursor, xAI Grok, DeepSeek, Mint AI, and Moonshot Kimi are deliberately not supported. None of them expose genuine quota telemetry that can be queried locally or through public quota endpoints. MonoAiBar strictly adheres to zero-telemetry and authentic measurements, rejecting mock or placeholder percentages.
