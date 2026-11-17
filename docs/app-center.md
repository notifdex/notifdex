# App Center acceptance

The native app and CLI share `NotifdexMac/NotificationReader.swift` and the same
SQLite core. App Center adds a serial worker that owns the database, settings,
polling, and navigation session. Main-thread views receive value snapshots.
Only one collector holds the database's file lock at a time.

## Selection and concurrency

Toggle changes are saved and applied on the same serial queue as capture writes.
The UI receives the new selection after persistence. A current snapshot can finish
before that queued change is accepted. Once applied, the change cancels recovery
before the next snapshot; the new allowlist filters future accepted observations.
Pause is persistent and stops collection and recovery. Sleep opens a coverage gap;
wake can request recovery. Storage errors stop the worker, release ownership, and
surface a retry action. The next run records an unclean interval.

This boundary corresponds to `AppRecovery.tla`'s Configure/Pause transitions.
`lastWrite` in the model means the latest write action, not the entire historical
database. Existing observations remain historical evidence after selections change.
The new finite model checks 432 reachable states with two apps and three steps.
It asserts `OnlyEnabledPersist`, `PausedStopsRecovery`, `OnlyNavigationActions`,
and eventual recovery termination under weak fairness of navigation steps.
Native timeouts, UI layout correctness, and real permission behavior need device tests.

## Recovery controls

The driver finds `com.apple.menuextra.clock` under ControlCenter's
`AXExtrasMenuBar`. It detects retained history using `AXNotificationListItems`,
expands only `AXNotificationCenterBannerStack` elements whose app label matches
the selection, and uses an advertised page-scroll action or settable scrollbar.
The exact ordinary-banner subrole is rejected by the expansion policy. It checks
advertised actions before invocation and reports failure instead of retrying an
ambiguous press blindly. Empty history can make open/closed detection ambiguous.
The initial controls were informed by measurements published at
https://github.com/maestrojeong/cua-rs-mcp/blob/main/DESIGN.md#14-notification-center.
Those measurements use a different Mac; Notifdex's own UI trials are pending.

## First device trial

1. Stop the CLI. Build/install the app and grant Notifdex Accessibility access.
2. Open App Center. Verify prior X observations and the same source identity appear.
3. Send an X DM. Confirm it appears once in Recent and the saved count increases.
4. Disable X. Send another DM and verify it is not saved after the toggle is applied.
5. Enable X and use Recover now. Observe the clock/panel/stack actions and report
   the recovery status and scan counts. Avoid clearing the test alerts.
6. Run recovery a second time. Verify repeated IDs/renderings produce duplicates
   and distinct identical messages stay distinct.
7. Enable one other app and send an alert. Verify the observed app label matches.
   Use a custom label if the notification uses another display name.
8. Pause during recovery. Verify navigation stops and the pause survives a relaunch.
9. Test sleep/wake, revoked permission, Notification Center restart, and a locked
   screen using the failure matrix. Capture availability always remains best effort.
10. Enable launch at login from the installed path, log out/in, and inspect status.

The CLI and app cannot simultaneously own the database. Rebuilding an ad-hoc
signed app may reset its permission identity. No Apple Developer ID certificate
or notarized distribution package is provided in this prototype. The build script
verifies the signature and runs a packaged SQLite-resource/deduplication self-check.
