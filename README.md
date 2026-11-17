# Notifdex

A local notification rolodex for macOS. Notifications become evidence you can
review alongside people, their platform identities, and eventually reminders
and relationship summaries.

The first milestone is durable notification collection. The repository starts
fresh here. The earlier Python/web implementation is preserved on
[`archive/notif-mgmt-2026-11-17`](https://github.com/qzyu999/notifdex/tree/archive/notif-mgmt-2026-11-17)
at `fafd4ca47d42b54f9ac614841e5e63e8e4f3cfcc`. The new tree retains Git ancestry,
so existing history remains accessible. Existing issues and other branches are
still available as historical context.

## Current scope

- A Swift package with a native Accessibility collector and transactional SQLite storage.
- Explicit app allowlist, stable device/login source namespace, and banner revisions.
- Durable capture runs and coverage gaps for startup, restart, sleep, scan failure,
  permission loss, and interrupted polling.
- SQLite failure/replay tests, Swift unit tests, and finite TLA+ safety and progress models.

The menu bar interface, installer, signed application bundle, AI, funnels, and
CRM screens are future milestones. The executable currently runs in Terminal.
The capture adapter needs acceptance testing on each target macOS/app combination.
The conversation's live X experiment validated the API approach, not this complete collector.

## Try capture on the Mac

Use a fresh clone or a new worktree when switching from the archived implementation.
Building requires Apple's command-line developer tools. Grant Accessibility access
to the process responsible for capture, then restart it after changing permissions.
Terminal access from the earlier experiment may carry over. A packaged app will
need its own permission grant.

```bash
swift build -c release
.build/release/notifdex-capture \
  --db "$HOME/Library/Application Support/Notifdex/capture.db" \
  --source macmini-2-jared \
  --app X
```

Keep `--source` stable for the same Mac/login and database. Use another namespace
for a different collector/device or user. App names are exact, case-sensitive
labels from Accessibility. Add repeated `--app` options after inspecting each
app's actual label. An app label is observed display text, not a verified bundle ID.

Selected notification previews and their Accessibility descriptions are saved
locally. Capture output prints status and counts without message bodies. New
directories/files use private permissions. SQLite itself is unencrypted. The
process owns an exclusive lock beside its database to prevent two collectors
from managing the same capture lifecycle. Ctrl-C performs a graceful stop.

### Running unit tests on macOS

The test suite imports XCTest and needs a developer toolchain that includes it.
If `swift test` reports `unable to resolve module dependency: XCTest` while
`swift build -c release` succeeds, the collector is built and can run. The
standalone Command Line Tools selected under `/Library/Developer/CommandLineTools`
may lack the test framework. With Xcode installed at the standard path and its
first-launch setup completed, select it for this test command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Adjust the path for a different Xcode installation. If Xcode is absent, you can
run the collector with the successful release build and use GitHub Actions for
the XCTest suite until you install Xcode. SQLite is supplied by the macOS SDK;
installing `pkg-config` is unnecessary for this Mac build.

Apple's developer-tool selection reference is available at
https://developer.apple.com/library/archive/technotes/tn2339/_index.html.

To inspect metadata without displaying message content:

```bash
sqlite3 "$HOME/Library/Application Support/Notifdex/capture.db" \
  'SELECT id, app_label, origin, captured_at FROM observations ORDER BY id DESC LIMIT 20;'
sqlite3 "$HOME/Library/Application Support/Notifdex/capture.db" \
  'SELECT reason, started_at, ended_at, recovery_scanned_at FROM coverage_gaps ORDER BY id DESC;'
```

## Reliability contract

The collector observes rendered notifications available through macOS
Accessibility. Once a database commit succeeds, replaying the same source,
banner ID, and rendering stores one observation. A changed preview is a separate
revision. Two identical messages with distinct banner IDs remain distinct.
Receipt time means observation time; source send time stays unknown.

Sleep, device power, Focus, hidden previews, and delivery settings can prevent
an alert from being observable. A successful scan certifies that a traversal
completed. It leaves delivery completeness unknown. On interruption/restart,
we retain a gap record and scan the currently accessible UI again. This scan
does not open Notification Center or restore alerts that have disappeared.

See [the data model](docs/data-model.md), [failure matrix](docs/reliability.md),
[formal model mapping](docs/formal-methods.md), and [development plan](docs/plan.md).

## Checks

```bash
swift test
python3 -m unittest discover -s tests -v
TLA_JAR=/absolute/path/to/tla2tools.jar bash tools/check-model.sh
```

Python's standard library runs supplemental tests against the exact shipped SQL,
including killing a writer before COMMIT. Production code is Swift and SQLite.
The model runner uses TLA+ tools 1.7.4 in CI. TLC explores two abstract event
revisions with arbitrary visibility changes, crashes, and availability changes.
Conditional progress is checked in a separate stable-environment configuration.
It is a finite model check. Implementation tests and real device trials establish
the correspondence to the actual collector and operating system.
