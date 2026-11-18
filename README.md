# Notifdex

Notifdex is a local **notification index** for macOS. It indexes alerts that
macOS exposes so you can find them later, connect them to people, and schedule
follow-ups.

The first milestone is durable notification collection. The repository starts
fresh here. The earlier Python/web implementation is preserved on
[`archive/notif-mgmt-2026-11-17`](https://github.com/qzyu999/notifdex/tree/archive/notif-mgmt-2026-11-17)
at `fafd4ca47d42b54f9ac614841e5e63e8e4f3cfcc`. The new tree retains Git ancestry,
so existing history remains accessible. Existing issues and other branches are
still available as historical context.

## Current scope

- **Inbox** groups and searches captured alerts. Save an alert or hide recurring noise.
- **People** connects alerts across apps to a person and their handles or addresses.
- **Today** lists open follow-ups by due date. Complete or snooze them from the list.
- A native menu bar app with App Center toggles and capture status.
- A shared Accessibility collector and transactional SQLite storage, also usable from Terminal.
- Explicit app allowlist, stable device/login source namespace, and banner revisions.
- Durable capture runs and coverage gaps for startup, restart, sleep, scan failure,
  permission loss, and interrupted polling.
- SQLite failure/replay tests, Swift unit tests, and finite TLA+ safety and progress models.

The app is packaged locally with ad-hoc code signing. Capture is best effort:
macOS may expose only some alerts and can redact previews. AI suggestions and
relationship templates are planned. Automated recovery depends on the
Notification Center controls available on your Mac.

## Run the menu bar app

Stop the Terminal collector with Ctrl-C before launching the app. Both use the
same SQLite database and exclusive owner lock. From your clone:

```bash
git pull --ff-only
bash tools/build-app.sh
mkdir -p "$HOME/Applications"
ditto dist/Notifdex.app "$HOME/Applications/Notifdex.app"
open "$HOME/Applications/Notifdex.app"
```

Click the tray icon in the menu bar, then **App Center**. Grant **Notifdex** its
own Accessibility permission in System Settings. Terminal's earlier grant belongs
to Terminal. The app polls for permission changes. If the system continues denying
access after granting it, quit and relaunch the app. Future ad-hoc rebuilds may
need a renewed permission grant. Quit the installed app before replacing it.

The Apps tab has toggles for X, Messages, Discord, Slack, Gmail, LinkedIn, WhatsApp,
and custom exact notification labels. X and Messages are enabled on new installs.
Existing capture preferences are preserved.
Settings persist in `~/Library/Application Support/Notifdex/settings.json`.
When the existing database has exactly one collector source, the app adopts that
source namespace so replay can recognize prior CLI observations. Otherwise a new
source UUID is persisted. The Recovery tab shows the source identity for inspection.

In Inbox, choose **Recent** or **By App**. Open **People** to see linked alerts
and **Today** to track follow-ups. The Recovery tab has **Recover now**, automatic
recovery on launch, wake, or app selection changes, and launch at login.
Login-item registration failures are shown. Installing to `~/Applications` before
enabling launch at login gives the helper a stable application path.

Automated recovery may visibly open Notification Center. It uses the clock's
Accessibility action, expands selected app stacks, and attempts exposed page-scroll
or scrollbar controls. It bounds navigation to 20 steps and 20 seconds and stops
on unchanged viewports, unavailable controls, cancellation, or permission errors.
It closes a panel it opened when the retained list is still detectable. Empty
history and panel visibility can be ambiguous, so the panel may stay open in that
case. Ordinary notification activation, reply, dismiss, and clear controls are
outside the navigation path. Unsupported controls are reported in recovery status.

The app selectors operate on observed notification labels. They do not connect
to social accounts. App-specific notification settings and iPhone forwarding
still determine which alerts reach the Mac. Automatic recovery starts enabled;
you can switch it off on the Recovery tab.

See [the app acceptance checklist](docs/app-center.md) for the first device test.

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

### Recover retained notifications after a restart

Every launch scans currently accessible notifications and uses durable database
identity to skip observations already saved. For alerts retained inside Notification
Center, stop the existing collector and run a recovery pass:

```bash
.build/release/notifdex-capture \
  --db "$HOME/Library/Application Support/Notifdex/capture.db" \
  --source macmini-2-jared \
  --app X --recover
```

The pass lasts 30 seconds. Open Notification Center by clicking the Mac's clock,
expand the X stack, and scroll through retained alerts while it runs. Each readable
alert from the selected app goes through the same parser and SQLite deduplication
as live banners. Other named apps can be included with repeated `--app` options.
Reading a snapshot saves its accepted observations in one transaction. A malformed
banner is reported separately, and valid banners from a partial scan can be saved
while the coverage gap stays open.

Example per-snapshot output:

```text
Scan: observed=3 new=1 duplicates=2 issues=0
Observed banner IDs: ...
```

This proves the collector actually read three allowed-app observations and saved
one new rendering. Counts describe each poll and may repeat across polls. They
are not counts of unique platform messages. `observed=0` means no selected-app
alerts were exposed in that poll. The final summary reports newly saved observations
and the maximum observed in a single poll. Recovery includes diagnostics automatically.
Use `--diagnostics` during normal capture to inspect counts and IDs continuously.
Logs omit sender names and message previews.

To test backfill, stop capture, send a uniquely marked DM, let its banner retire
into Notification Center without clearing it, then run `--recover` and expose it.
To test replay, run the same pass again with the same source and database. A
stable banner ID and unchanged rendering should produce `new=0 duplicates=1`
when that one alert is observed. If macOS changes the ID or rendering, a new
observation is preserved. ID continuity between live and retained views still
needs verification on each target macOS version. Identical message text alone
never merges distinct banners.

This UI-based recovery requires you to expose retained alerts. It does not open
the panel, expand groups, or scroll automatically. Cleared, unrendered, or
undelivered notifications may remain unavailable. A recovery pass leaves delivery
completeness unknown. Retained-alert traversal still needs validation on your Mac.

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
Conditional progress and overlapping-history recovery are checked in separate configurations.
`AppRecovery.cfg` checks enabled-app persistence boundaries, pause behavior,
navigation actions, bounded steps, and conditional recovery termination.
It is a finite model check. Implementation tests and real device trials establish
the correspondence to the actual collector and operating system.

### If the app appears frozen

Before restarting, capture a short process sample in Terminal:

```sh
sample Notifdex 3 -file "$HOME/Desktop/notifdex-hang.txt"
```

Share the sample when reporting a hang. It records thread stacks and process
metadata; inspect it before sharing. Then quit Notifdex (or use Activity Monitor
if its menu is unresponsive) before installing a new build. Keep `capture.db`
and `settings.json`; restart recovery uses the existing deduplication history.

The collector runs away from the UI thread. Accessibility IPC uses a 0.5-second
per-element timeout, with traversal/session deadlines checked between calls.
These are best-effort bounds on OS messaging, not hard real-time guarantees.
Status and settings acknowledgements are delivered in AppKit's menu-tracking and
modal modes as well as its normal run loop. Login-item service operations run on
a separate background queue so they cannot block the main UI thread.
