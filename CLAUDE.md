# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A macOS menu bar app that monitors AI provider quota and usage (Claude Code, Google Antigravity, OpenAI Codex) by reading the keychain, local config files, and a loopback RPC — no network telemetry, no token cost.

**The directory, product, target, and binary are all `MonoAiBar`.** `make clean` and `make install` remove both legacy `MonoBar.app` and `MonoAiBar.app` paths.

## Commands

```bash
make bundle    # scripts/build.sh + scripts/bundle.sh -> MonoAiBar.app, signed with a real identity
make build     # swift build -c release --arch arm64 only
make run       # scripts/run.sh
make install   # clean + bundle, copies to /Applications and ~/Applications,
               # symlinks ~/.local/bin/monoaibar and ~/.local/bin/monobar,
               # then refreshes lsregister/QuickLook/Finder caches
make clean     # pkills running instances, removes .build and both .app names
```

Apple Silicon only (`--arch arm64`), macOS 26.0+, swift-tools-version 6.0 in Swift 6 language mode with strict concurrency. `DEVELOPER_DIR` is pinned to `/Applications/Xcode.app/Contents/Developer` when present — building without it fails with a `SwiftUIMacros` plugin error, so always build through `scripts/build.sh` rather than a bare `swift build`. There is **no test target** in `Package.swift`, so `swift test` will fail.

## Architecture

No external Swift dependencies. `Sources/MonoAiBar/` is layered:

- `App/` — `MonoAiBarApp.swift` (entry point) and `AppDelegate.swift`, which calls
  `QuotaManager.shared.start()`. Runs as `LSUIElement` (menu bar only, no Dock icon).
- `Models/QuotaModels.swift` — the shared `Sendable` quota types every service maps into.
- `Services/`
  - `QuotaManager.swift` — `@MainActor @Observable`, owns the refresh loop and the status map
  - `CredentialStore.swift` — actor; the only place credentials are read or written
  - `Keychain.swift` — thin `SecItem*` wrapper
  - `ClaudeUsageService.swift`, `AntigravityUsageService.swift`, `CodexUsageService.swift` — actors
  - `ProcessInspector.swift` — `libproc` / `sysctl` process and socket inspection
  - `HTTPClient.swift` — the one shared ephemeral `URLSession` shape
  - `SettingsStore.swift`, `NotificationService.swift`, `Log.swift`
- `UI/` — `StatusItemController` owns the status item and the popover's open/close state machine,
  `MenuBarRenderer` rasterises the status item image, `PopoverContentView` + `ProviderQuotaCard` +
  `MiniProgressBar` render the dropdown, plus `SettingsView`, `OfficialBrandIcons`, and `BrandIcon`
  (the one SwiftUI wrapper for a provider glyph).

Adding a provider means a new actor in `Services/` returning `ProviderStatus`, a case in
`ProviderType`, a branch in `QuotaManager.fetch(_:)`, and an icon in `OfficialBrandIcons.swift`.

Brand glyphs are hand-drawn Core Graphics templates that trace the vendors' official marks (the
Claude burst, the Antigravity arch, the OpenAI blossom). They are templates so the menu bar can
invert them and SwiftUI can tint them — never swap one for a bitmap or a coloured asset.

**Only add a provider whose real usage figures can actually be read.** A provider with
no readable telemetry belongs in neither the enum nor the README. Never present mock or placeholder
percentages as live quota.

## Conventions

- **Zero telemetry** is a documented product guarantee (see `docs/SECURITY.md` and the README
  badge). Never add analytics, crash reporting, or any outbound reporting of usage data.
- **Secrets and non-interactive caches.** Stored in private Application Support cache with mode `0600`
  and MonoAiBar's own Keychain item. Never query foreign Keychain items to prevent macOS permission dialogs.
  Rotated tokens keep `~/.claude/.credentials.json` in sync so CLI and app share credentials seamlessly.
- **`bundle.sh` must sign with a real certificate.** A keychain grant is bound to the signing
  identity; an ad-hoc signature's hash changes every build, so macOS re-prompts each time. The
  script prefers `Developer ID Application`, falls back to `Apple Development`, and warns loudly if
  it has to go ad-hoc. Do not "simplify" it back to `codesign --sign -`.
- No `Foundation.Process` anywhere. Process and port discovery go through `ProcessInspector`.
- No `print`. Use the `OSLog` categories in `Log.swift`, and never interpolate a token into a log
  line.
- **Semantic Versioning & Rules:** Governed by `RULES.md`. When introducing a new version, follow the
  increment checklist across `scripts/bundle.sh`, `PopoverContentView.swift`, services userAgent, and README badges.

## Known gaps

- `UNUserNotificationCenter.requestAuthorization` throws "Notifications are not allowed for this
  application" whenever macOS has alerts switched off for MonoAiBar. This is not a bug and is not
  fixed by reinstalling: `usernoted` still stores every notification (`hasAuthorizations: true`,
  `notificationsAllowed: false`), so alerts reach Notification Center but produce no banner and no
  sound. `SettingsView` detects it through `NotificationService.alertsAllowed()` and offers a link
  to the system Notification pane. Do not "fix" it by retrying the request.
- `make install` deliberately places the bundle in both `/Applications` and `~/Applications`, so
  LaunchServices registers two copies of the same bundle identifier (three while an uncleaned
  `MonoAiBar.app` sits in the repo root). Harmless, but expect duplicates in `lsregister -dump`.
