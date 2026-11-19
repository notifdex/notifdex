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

`spec/InboxWorkflow.tla` models saved status, explicit links, and one due date
and completion state per existing observation. It checks two alerts, two
people, two dates, and histories with relinking, snoozing and completion.
Scheduling reopens a completed follow-up. Saving does not change a link
or due date. Failed transactions are stuttering steps in this abstraction.
The foreign keys and migration test cover referential integrity and
preservation of existing evidence and links in SQLite. Swift tests exercise
manual linking across apps, duplicate names, normalized identities, and
reopening persisted follow-ups. The new SQL acceptance tests initially
failed because the v2 migration was missing and pass with it applied.

Hidden is the union of independent per-alert hides and app-scoped
title and body matches. The InboxWorkflow model checks the Inbox/Hidden
partition and verifies that removing one field rule leaves the other field
and individual hides effective. The configured match sets abstract already
evaluated app and exact-text checks. Swift tests validate those checks,
subsequent captures, and undo after reopening. The v7 SQL acceptance test
failed before the migration existed and now verifies that the original
Gmail body match, rule ID, and raw text survive the upgrade.

### Inbox flags and read views

The InboxWorkflow model verifies that visible flagged alerts exclude hidden
alerts, hidden alerts retain their flag, and read/unread partition Inbox and
Flagged. Changing a flag keeps read state, saved state, links, follow-ups,
and hide state intact. Each flag operation maps to one SQLite statement.
The SQL acceptance test first failed on the missing v6 migration and now
passes. Swift tests cover upgrade and reopening, overlapping hide reasons,
date ties, filtering before the limit, and lookup of an open alert after a
read-state change. The model does not simulate pagination or SwiftUI events.

### Person matching

`PersonMatch.tla` models one app/title key across three alerts. Captured
observations determine eligibility for backfill or future-only matching.
Explicit assignments and exclusions take precedence, and conflicting manual
destinations pause the derived links. Removing a rule leaves explicit state
intact. SQLite uses a unique key for the rules and computes links at read time
with an observation-ID cutoff. Its v4 migration preserves manual links. The
SQL acceptance test initially failed on the missing v4 schema and now passes.
The Swift test covers restart, different apps, title rules, conflicts, and undo.

### Person notes

`PersonNotes.tla` models adding, editing, and deleting notes for two
people. Each live note has one owner, and editing keeps the owner fixed.
The model abstracts SQLite commits as atomic transitions and failed writes
as stuttering. It omits timestamps, which the store records separately.
The SQL acceptance test failed before the v5 schema existed and passes
with it applied. Swift tests open an existing v4 database, exercise the
note lifecycle across store reopen, and reject edits or deletions for
another person.

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

### Relationship templates

`RelationshipTemplates.tla` checks two people, two immutable versions of one
template ID, two candidate definitions, two stages, and two independent
milestones. Person assignments pin an installed version. The model treats stage
and milestone IDs as validated inputs and uses the same finite ID sets for
both versions. The Swift tests also exercise a newer version with a different
stage set. The model abstracts database commits and failed writes, and checks
durable state. Swift tests separately assert returned assignments and errors.

| Case | Model action and property | Swift store verification |
| --- | --- | --- |
| Install or replay | `Install`, `PreserveExisting` | Equal definition returns the installed version. Changing its contents reports a conflict. |
| Apply or replay | `Apply`, `CompleteAssignments`, `PreserveExisting` | Initial stage and unchecked milestones commit together. Reapplying after progress preserves it. |
| Explicit progress | `SetStage`, `SetMilestone`, `SafeSteps` | Repeated stage and checkbox sets have the same result. Setting or clearing a milestone leaves the stage intact. |
| New version | `Install` and `Apply`, `PreserveExisting` | A new person can use v2. The existing person keeps v1 and applying v2 to them reports a conflict. |
| Failed write and retry | `FailedWrite`, `CompleteAssignments`, `SafeSteps` | A trigger aborts the second milestone insert. Reopening finds no assignment, and retry after removing the trigger succeeds. |

The v8 migration adds tables under the existing SQLite write transaction and
advances `user_version` on commit. The Swift migration fixture opens a v7
database with captured evidence, links, notes, hide rules and follow-up state.
It also round-trips the separate capture settings file. The SQL atomicity test
failed on the missing schema before implementation. The standalone model ran
before the Swift store change and checked 7,378 reachable states.
