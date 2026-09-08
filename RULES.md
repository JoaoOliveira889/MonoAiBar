# MonoAiBar Rules

Mandatory rules for the development and maintenance of MonoAiBar.

## Semantic Versioning (SemVer)

The project strictly follows Semantic Versioning (`MAJOR.MINOR.PATCH`):
- **Base Initial Version**: `0.0.1` (Tag: `v0.0.1`).
- **PATCH (`0.0.x`)**: Bug fixes, minor UI/UX adjustments, background refresh optimizations, internal refactoring, and performance improvements that preserve existing behavior.
- **MINOR (`0.x.0`)**: Adding new genuine AI providers (with verifiable telemetry), new configurable settings or display modes, and backward-compatible feature additions.
- **MAJOR (`x.0.0`)**: Architectural overhauls, breaking changes to credential/storage formats, or macOS platform requirement shifts.

### Mandatory Procedure for Every New Version
Whenever introducing any change that warrants a version increment:
1. **Increment `APP_VERSION`** in `scripts/bundle.sh` (e.g. `APP_VERSION="0.0.2"`).
2. **Update Fallback Version** in `Sources/MonoAiBar/UI/PopoverContentView.swift` (`v\(version ?? "X.Y.Z")`).
3. **Update HTTP User-Agent** in:
   - `Sources/MonoAiBar/Services/ClaudeUsageService.swift` (`userAgent = "MonoAiBar/X.Y.Z"`)
   - `Sources/MonoAiBar/Services/CodexUsageService.swift` (`userAgent = "MonoAiBar/X.Y.Z"`)
4. **Update Version References in Docs & Badges**:
   - Version badge in `README.md` (`https://img.shields.io/badge/version-vX.Y.Z-blueviolet?style=for-the-badge` and `alt="Version X.Y.Z"`).
   - Architecture reference in `docs/SECURITY.md`.
5. **Commit and Tag**:
   - Create a Conventional Commit (e.g. `feat(v0.1.0): ...` or `fix: ...`).
   - Create an annotated Git tag matching the release (`git tag -a vX.Y.Z -m "Release vX.Y.Z"`).
6. **Compile and Verify**:
   - Run `make bundle` to verify compilation, signing, and bundle assembly.
   - Run `make install` to install locally and verify the menu bar popover displays the exact new version.
7. **Publish**:
   - Push commit and tag to GitHub (`git push origin main && git push origin vX.Y.Z`).
   - Create GitHub release: `gh release create vX.Y.Z --title "MonoAiBar vX.Y.Z" --notes "..."`.

## Security & Privacy Rules
- **Zero Telemetry**: Never add analytics, tracking, telemetry SDKs, or outbound usage reporting.
- **No Mock or Placeholder Telemetry**: Only integrate providers whose real, authentic quota metrics can be read. Never simulate usage percentages.
- **Keychain and 0600 Storage**: Store secrets and OAuth credentials exclusively in the macOS Keychain or isolated caches with `0600` permissions. Never write tokens to `UserDefaults` or plaintext git-tracked files.
- **No Subprocesses**: Never invoke shell binaries (`/usr/bin/security`, `/usr/sbin/lsof`, etc.). Use in-process C APIs (`libproc`, `sysctl`, `Security.framework`).
- **Loopback RPC Only**: Query local servers (Antigravity) strictly on `127.0.0.1`.

## UX & Menu Bar
- **Non-blocking Concurrency**: All network and RPC queries must run asynchronously via actors in Swift Concurrency. Never block the main actor or UI thread.
- **Responsive Dismissal**: Popovers and settings must open smoothly and dismiss cleanly on outside interaction.
