# MonoAiBar — System Architecture

This document describes the technical architecture, data pipeline, and design principles of **MonoAiBar**, a native, ultra-lightweight AI quota monitor for macOS.

---

## 🏛️ Architecture Overview

MonoAiBar is engineered around three core principles:
1. **Low Resource Overhead:** 0% idle CPU and roughly 85 MB resident — largely the shared SwiftUI and AppKit runtime — with no Electron, WebView, or third-party runtime.
2. **Zero Token Cost:** All quota and utilization metrics are queried through official account telemetry endpoints or local language server RPCs. **It never dispatches prompts or consumes tokens from your allowance.**
3. **Strict Privacy:** Zero telemetry, analytics, or remote logging. No user prompts, code, or personal metadata ever leaves your local machine.

```
┌─────────────────────────────────────────────────────────┐
│                      macOS Menu Bar                     │
│               [MenuBarLabelView / NSImage]              │
└────────────────────────────┬────────────────────────────┘
                             │ Observes
┌────────────────────────────▼────────────────────────────┐
│                       QuotaManager                      │
│                  (@MainActor Observable)                │
└──────┬─────────────────────┬─────────────────────┬──────┘
       │                     │                     │
┌──────▼──────┐       ┌──────▼──────┐       ┌──────▼──────┐
│ ClaudeUsage │       │ Antigravity │       │ CodexUsage  │
│   Service   │       │UsageService │       │   Service   │
└──────┬──────┘       └──────┬──────┘       └──────┬──────┘
       │                     │                     │
       ▼                     ▼                     ▼
 Anthropic OAuth       Local RPC Server       OpenAI Wham
(api.anthropic.com)   (127.0.0.1:LISTEN)   (chatgpt.com)
```

---

## 🧩 Core Subsystems

### 1. Application Lifecycle (`App/`)
- **`AppDelegate.swift`:** Configures the application activation policy as `.accessory` (`LSUIElement = true`). This keeps MonoAiBar exclusively in the macOS menu bar without polluting the Dock or spawning unwanted main windows.
- **`MonoAiBarApp.swift`:** Application entry point using SwiftUI's modern `MenuBarExtra` with `.window` presentation style for smooth, native popover interaction.

### 2. Data Models (`Models/QuotaModels.swift`)
- **`ProviderType`:** Enumerates the supported AI providers (`claude`, `antigravity`, `codex`), providing short codes (`CLD`, `AGY`, `COD`), accent colors, brand icons, and the shell command that re-authenticates each one.
- **`ProviderStatus`:** Reactive provider state, tracking connectivity health (`healthy`, `warning`, `expired`, `notFound`), detected subscription tier, credential source, and quota windows.
- **`QuotaWindow`:** Encapsulates rate limit windows such as the **5-hour active session** (`5 * 3600s`) and weekly allowances (`7 * 86400s`), formatting precise countdowns (`Resets in 4h 24m`).

### 3. Menu Bar Rendering Pipeline (`UI/MenuBarRenderer.swift`)
Rather than relying on static SwiftUI text labels that can drift or lack system template adaptability, `MenuBarRenderer` renders custom **CoreGraphics / NSImage** canvases through `NSImage(size:flipped:drawingHandler:)`, so each image re-rasterises at the backing scale of whichever display it appears on:
- **macOS System Template (`isTemplate = true`):** Adapts instantly across Light and Dark macOS appearances, active desktop wallpapers, and accent colors.
- **3 Configurable Display Modes:**
  1. **Stacked Text (Default):** Uppercase provider identifier above percentage value (`CLD 14%`, `AGY 7%`), matching native macOS hardware activity monitors.
  2. **Single Line:** Compact horizontal layout (`cld 14%  agy 7%`).
  3. **Icons:** Hand-crafted vector brand icons rendered pixel-perfect directly above the percentage values.

### 4. Telemetry Services (`Services/`)

