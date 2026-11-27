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

Removing a relationship template is a version-scoped `Remove` step. It
clears one person's assignment and progress atomically. SQLite uses the
existing assignment-to-milestones cascade. Other assignments and installed
versions are preserved. The Swift test covers a mismatched version, a
repeated removal, and reapplying from the initial stage. It also checks that
notes and workspace membership survive. The People control acceptance check
failed before the workspace menu and removal confirmation were added.

### People workspaces

`PeopleWorkspaces.tla` models two workspaces, two people (`alex` and `sam`), and two alerts
with dynamic linking (`Link`), membership (`SetMember`), routing (`Route`), workspace creation (`Create`),
and failed writes (`FailedWrite`). It checks referential integrity (`ValidReferences`), independent changes
to membership, routes, and links (`IndependentChanges`), cross-person workspace isolation (`CrossPersonWorkspaceIsolation`),
and both isolation and completeness of the scoped People timeline (`ScopedTimeline`, `TimelineComplete`).
A linked alert appears for a workspace member if its route is unassigned or matches the workspace.
Explicit set and remove operations are idempotent. A write failure leaves durable state unchanged.
The model omits workspace labels, search, and UI state.

### Collector lifecycle, flock exclusion, and recovery gaps

`CollectorLifecycle.tla` unifies two competing collectors (`app` and `cli`), exclusive database lock ownership (`flock`),
availability guards (`permission`, `paused`, `sleeping`, non-empty app selection), recovery panel cleanup (`panelOpen`),
typed open gap classes (`collector_stopped`, `unavailable`, `partial_scan`, `recovery_navigation`), and `RecoveryBudget`
step/unchanged limits. It checks:

- `AtMostOneWriter` and `ExclusiveWriteActions`: no collector can mutate gaps or run recovery without holding the lock.
- `FailedRecoveryNotMaskedByLiveScan`: a failed recovery session keeps `recovery_navigation` open even across subsequent clean live scans, until a later recovery completes (`CaptureStore.recover(..., excluding: ["recovery_navigation"])`).
- `UnavailableStopsRecovery` and `NoLeakedPanel`: losing permission, pausing, sleeping, or disabling all apps terminates recovery and closes the Notification Center panel.
- `BudgetBoundsRecovery`: active recovery stays strictly within `MaxSteps` and `MaxUnchanged`.

### Inbox detail continuity and hide undo

`InboxSelection.tla` models view switching (`inbox`, `unread`, `flagged`, `hidden`), detail selection,
read/flag toggles, explicit per-alert hides, hide rules, and one-step hide undo (`lastHide`). It proves:

- `SelectedNeverHiddenInVisibleViews` and `SelectedAlwaysHiddenInHiddenView`: visible views never keep a hidden alert open, and the Hidden view only keeps hidden alerts open.
- `DetailContinuity`: marking the open alert read in `unread` or unflagging it in `flagged` keeps its detail pane open (`CaptureStore.selectedInboxEntry`), while hiding the open alert from any visible view clears selection immediately, and undoing the last explicit hide clears both the hide entry and the undo slot.
- `LastHideIsHidden`: the undo slot never references a non-hidden alert.

The v9 migration adds three tables in the existing transaction. Each
membership is one person/workspace pair. An observation route is one
workspace per alert and is stored separately from the observation and link.
The SQL contract failed on the missing migration before implementation.
The Swift fixture opens a v8 database, exercises routing and membership
independently, and verifies after reopen that preexisting people, alerts,
identities, notes, and template progress survived. It also checks workspace
scoping before search and that a failed attempt to create a person in an
unknown workspace rolls back the person record.

