# Notifdex agent handoff

Notifdex is a local-first macOS notification inbox and relationship notebook. It indexes notifications macOS exposes through Accessibility, including iPhone alerts forwarded to the Mac. It runs from the menu bar and keeps collecting when App Center closes. The native Swift implementation on `main` is the product. The [archived Python/web branch](https://github.com/notifdex/notifdex/tree/archive/notif-mgmt-2026-11-17) is historical context.

## Pick up work

1. Read this guide, check `git status --short --branch`, fetch `origin/main`, and inspect the current code and any linked issues or PRs. Use a branch from current `main`. If the existing checkout has unrelated changes, isolate your work and preserve them.
2. State the acceptance condition before editing. For deterministic behavior changes, write a failing regression test and record the failing and passing results. Use synthetic fixtures and cover the relevant failure paths.
3. Keep PRs focused. For a bug, describe the observed symptom, proven root cause or remaining hypothesis, fix, and verification. For an interface change, name the specific pane or control and list the features affected. Keep design work separate from capture, schema, and workflow changes unless the task requires them.
4. Open a PR and wait for the relevant CI checks when preparing a merge. When the user asks for a merge, verify the merged commit is on `main`. Report what CI checked and which hands-on checks remain. For installed Mac testing, give the Homebrew upgrade command (`brew update && brew upgrade --cask notifdex`) or normal local pull/build/open command cleanly.

## Where to work

| Area | Start here |
| --- | --- |
| App Center, menu bar, window chrome & cross-monitor drag sync | [NotifdexApp.swift](Sources/NotifdexApp/NotifdexApp.swift), [AppCenterPresence.swift](Sources/NotifdexApp/AppCenterPresence.swift), [WindowChromeLayout.swift](Sources/NotifdexCore/WindowChromeLayout.swift), [WindowChrome.tla](spec/WindowChrome.tla) |
| Inbox, detail pane, People, Today, Flagged, Saved, Hidden, Notes, Apps and Recovery | [WorkflowView.swift](Sources/NotifdexApp/WorkflowView.swift), [Inbox.swift](Sources/NotifdexCore/Inbox.swift), [InboxPresentation.swift](Sources/NotifdexCore/InboxPresentation.swift) |
| Appearance Studio, surfaces/pigments, and built-in guide | [AppAppearance.swift](Sources/NotifdexApp/AppAppearance.swift), [AppearancePreferences.swift](Sources/NotifdexCore/AppearancePreferences.swift), [AppearanceStudioView.swift](Sources/NotifdexApp/AppearanceStudioView.swift), [UserGuideView.swift](Sources/NotifdexApp/UserGuideView.swift) |
| Accessibility adapter, parser and recovery | [NotificationReader.swift](Sources/NotifdexMac/NotificationReader.swift), [NotificationTree.swift](Sources/NotifdexMac/NotificationTree.swift), [Observation.swift](Sources/NotifdexCore/Observation.swift), [CaptureWorker.swift](Sources/NotifdexMac/CaptureWorker.swift), [RecoveryAutomation.swift](Sources/NotifdexMac/RecoveryAutomation.swift) |
| Storage, settings and relationship templates | [CaptureStore.swift](Sources/NotifdexCore/CaptureStore.swift), [AppSettings.swift](Sources/NotifdexCore/AppSettings.swift), [data model](docs/data-model.md), [templates](templates/README.md) |
| Command-line collector | [NotifdexCapture/main.swift](Sources/NotifdexCapture/main.swift), [README](README.md#try-capture-on-the-mac) |
| iOS companion & hybrid CloudKit sync (iOS 27 Shortcuts → shared `NotifdexCore` → CloudKit Private DB) | [ios/README.md](ios/README.md), [ios/NotifdexiOS.xcodeproj](ios/NotifdexiOS.xcodeproj), [CaptureNotificationIntent.swift](ios/NotifdexiOS/Intents/CaptureNotificationIntent.swift), [HybridSync.swift](Sources/NotifdexCore/HybridSync.swift), [CloudKitSyncTransport.swift](Sources/NotifdexCore/CloudKitSyncTransport.swift), [IOSCapture.tla](spec/IOSCapture.tla), [HybridSync.tla](spec/HybridSync.tla) |
| Public website (`notifdex.com`) | [website/src/](website/src/), [website/README.md](website/README.md), [website/scripts/check.mjs](website/scripts/check.mjs), [website-ci.yml](.github/workflows/website-ci.yml) |
| Cloudflare infrastructure (OpenTofu + R2 state) | [infra/cloudflare/](infra/cloudflare/), [infra/cloudflare/README.md](infra/cloudflare/README.md), [cloudflare-infra.yml](.github/workflows/cloudflare-infra.yml) |
| Signed macOS releases, notarization & Homebrew tap | [docs/operations.md](docs/operations.md), [docs/release-signing.md](docs/release-signing.md), [tools/build-app.sh](tools/build-app.sh), [tools/render-homebrew-cask.sh](tools/render-homebrew-cask.sh), [release-macos.yml](.github/workflows/release-macos.yml) |
| Behavior and verification | [App Center acceptance](docs/app-center.md), [reliability matrix](docs/reliability.md), [formal model and implementation mapping](docs/formal-methods.md), [CI](.github/workflows/checks.yml) |

## Current product decisions

- **App Center & window chrome.** Apps and Recovery are folded into the unified sidebar (`Primary`: Inbox, Today, People, Notes, Docs; `Library`: Flagged, Saved, Hidden; `System`: Apps, Recovery), with a compact View picker below `860pt`. The window uses a single native SwiftUI `.unifiedCompact` (`~38pt`) titlebar with the icon + `"Notifdex"` wordmark in `ToolbarItem(placement: .navigation)` and `.sharedBackgroundVisibility(.hidden)` on macOS 26+ (no glass pill bubble). `AppCenterPresence` uses `WindowChromeSyncState` so idle SwiftUI ticks are no-ops, `NSWindow` chrome mutations are deferred while dragging across monitors, and drag releases never trigger titlebar double-click zoom/minimize. Global Status and Appearance controls live in the sidebar footer (with compact-header fallback). Preserve per-view search, filtering, grouping/sorting, read/unread, flag/save, hide rules and undo, open-in-app, linking, workspaces, follow-ups, and explicit back navigation.
- **Alert detail & open-in-app.** The right-hand pane inside Inbox starts at the widest available split up to 640 points, with at least 250 points reserved for the feed and an adjustable divider (single-pane with `Back to alerts` at narrow sizes). `InboxDestination` supports `Open in Messages` (`com.apple.MobileSMS` via `NSWorkspace.openApplication`), native `WhatsApp` (`whatsapp://` with web fallback), and static web URLs for `X`, `Gmail`, `Discord`, `Slack`, and `LinkedIn` without placing captured text in URLs.
- **Appearance.** Appearance Studio supports four surfaces (**Clear Glass**, **Ambient Glass**, **Custom Image**, and **Solid**) across six color pigments (`Mineral`, `Vermilion`, `Prussian`, `Sienna`, `Celadon`, `Nocturne`), plus menu bar icon style and **Show data folder**. Selecting a pigment in Solid mode must stay in Solid mode ([#71](https://github.com/notifdex/notifdex/pull/71)). Check light/dark appearances, Reduce Transparency, Increase Contrast, and selection contrast when changing styling.
- **People, Notes, and Docs.** People can belong to multiple workspaces; a person's timeline in a workspace includes linked alerts routed to that workspace and unassigned linked alerts. Person memberships and alert workspaces are independently editable. Personal Notes have a one-level folder layout and Unfiled; People Notes and the People profile edit the same stored notes. Relationship templates are versioned and person-scoped. **Docs** opens the built-in offline Notifdex guide (`UserGuideView.swift`); the separate Saved Documents feature was removed in [#60](https://github.com/notifdex/notifdex/pull/60) while keeping legacy v11 database compatibility.
- **Website (`notifdex.com`).** Static site in `website/src/` (`index.html`, `updates.html`, `faq.html`, `privacy.html`, `404.html`) hosted on Cloudflare Pages (`website/*` watch path) with SHA-256 CSS/JS cache-busting, strict CSP (no inline styles/scripts/handlers), dark/light toggle, and synthetic-only preview data. Never use the term `Rolodex` in public website assets ([#38](https://github.com/notifdex/notifdex/issues/38), enforced by `website/scripts/check.mjs`).
- **Future AI.** [#48](https://github.com/notifdex/notifdex/issues/48) explores chat grounded in local Docs, Notes, and notification history; [#5](https://github.com/notifdex/notifdex/issues/5) tracks opt-in AI summaries. Keep capture and storage usable offline, treat retrieved content as data, and require explicit opt-in before external processing.

## Build, release, and verify

### Installed app (signed Homebrew release — recommended for Mac testing)

```bash
brew update && brew upgrade --cask notifdex
open /Applications/Notifdex.app
```

- Signed, Apple-notarized universal releases (`arm64` + `x86_64`, Team ID `HNH4DY9A2T`, bundle ID `com.notifdex.mac`) are published on [GitHub Releases](https://github.com/notifdex/notifdex/releases) and distributed via [`notifdex/homebrew-tap`](https://github.com/notifdex/homebrew-tap). Accessibility grants persist across signed upgrades ([#20](https://github.com/notifdex/notifdex/issues/20), closed).
- Pushing a version tag (`git tag vX.Y.Z && git push origin vX.Y.Z`) runs [`.github/workflows/release-macos.yml`](.github/workflows/release-macos.yml) to test, build, sign, notarize, staple, publish the GitHub Release, and auto-update `Casks/notifdex.rb` via the never-expiring SSH Deploy Key `HOMEBREW_TAP_DEPLOY_KEY`. Update [`website/src/updates.html`](website/src/updates.html) when shipping user-facing releases. See [docs/operations.md](docs/operations.md) for the full runbook and rollback steps.

### Local source build (development)

Quit Notifdex from the menu bar (and stop any Terminal collector sharing `capture.db`) before rebuilding:

```bash
cd ~/projects/notifdex && git pull --ff-only && bash tools/build-app.sh && open dist/Notifdex.app
```

- Without `NOTIFDEX_SIGNING_IDENTITY`, `tools/build-app.sh` ad-hoc signs `dist/Notifdex.app` and runs `--self-check`. Rebuilding an ad-hoc copy may require removing and re-adding Notifdex in Accessibility settings.
- A standalone Command Line Tools install on macOS may lack `XCTest` (CI runs `swift test` on `macos-26-intel`). Keep production builds independently runnable and avoid `@State` in `Sources/NotifdexApp/` (enforced by `test_macos_build_contract.py`). In sandboxed shells where SwiftPM cannot nest `sandbox-exec` or write `/var/folders/.../ModuleCache`, run with `CLANG_MODULE_CACHE_PATH=/tmp/notifdex-clang-cache SWIFT_MODULE_CACHE_PATH=/tmp/notifdex-swift-cache swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors`.

### Automated verification suites

```bash
python3 -m unittest discover -s contract-tests -v
swift test
TLA_JAR=/absolute/path/to/tla2tools.jar bash tools/check-model.sh
npm --prefix website run build && npm --prefix website run check
```

- Run `swift test`, the Python contract suite, and all TLC configurations (`spec/*.cfg`) for foundation, durability, recovery, or window-chrome changes. Model stateful durability, recovery, or window-chrome changes in TLA+ before implementation.
- For iOS companion changes (`ios/`), keep `ios/` isolated from `Package.swift` / macOS CLT builds, verify `spec/IOSCapture.tla`, and run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/NotifdexiOS.xcodeproj -scheme NotifdexiOS -destination "platform=iOS Simulator,name=iPhone 17" test`. See [ios/README.md](ios/README.md) for device install and Shortcuts setup steps.
- For website changes, run `npm --prefix website run build && npm --prefix website run check`, verify `contract-tests/test_website_and_infra_contract.py`, and preview locally with `npm --prefix website run preview` (`http://127.0.0.1:4173`).
- For Cloudflare OpenTofu changes (`infra/cloudflare/`), follow the PR validate → manual `plan` → protected `cloudflare-prod` `apply` workflow in [docs/operations.md](docs/operations.md) and [infra/cloudflare/README.md](infra/cloudflare/README.md).

## Triage missing notifications

1. Check the alert's path in order: **iPhone notification → macOS Notification Center → Notifdex**. Forwarded iPhone alerts require macOS 15+ (Apple Silicon/T2) & iOS 18+, iPhone Mirroring paired, *Allow notifications from iPhone* enabled per app, and *Show Previews* not set to *Never* (Apple currently restricts iPhone Mirroring in the EU). A locked screen, Sleep Focus, and a sleeping Mac are distinct test conditions.
2. If the Mac has the alert but Inbox does not, check the Notifdex app toggle (X and Messages start enabled on new installs), collection status, Accessibility grant, filters, and Hidden. Expand the app stack in Notification Center and try **Recovery → Recover now** while the alert is retained.
3. When needed, run an isolated live capture (`--recover` inspects retained alerts for 30 seconds; `--probe-account` is only for X or Gmail):

```bash
swift build -c release --product notifdex-capture &&
  notifdex_bin="$(swift build -c release --show-bin-path)" &&
  notifdex_probe="$(mktemp -d)" &&
  "$notifdex_bin/notifdex-capture" --db "$notifdex_probe/capture.db" \
    --source whatsapp-test --app WhatsApp --diagnostics
```

- **Known WhatsApp case.** [#51](https://github.com/notifdex/notifdex/pull/51) trims edge direction marks (`U+200E`) from the parsed app label while preserving the raw Accessibility description; use `--app WhatsApp`.
- Keep personal messages, databases, credentials, certificates (`.p12`, `.p8`, `.cer`), and machine-specific capture files out of Git and CI. Consult [docs/reliability.md](docs/reliability.md) before claiming coverage.

## Storage and matching invariants

- Use one SQLite database (`~/Library/Application Support/Notifdex/capture.db` alongside `settings.json`) with atomic transactions and acknowledge only committed evidence. Keep the live collector's source ID stable for that Mac and login; scope event identity to the collector source and retain changed renderings as revisions.
- Track observation time, source event time, UI visibility, delivery coverage, and workflow state independently. Preserve historical gaps across restart, revocation, sleep, or interruption.
- Preserve provenance and parser version. App labels and sender display names are observed text. Never create or merge people solely by display name.
- Check [the issue tracker](https://github.com/notifdex/notifdex/issues) for current priorities. Active lines of work include [account attribution](https://github.com/notifdex/notifdex/issues/3), [the public Mac beta](https://github.com/notifdex/notifdex/issues/22), [Cloudflare rollback drill](https://github.com/notifdex/notifdex/issues/69), and the AI discussions ([#5](https://github.com/notifdex/notifdex/issues/5), [#48](https://github.com/notifdex/notifdex/issues/48)). Signed macOS updates ([#20](https://github.com/notifdex/notifdex/issues/20)) and the website FAQ ([#78](https://github.com/notifdex/notifdex/issues/78)) are completed.