#### A. Claude Code (`ClaudeUsageService.swift`, `CredentialStore.swift`, `Keychain.swift`)
- `CredentialStore` is an actor that owns every credential lookup. It prioritizes local files
  (`~/.claude/.credentials.json`, `~/.claude/credentials.json`) and MonoAiBar's own private cache
  (`~/Library/Application Support/MonoAiBar/claude_credentials.json` and Keychain `com.joaooliveira889.monoaibar.claude`),
  completely eliminating repetitive macOS Keychain authorization dialogs.
- Refreshed OAuth tokens are written back to MonoAiBar's private store and synchronized with
  `~/.claude/.credentials.json` so Claude Code CLI and MonoAiBar share the fresh token.
- Executes an authenticated `GET` against `https://api.anthropic.com/api/oauth/usage` with the beta
  header `oauth-2025-04-20`, and decodes the 5-hour, 7-day, and 7-day-Sonnet windows.
- On HTTP 401/403 it refreshes once and retries, then updates the cache.

#### B. Google Antigravity (`AntigravityUsageService.swift`, `ProcessInspector.swift`)
- `ProcessInspector` locates the language server by executable path or command line, reading arguments via
  `sysctl(KERN_PROCARGS2)`. When Antigravity is open, metrics flow seamlessly via loopback RPC.
- Quota windows are retained in cache when temporarily disconnected, preventing blank or zeroed displays.
  `--host_bridge_url`.
- Candidates are the bridge port plus a small offset, then the process's own listening sockets —
  enumerated in-process with `libproc` (`proc_pidinfo` / `proc_pidfdinfo`) — ordered by proximity
  to the bridge port and capped at twelve probes. This replaces the old `/usr/sbin/lsof` subprocess,
  which returned several hundred sockets in arbitrary order.
- The last working port is remembered in `UserDefaults` and tried first on the next cycle.
- Calls `exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` and
  `GetUserStatus` on `127.0.0.1`, extracting remaining quota fractions for the Gemini and
  Claude/GPT model groups. No outbound internet traffic.

#### C. OpenAI Codex (`CodexUsageService.swift`)
- Checks the keychain-stored Settings key first, then `~/.codex/auth.json`,
  `~/.config/codex/auth.json`, `~/.config/openai/auth.json`, and finally the environment.
- Queries `https://chatgpt.com/backend-api/wham/usage` for the primary rate limit window.
- API-key authentication is reported as healthy with no window, since key billing is metered rather
  than windowed and has no quota to display.

#### D. Shared plumbing
- `HTTPClient` holds the one ephemeral `URLSession` shape every provider uses: cookies refused, no
  URL cache, short timeouts, and a 512 KB response ceiling enforced before decoding.
- `Log` exposes four `OSLog` categories. Every interpolation that reaches a log line is marked
  `.public` deliberately; no log statement takes a token.

---

## ⚡ Concurrency & Hardware Optimization

- **Apple Silicon (ARM64) Exclusive:** Compiled with `--arch arm64` for maximum execution efficiency on M-series processors.
- **macOS 26.0+ Target, Swift 6 Language Mode:** Built with strict concurrency checking. Provider services are actors, UI state is `@MainActor @Observable`, and every value crossing an isolation boundary is `Sendable`. There is no lock, no `DispatchQueue`, and no unchecked shared state beyond two documented `nonisolated(unsafe)` font constants in the renderer.
- **Asynchronous Refresh:** `QuotaManager` queries all active providers concurrently with `withTaskGroup`, never blocking the main thread.
- **Structured Timer:** The refresh cycle is a cancellable `Task` sleeping on `Duration` with a 10% tolerance, replacing the Combine `Timer.publish` pipeline. Sleep cancels it; wake restarts it after a 1.5s debounce so the network stack is ready.
- **Cached Menu Bar Image:** `MenuBarRenderer` keys its cache on exactly the strings it draws, and the usage values are passed in rather than pulled from the manager, so an unrelated state change cannot force a redraw.
- **Ephemeral HTTP Sessions:** Every outbound request uses `URLSessionConfiguration.ephemeral`, so cookies, headers, and caches are never written to disk.
- **No Subprocesses:** Process and port discovery use `libproc` and `sysctl` directly. `Foundation.Process` is not used anywhere in the codebase.