The People timeline regression (#42) arose because it applied an exact
alert-route filter even to linked alerts with no route. The existing
workspace fixture encoded this empty result. Adding the `TimelineComplete`
invariant before changing the model produced a counterexample immediately
after adding a person to a workspace. The corrected model and Swift store
include unassigned alerts through the person's membership without writing
any routes. Swift tests cover migrated links, a new rule-linked capture,
search, explicit routing and clearing, and selected alert lookup. An
ordinary workspace-filtered inbox continues to require an explicit route.

### Appearance preferences and surface orthogonality (#70)

`spec/Appearance.tla` (`spec/Appearance.cfg`) models surface finishes (`clearGlass`, `ambientGlass`, `customImage`, `standard` / Solid), color pigments (`Themes`), custom backdrop presence, and macOS accessibility overrides (`reduceTransparency`, `increaseContrast`). It corresponds directly to `Sources/NotifdexCore/AppearancePreferences.swift` (`AppearanceState`), which `AppearanceSettings` in `Sources/NotifdexApp/AppAppearance.swift` delegates to:

- `SolidNeverTransparent`: `standard` (Solid) never enables glass panels or a transparent window.
- `AccessibilityForcesOpaque`: enabling macOS Reduce Transparency or Increase Contrast forces opaque rendering without mutating stored user preferences.
- `SolidAppliesPigmentUnlessHighContrast`: Solid mode applies the selected pigment's opaque matte finish unless Increase Contrast is enabled.
- `OrthogonalPreferences`: selecting a color theme (`SelectTheme`) never changes `surface` (preventing the #70 regression where Solid snapped back to Clear), selecting a surface never changes `theme`, and importing or removing a custom backdrop preserves `theme` while only falling back from `customImage` to `clearGlass` when a photo backdrop is removed.

The new contract test in `contract-tests/test_app_center_layout_contract.py` failed before implementation (missing `AppearancePreferences.swift` and Solid pigment rendering) and passes after the fix alongside `Tests/NotifdexCoreTests/AppearancePreferencesTests.swift`. Visual contrast and macOS light/dark appearance checks remain hands-on device verification.

### Window chrome ownership, compact titlebar height, sidebar accounting, and multi-monitor drag stability

`spec/WindowChrome.tla` (`spec/WindowChrome.cfg`) and `spec/WindowDrag.tla` (`spec/WindowDrag.cfg`) formally specify App Center's native AppKit window ownership (`appkit_window_controller`), single toolbar ownership (`appkit_toolbar`), native titlebar hit-target routing (`native_theme_frame`), SwiftUI hosting sizing isolation (`sizingOptions = []`), compact titlebar height (`unifiedCompact` <= `44pt`), brand visibility without macOS 26/27 pill bubbles (`item.isBordered = false`), global control reachability, activation-policy ordering (`regular` before/while open, `accessory` when closed), drag-safe transparency synchronization, and offscreen-titlebar bounds recovery. They correspond to `Sources/NotifdexCore/WindowChromeLayout.swift`, `Sources/NotifdexApp/AppCenterWindowController.swift`, and `Sources/NotifdexApp/WorkflowView.swift`:

- `NativeAppKitWindowOwnership` and `SingleTitlebarOwner`: require App Center to be owned by a native AppKit `NSWindowController` + `NSWindow` with a single native `NSToolbar` (the Safari/Mail architecture) instead of SwiftUI's `Window` scene (`_TtC7SwiftUI12AppKitWindow`) or a dual-owner titlebar.
- `TitlebarHitTargetIsNative` and `SwiftUISizingIsolatedFromWindowFrame`: `AppCenterRootView.hitTest(_:)` returns `nil` for `y >= window.contentLayoutRect.maxY`, the edge-to-edge backdrop sits in a non-interactive container, and `NSHostingView` is pinned strictly to `window.contentLayoutGuide` with `sizingOptions = []` so titlebar drags go straight to native `NSThemeFrame` and 1-second `CaptureWorker` state ticks never push frame mutations to `NSWindow`.
- `ActivationPolicyMatchesWindow`: `NSApp.setActivationPolicy(.regular)` is set before creating/ordering the window on screen and restored to `.accessory` in `windowWillClose`.
- `NoChromeMutationDuringDrag`, `NoCompetingSystemDragGesture`, `ZeroCumulativeDragDrift`, `PendingSyncFlushedWhenIdle`, `TitlebarReachableWhenOpenAndIdle`, and `DragStabilityProperty`: prove that with `window.isMovable = false` (`~systemDragGestureEnabled`), anchor-based global-coordinate titlebar dragging (`TitlebarDragSession` + `NSWindow.trackEvents` + `setFrameOrigin`, bypassing macOS 27.2's broken SkyLight client-initiated drag trait gesture) preserves `windowX = startOriginX + (mouseX - startMouseX)` at every drag step with zero horizontal snapping or cumulative drift, never mutates chrome during an active drag, never snaps on release or mid-drag focus loss (`ResignKeyMidDrag`) when straddling monitors, and recovers an unreachable/offscreen titlebar onto the nearest connected display's `visibleFrame` once idle or on reopen (`WindowPlacementGeometry.recoveredFrame`).
- `TitlebarHeightBounded`, `BrandAlwaysVisibleInTitlebar`, `NoBrandToolbarBubble`, `GlobalControlsAlwaysReachable`, `DoubleClickTitlebarBehavior`, `AtMostOneToolbarPopoverOpen`, `SidebarCompleteAndDisjoint`, `ActiveModeAlwaysIndicated`, and `NoDuplicateActiveModeHeading`: preserve the compact unified titlebar, native double-click Zoom/Minimize behavior, and sidebar layout invariants.

Physical multi-monitor mouse dragging on macOS WindowServer (including across external displays with Spaces/tiling) cannot be fully decided by finite state models or unit tests alone and remains a hands-on Mac check after CI passes.

### iOS 27 capture and hybrid macOS ↔ iOS CloudKit sync (#96)

- `spec/IOSCapture.tla` (`spec/IOSCapture.cfg`) models the isolated iOS 27 Shortcuts AppIntent ingestion pipeline (`ios/NotifdexiOS/Core/CaptureService.swift` + `NotificationStore.swift`) and verifies `AcknowledgedIsDurable`, `DurableNeverDisappears`, `SkipAndFailNeverWrite`, and `ToggleNeverFabricatesVerification`.
- `spec/HybridSync.tla` (`spec/HybridSync.cfg`) models opt-in pairing, one-tap revocation, filtered Mac → iOS projection (excluding hidden/muted alerts), monotonic LWW workflow sync, deletion tombstones, dirty-digest push skipping with transient push failure retry (`PushFail`), and macOS iPhone-forwarding outages (`SetMacForwarding`, `MacForwardingWarning`). It corresponds directly to `Sources/NotifdexCore/HybridSync.swift` and `CloudKitSyncTransport.swift`:
  - `HiddenNeverLeaksToCloudOrIPhone`: hidden or rule-filtered alerts on Mac never enter the CloudKit batch or reach iPhone.
  - `TombstoneBlocksResurrection` and `CloudStateMonotonic`: tombstoned deletions stay deleted across stale offline retries and workflow versions advance monotonically.
  - `DirtyFlagProtectsUnpushedData`: failed pushes never clear the dirty digest, preventing silent data drops on retry.
  - `LocalEvidenceNeverVanishes` and `UnpairedOrRevokedNeverSyncs`: local-only and revoked devices never push/pull cloud state and keep all local observations intact.
  - `ForwardingHealthSoundness`: `MacForwardingHealthAnalyzer` never false-alarms when unpaired or when macOS Accessibility captured the alert locally, and whenever it flags degradation, the Mac already holds the alert via iOS hybrid sync.
- `spec/AutoSync.tla` (`spec/AutoSync.cfg`) models the automatic bidirectional sync scheduler (`AutoSyncStateMachine` & `AutoSyncEngine` in `Sources/NotifdexCore/HybridSync.swift`), proving `SingleFlight`, `UnpairedNeverSchedules`, `DisabledAutoNeverArmsTimer`, `BackoffBounded`, and `MidSyncTriggerNotDropped` across burst triggers, mid-sync edits, transient failures, revocation, and re-pairing.
