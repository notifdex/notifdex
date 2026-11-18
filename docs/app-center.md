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
3. Send an X DM. Confirm it appears once in Inbox and the saved count increases.
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

### Check which X or Gmail account received an alert

Use synthetic DMs and emails for this test. The probe prints text attributes for
the first matching alert. It does not open alerts or write to the capture database.

```sh
swift build -c release --product notifdex-capture
.build/release/notifdex-capture --probe-account NOTIFDEX-ACCOUNT-TEST --app Gmail
```

1. With both accounts signed in, start the probe and send an email from a third
   account to mailbox A. Use `NOTIFDEX-ACCOUNT-TEST` as the subject or in the
   first line of the message so it appears in the preview.
2. Keep the output and dismiss that test alert. Run the same command and send
   the same email from the same sender to mailbox B. Repeat with the other
   mailbox active in Gmail to check whether the signal follows the recipient.
3. Run the same comparison with `--app X` and the marker in the DM text.
   Use the same sender and matching text for both receiving accounts.
4. If testing retained alerts, leave the matching alert in Notification Center
   and open its stack while the probe waits. Compare the live and retained fields.

Terminal needs Accessibility permission for the probe. If an alert is missed,
make sure iPhone mirroring shows a preview and only the intended test alert
with the marker remains. Review output before sharing because it may contain
account identifiers. A different banner UUID identifies a different alert, and
does not establish which account received it. Look for a field that follows the
recipient when the foreground account changes.

### Try the Inbox → People → Today workflow

1. Open **App Center → Inbox**. Search for a captured alert or filter by app.
2. Select the alert and click **Save for later**. It appears in **Saved**.
3. Enter a name and click **Create and link**. Select an alert from a different
   app and choose the same person under **Link to person**.
4. Open **People** and choose the person to see both alerts and add handles
   or addresses. These links are manual. Names on notifications can overlap.
5. Select either alert, choose a due date, and click **Add follow-up**.
   Open **Today**, select it, then use **Snooze a day** or **Mark done**.
   Today lists open follow-ups, including future ones, in due-date order.

The first launch migrates the existing local capture database to version 2.
Use the rebuilt app and CLI with that database. Older builds reject version 2.

### Hide alerts and subject matches

Use **Hide** on an Inbox row. **Hide this alert** affects just that entry.
**Hide all with this subject** affects past, current, and future alerts from
the same app with exactly the same captured subject text. Gmail is the first
supported subject source, using the subject shown in its captured preview.

Click **Undo** in the Inbox to reverse the latest hide. At any time, use
**Hidden** to undo an individual hide or remove a subject rule. If both
apply to an alert, remove both to restore it. Saved items, follow-ups,
and person activity remain accessible from their own views.

The filter update upgrades the local database to version 3 on first launch.

Select an alert to mark it read. An unread dot and stronger text distinguish
unopened rows. Use **Mark unread** to put the dot back. Follow-up completion
is a separate action under **Today**.

Use **Open in X**, **Open in Gmail**, or the matching app button to jump back
to that service. WhatsApp tries the installed app first and falls back to
WhatsApp Web. Notifdex opens the app or inbox because captured alerts do not
currently include a link to the exact conversation.

App Center appears in the Dock and app switcher while its window is open.
Closing the window returns Notifdex to the menu bar and leaves capture running.
**Today** lists open follow-ups, including future ones, ordered by due date.
**Hidden** is the last Inbox view.

### Remember a person match

Open a linked alert and choose **Remember this match…**. Review the exact
app and title, destination person, and the number of existing unlinked
matches. Choose **Existing and future** or **Future only**. Future means
newly captured by Notifdex after you confirm, including retained alerts
that have never been captured.

Matching is exact. X and Twitter share the X category. An engagement label
such as “Liked by Example” is its own title. If the same app and title are
manually linked to different people, the rule pauses. **Unlink and skip
matching rules** keeps that alert out of rules you create later. The
person card lists rules so you can remove them and undo their links.
Older manual links are preserved. Earlier unlinks had no stored marker to migrate.

### Keep notes on a person

Open **People**, choose a person, and click **Add note…**. Notes are dated
and saved in your local database. Use **Edit…** to change or delete a note.
The v5 database upgrade adds notes and preserves existing people and alerts.

### Apple Messages

Messages is enabled by default on a new install. If you already use
Notifdex, check **App Center → Apps → Messages**. Existing capture settings
are preserved, including when Messages is off. Send a fresh text
to the Apple Account or number configured in Messages on this Mac and check
**Inbox → Messages** after the Mac alert appears. If using SMS, MMS, or RCS,
[set up text message forwarding](https://support.apple.com/guide/messages/set-up-messages-ichte16154fb/mac)
if needed. Notifdex captures the notification preview that macOS exposes.
Messages history and sending are handled by the Messages app.


### Choose how the Inbox is arranged

Inbox starts with **All** alerts in one list, newest capture first. Choose
**Unread** to see alerts you haven't opened in Notifdex, or **Read** to find
alerts you've opened. Opening an unread alert keeps its detail available
even after it leaves the Unread list.

Use **View** to group by app or switch between **Newest first** and **Oldest
first**. Both date orders work inside each app group. Click an app heading
to expand or collapse it. The app filter and search work in either layout.

Click the flag next to an alert to find it again in **Flagged**. Removing
the flag drops it from that view. A hidden alert keeps its flag and returns
to Flagged when all reasons for hiding it are removed.
