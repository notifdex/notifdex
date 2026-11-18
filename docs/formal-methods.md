# Formal model and implementation correspondence

`spec/Capture.tla` has three executable TLC configurations. They use two abstract
event revisions. Larger instances can be checked by changing `Events` in a copy
of the configuration. Checking one finite instance establishes the listed
properties for that instance and abstraction. It does not establish arbitrary
OS behavior, runtime correctness, cryptographic identity, or indefinite hardware durability.

| Model | Implementation/assumption | Verification |
| --- | --- | --- |
| `Events` | Source/banner/rendering tuples, each abstracted to one symbol | SQL uniqueness, different IDs/revisions/source tests |
| `visible` | UI available to collector | `Show`/`Hide` arbitrary; real adapter tests required |
| `pending` | Snapshot in volatile memory | Process crash may discard it |
| `stored` | Committed observations | SQLite transaction, WAL, FULL; process-death/reopen tests |
| `acknowledged` | Successful return / saved status | Print only after record or recordBatch returns successfully |
| `running` | Collector lifecycle | Crash/restart; durable heartbeat bounds gap |
| `accessible` | Combined availability of UI/permissions/polling | Suspend/restore abstraction; no inferred phone state |
| `gap` | Active interruption requiring scan | Historical intervals persist separately in SQLite |
| `Scan` | One successful local UI snapshot | Empty success leaves upstream completeness unknown |

## Safety

- `TypeOK` bounds all state to the configured events and booleans.
- `AcknowledgedIsDurable` requires acknowledgements to refer to committed evidence.
- `DurableNeverDisappears` checks that stored observations survive every modeled action.
- `UnavailableIsMarked` requires an active gap whenever capture is stopped,
  unavailable, or awaiting a recovery scan.

Set-valued storage abstracts effect idempotence. The implementation's UNIQUE
constraint is independently tested, since the abstract set cannot represent
duplicate database rows. Individual transactions map to atomic `Commit(e)`.
Atomic recovery snapshots map to `CommitBatch`, which commits a subset of pending
observations together. Constraint failure rolls back the entire accepted batch.
Disk-write failure is a stuttering step followed by an error/exit, with no
acknowledgement. Source events hidden before scanning may disappear forever.
Observations read into RAM can also be lost before durable commit. The model
deliberately allows that loss.

The invariant refers to abstract failures visible to the model. An actual crash
cannot synchronously write a gap. The implementation records an unclean interval
on the next successful startup. An external UI observing a dead process must
also treat its heartbeat as stale. Phone power and Focus are not observable
model inputs in this milestone, so they never produce invented certainty.

## Conditional progress

`Progress.cfg` starts with both events visible and checks that both eventually
reach durable storage. The environment then stays running and accessible, and
each continuously enabled scan/commit receives weak fairness. Real storage
must eventually succeed and the collector must keep running for this claim to
apply. `Capture.cfg` permits repeated crashes and hides, so it asserts safety
without unconditional eventual capture.

`Recovery.cfg` starts with one event already stored and both events retained in
the accessible UI. It checks eventual storage of the missing event with the same
stable-environment fairness assumptions. The implementation regression checks a
reopened database with overlapping history, exact inserted/duplicate counts, and
batch rollback on invalid input. The UI adapter may expose only expanded or
onscreen alerts. Scanning retained UI requires the user to open/expand/scroll
Notification Center, and no historical-completeness property is asserted.

## TDD and refinement workflow

For the next change, write a failing contract test, identify the model transition
and assumption it changes, run TLC, implement the smallest passing change, then
run the full suite. An adapter bug needs a synthetic Accessibility fixture plus
a regression test, followed by an actual device acceptance trace. Keep proofs
about committed evidence distinct from tests about delivery/visibility.

