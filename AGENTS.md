# Notifdex agent handoff

Notifdex is a local-first macOS notification inbox and relationship notebook. It indexes notifications macOS exposes through Accessibility, including iPhone alerts forwarded to the Mac. It runs from the menu bar and keeps collecting when App Center closes. The native Swift implementation on `main` is the product. The [archived Python/web branch](https://github.com/qzyu999/notifdex/tree/archive/notif-mgmt-2026-11-17) is historical context.

## Pick up work

1. Read this guide, check `git status --short --branch`, fetch `origin/main`, and inspect the current code and any linked issues or PRs. Use a branch from current `main`. If the existing checkout has unrelated changes, isolate your work and preserve them.
2. State the acceptance condition before editing. For deterministic behavior changes, write a failing regression test and record the failing and passing results. Use synthetic fixtures and cover the relevant failure paths.
3. Keep PRs focused. For a bug, describe the observed symptom, proven root cause or remaining hypothesis, fix, and verification. For an interface change, name the specific pane or control and list the features affected. Keep design work separate from capture, schema, and workflow changes unless the task requires them.
4. Open a PR and wait for the relevant CI checks when preparing a merge. When the user asks for a merge, verify the merged commit is on `main`. Report what CI checked and which hands-on checks remain. Give the normal pull/build/open command first. Previous worktrees and downloaded patches were troubleshooting workarounds.

## Where to work

| Area | Start here |
| --- | --- |
| App Center, menu bar, Settings, Apps and Recovery | [NotifdexApp.swift](Sources/NotifdexApp/NotifdexApp.swift), [AppCenterPresence.swift](Sources/NotifdexApp/AppCenterPresence.swift) |
| Inbox, detail pane, People, Today, Flagged, Saved, Hidden and Notes | [WorkflowView.swift](Sources/NotifdexApp/WorkflowView.swift), [Inbox.swift](Sources/NotifdexCore/Inbox.swift), [InboxPresentation.swift](Sources/NotifdexCore/InboxPresentation.swift) |
| Appearance, built-in guide and local documents | [AppAppearance.swift](Sources/NotifdexApp/AppAppearance.swift), [UserGuideView.swift](Sources/NotifdexApp/UserGuideView.swift), [SavedDocumentsView.swift](Sources/NotifdexApp/SavedDocumentsView.swift) |
| Accessibility adapter, parser and recovery | [NotificationReader.swift](Sources/NotifdexMac/NotificationReader.swift), [NotificationTree.swift](Sources/NotifdexMac/NotificationTree.swift), [Observation.swift](Sources/NotifdexCore/Observation.swift), [CaptureWorker.swift](Sources/NotifdexMac/CaptureWorker.swift), [RecoveryAutomation.swift](Sources/NotifdexMac/RecoveryAutomation.swift) |
| Storage, settings and relationship templates | [CaptureStore.swift](Sources/NotifdexCore/CaptureStore.swift), [AppSettings.swift](Sources/NotifdexCore/AppSettings.swift), [data model](docs/data-model.md), [templates](templates/README.md) |
| Command-line collector | [NotifdexCapture/main.swift](Sources/NotifdexCapture/main.swift), [README](README.md#try-capture-on-the-mac) |
| Behavior and verification | [App Center acceptance](docs/app-center.md), [reliability matrix](docs/reliability.md), [formal model and implementation mapping](docs/formal-methods.md), [CI](.github/workflows/checks.yml) |

## Current product decisions

- **App Center.** Top-level tabs are Inbox, Apps, and Recovery. Inbox has a sidebar at wide sizes and a View picker at narrower sizes. Preserve per-view search, filtering, grouping and sorting, read/unread, flag/save, hide rules and undo, open-in-app, linking, workspaces, follow-ups, and explicit back navigation. Check that opening the only unread alert or unflagging the displayed alert can leave usable detail when its row leaves the filter.
- **Alert detail.** The right-hand pane inside Inbox shows actions such as Open in Gmail. It starts at the widest available split up to 640 points, with at least 250 points reserved for the feed. The divider remains adjustable. At narrow sizes the detail uses a single-pane view with Back to alerts. App Center uses the original startup size and native window controls. The experimental Window Size menu was removed in [PR #54](https://github.com/qzyu999/notifdex/pull/54), which supersedes [#52](https://github.com/qzyu999/notifdex/pull/52) and [#53](https://github.com/qzyu999/notifdex/pull/53). macOS CI passed. Physical divider and menu testing was still pending at handoff.
- **Appearance.** Keep Glass and Standard as selectable themes. Glass uses the violet backdrop and frosted surfaces. Settings exposes both appearance choices directly, with the active choice marked, and retains Show data folder. The previous nested hover menu was hard to use. Check light and dark appearances, Reduce Transparency, Increase Contrast, and selection contrast when changing styling.
- **People and Notes.** People can belong to multiple workspaces. A person's timeline in a workspace includes linked alerts routed to that workspace and linked alerts without an assigned workspace. A person's memberships and an alert's workspace are independently editable. Personal Notes have a one-level folder layout and Unfiled. The People Notes view and the People profile edit the same stored notes. Relationship templates are versioned and person-scoped.
- **Docs.** Docs opens the built-in Notifdex how-to. The separate local document library lives in Notes under Saved Documents. It accepts UTF-8 text or Markdown into a draft. See [#46](https://github.com/qzyu999/notifdex/pull/46), [#49](https://github.com/qzyu999/notifdex/pull/49), and [#50](https://github.com/qzyu999/notifdex/pull/50).
- **Future AI.** [#48](https://github.com/qzyu999/notifdex/issues/48) is an exploration of chat grounded in local Docs, Notes, and notification history. [#5](https://github.com/qzyu999/notifdex/issues/5) tracks opt-in AI summaries. Discuss local inference, user-configured OpenAI- or Anthropic-compatible endpoints, and an optional paid hosted route through Inference Exchange or providers such as DeepInfra as design options. Decide source permissions, citations, incomplete context, retention, and trust boundaries before implementation. Treat retrieved content as data. External processing requires explicit opt-in. Keep capture and storage usable offline. CRM inference and outbound actions require their own product contracts.

## Build and verify

On the user's Mac, quit Notifdex from its menu bar before rebuilding. Also stop a Terminal collector if it is using the app's database. From the existing checkout on `main`:

```bash
cd ~/projects/notifdex && git pull --ff-only && bash tools/build-app.sh && open dist/Notifdex.app
```

- The script builds and ad-hoc signs the app, checks resources and replay behavior, and writes `dist/Notifdex.app`. Follow the [README](README.md#run-the-menu-bar-app) for installation to `~/Applications` and launch at login. The packaged app needs its own Accessibility grant and may need it again after a rebuild.
- If local changes block the pull, inspect `git diff` and preserve the specific edits. The prior WhatsApp patch is already on `main` via [#51](https://github.com/qzyu999/notifdex/pull/51). If the checkout still carries those exact edits, stash the affected files as a backup before pulling.
- A standalone Command Line Tools installation on the test Mac previously failed to resolve `XCTest`. macOS CI ran those tests. Keep the production build independently runnable, and follow the existing observable-model pattern in the UI. The app's build contract guards against using `@State` because of an unavailable compiler plugin on that toolchain.
- The test Mac also reported Swift build-database I/O and a missing generated compiler input. The cause was unconfirmed. If it recurs, capture the actual error and `swift --version`. SwiftPM's native backend is a targeted diagnostic when applicable. A passing CI run also publishes a universal app artifact that can unblock device testing.
- Run `swift test`, the Python contract suite, and all TLC configurations for foundation changes. Model stateful durability or recovery changes in TLA+ before implementation. Keep model assumptions, implementation mapping, tests, and limitations together. UI-only changes use the relevant layout contracts and a manual Mac check. CI also builds release binaries, packages native and universal apps, and smoke-tests menu bar startup and shutdown.

```bash
python3 -m unittest discover -s contract-tests
swift test
TLA_JAR=/absolute/path/to/tla2tools.jar bash tools/check-model.sh
```

## Triage missing notifications

1. Check the alert's path in order: **iPhone notification → macOS Notification Center → Notifdex**. A locked screen, Sleep Focus, and a sleeping Mac are distinct test conditions. Check app notification settings and iPhone forwarding when the Mac received no alert. If the original alert is already gone, use a fresh synthetic message with the Mac awake, the chat closed, and Focus off. The iPhone badge identifies a forwarded alert on the Mac.
2. If the Mac has the alert but the Inbox does not, check the Notifdex app toggle, collection status, Accessibility grant, filters, and Hidden. Expand the app stack in Notification Center and try **Recovery → Recover now** while the alert is retained.
3. When needed, run an isolated live capture. Send a fresh synthetic message once capture starts. Add `--recover` to inspect retained alerts for 30 seconds and manually expose the target stack. Use the account probe only for X or Gmail. For WhatsApp, compare the scanner's counts with the exact Accessibility label and banner structure using a synthetic marked message.

```bash
swift build -c release --product notifdex-capture &&
  notifdex_bin="$(swift build -c release --show-bin-path)" &&
  notifdex_probe="$(mktemp -d)" &&
  "$notifdex_bin/notifdex-capture" --db "$notifdex_probe/capture.db" \
    --source whatsapp-test --app WhatsApp --diagnostics
```

- **Known WhatsApp case.** macOS exposed a plain-looking app label prefixed by the invisible direction mark `U+200E`. The old exact match silently skipped it. Passing the marked label captured one observation, then counted the next poll of the same banner as a duplicate. [#51](https://github.com/qzyu999/notifdex/pull/51) trims edge direction marks from the parsed app label and preserves the raw Accessibility description. On current `main`, use `--app WhatsApp`.
- For a personal notification, collect only the sanitized evidence needed: whether each stage saw it, approximate time, scan counts and issues. Keep personal messages, databases, credentials, and machine-specific capture files out of Git and CI. Treat a silent scan as unknown upstream delivery. Consult [reliability](docs/reliability.md) before claiming coverage.

## Storage and matching invariants

- Use one SQLite database with atomic transactions and acknowledge only committed evidence. The default app data folder is `~/Library/Application Support/Notifdex`, with `capture.db` and `settings.json`. Keep the live collector's source ID stable for that Mac and login. Scope event identity to the collector source and retain changed renderings as revisions.
- Track observation time, source event time, UI visibility, delivery coverage, and workflow state independently. Preserve historical gaps across restart, revocation, sleep, or interruption. Recovery reports the outcome of the local scan. Missing alerts leave prior delivery and user activity unknown.
- Preserve provenance and parser version. App labels and sender display names are observed text. Verified identities and explicit person links have separate evidence. Never create or merge people solely by display name.
- Use [the issue tracker](https://github.com/qzyu999/notifdex/issues) for current priorities. Active lines of work include [account attribution](https://github.com/qzyu999/notifdex/issues/3), [signed macOS updates](https://github.com/qzyu999/notifdex/issues/20), [the public Mac beta](https://github.com/qzyu999/notifdex/issues/22), and the AI discussions above. Verify issue state before treating an older proposal as a current requirement.