Foundation validation in this workspace on 2026-11-17 found 224 reachable safety
states and 10 stable-progress states with no violation. The eight supplemental
SQLite tests passed, including process death during an uncommitted transaction.
Swift/macOS checks run in GitHub Actions because this workspace has no Swift SDK.
An acknowledgement-before-storage mutation of the model produced the expected
`AcknowledgedIsDurable` counterexample. The native NUL regression failed before
switching SQLite text bindings to explicit UTF-8 byte lengths.
The restart regression also first failed with an obsolete active startup gap.
Restart now bounds the old process's intervals and transfers active uncertainty
to the new startup-scan interval, preserving all historical rows.

The recovery extension checked 224 safety states, 10 stable-progress states,
and 7 overlapping-history recovery states locally with no violation. The native
tests cover a replayed snapshot and a constraint failure partway through a batch.
Actual retained-UI traversal and banner-ID continuity remain device acceptance work.

## Menu responsiveness regression (2026-11-17)

The menu-tracking tests run the real worker against a paused, temporary fixture
database, then update settings while the main run loop stays in event-tracking
mode. A separate callback test isolates delivery from storage and permissions.
The pre-fix main-dispatch implementation fails these acceptance conditions;
the fix schedules callbacks in normal, menu-tracking, and modal run-loop modes.
A modal-mode stop assertion also protects graceful termination.

This changes adapter scheduling and per-element AX messaging timeouts, not
storage transitions or recovery actions. The existing four TLC configurations
still apply. Their fairness assumptions do not prove responsiveness of AppKit,
Notification Center, or Login Items; device testing and hang samples remain
necessary. Settings acknowledgements now follow their own completed request,
rather than an unrelated scan heartbeat.

The red acceptance run (`44192090553`) reproduced three failed assertions in
the two menu-tracking tests. The fix run (`44192435367`) passed 22 Swift tests,
8 SQLite contract tests, all four finite TLC configurations, real-worker app
startup/shutdown, and native/universal packaging. These CI results use synthetic
data and do not establish recovery coverage on a user's device.

### Inbox, person links, and follow-ups

`spec/Rolodex.tla` models saved status, explicit links, and one due date
and completion state per existing observation. It checks two alerts, two
people, two dates, and histories with relinking, snoozing and completion.
Scheduling reopens a completed follow-up. Saving does not change a link
or due date. Failed transactions are stuttering steps in this abstraction.
The foreign keys and migration test cover referential integrity and
preservation of existing evidence and links in SQLite. Swift tests exercise
manual linking across apps, duplicate names, normalized identities, and
reopening persisted follow-ups. The new SQL acceptance tests initially
failed because the v2 migration was missing and pass with it applied.

Inbox visibility is derived from independent per-alert hides and app/subject
rules. The Rolodex model checks that Inbox and Hidden partition the captured
alerts. Hiding and reading leave saved items, links, and follow-ups unchanged.
The SQLite migration acceptance test failed on the missing v3 schema before
implementation. The Swift test checks exact matches, later captures, rule
removal, and combinations of both kinds of hide.

### Person matching

`PersonMatch.tla` models one app/title key across three alerts. Captured
observations determine eligibility for backfill or future-only matching.
Explicit assignments and exclusions take precedence, and conflicting manual
destinations pause the derived links. Removing a rule leaves explicit state
intact. SQLite uses a unique key for the rules and computes links at read time
with an observation-ID cutoff. Its v4 migration preserves manual links. The
SQL acceptance test initially failed on the missing v4 schema and now passes.
The Swift test covers restart, different apps, title rules, conflicts, and undo.

### Notification Center fixture coverage

The macOS tests supply a synthetic tree at the read-only Accessibility
boundary: windows and children, banner/alert subroles, identifiers,
attributed descriptions, and title/body values. The production scanner
uses the same traversal, parsing, and app allowlist. A stale sibling
fixture initially reproduced the existing all-or-nothing traversal.
The end-to-end fixture drives the real capture worker, SQLite and Inbox
query, including repeat capture and a denied permission case.

The Capture model's PartialScan action allows readable observations to
commit while keeping coverage marked as incomplete. This abstracts
failed subtrees. The fixtures cannot certify Accessibility permissions
after installation, the live iPhone mirroring path, or undocumented
changes to the OS tree. Verify those on a Mac with fresh test alerts.
