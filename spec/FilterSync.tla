----------------------------- MODULE FilterSync -----------------------------
EXTENDS Naturals, FiniteSets

(*
  Formal model for Issue #111: deterministic multi-device synchronization of
  notification hide rules (app/title/body filters), tombstones (removals/undo),
  and shared vs. device-local user preferences across macOS and iOS.

  Models:
  - Offline local edits (create, disable, re-enable, remove/tombstone, re-create)
  - Concurrent conflicting edits on Mac and iPhone at the same or different logical times
  - Duplicate / out-of-order batch delivery & transient push failures
  - Conservative tie-breaking: on equal timestamps, enabled/active hide state wins over
    disabled so previously hidden notifications are never unexpectedly revealed, and a
    tombstone with deletedAt >= updatedAt suppresses stale offline re-adds while a
    strictly newer re-create (updatedAt > deletedAt) supersedes an older tombstone.
  - Strict isolation of device-local preferences from remote sync.
*)

CONSTANTS Mac, IPhone, MaxTime

Devices == {Mac, IPhone}
RuleStates == {"absent", "enabled", "disabled"}
LocalPrefValues == {0, 1}
SharedPrefValues == {0, 1}

VARIABLES
    clock,              \* Global monotonic logical clock (0..MaxTime)
    \* Per-device rule state for a canonical hide rule key (app, field, value)
    ruleState,          \* [Devices -> RuleStates]
    ruleUpdatedAt,      \* [Devices -> 0..MaxTime]
    tombstoneAt,        \* [Devices -> 0..MaxTime] (0 means no tombstone)
    \* Shared synced preference (e.g. color pigment / groupByApp)
    sharedPref,         \* [Devices -> SharedPrefValues]
    sharedPrefAt,       \* [Devices -> 0..MaxTime]
    \* Device-local preference (e.g. macOS glass surface / window geometry / pause state)
    localPref,          \* [Devices -> LocalPrefValues]
    \* CloudKit zone retains pushed snapshots (models out-of-order / duplicate / stale pulls)
    cloudBatches,       \* Set of snapshot records pushed to CloudKit
    \* Track which device last changed localPref to assert remote sync never touches it
    lastOp

vars == <<clock, ruleState, ruleUpdatedAt, tombstoneAt,
          sharedPref, sharedPrefAt, localPref, cloudBatches, lastOp>>

\* Deterministic merge of a single canonical rule + tombstone snapshot into local state.
\* Implements the exact semantics of CaptureStore.applySyncBatch:
\* 1. Merge tombstone timestamp: newTomb = max(localTomb, remoteTomb)
\* 2. Evaluate candidate active rule (local vs remote) using LWW on updatedAt,
\*    with conservative tie-break ("enabled" beats "disabled") on equal updatedAt.
\* 3. If newTomb >= bestUpdatedAt (and newTomb > 0), deletion dominates -> "absent".
\*    Otherwise, the surviving active rule wins (re-create after delete supersedes older tombstone).
Max(a, b) == IF a >= b THEN a ELSE b

MergeRule(lState, lTime, lTomb, rState, rTime, rTomb) ==
    LET newTomb == Max(lTomb, rTomb)
        localAlive == (lState # "absent") /\ (lTime > newTomb)
        remoteAlive == (rState # "absent") /\ (rTime > newTomb)
    IN IF ~localAlive /\ ~remoteAlive THEN
           [state |-> "absent", updatedAt |-> Max(lTime, rTime), tombAt |-> newTomb]
       ELSE IF localAlive /\ ~remoteAlive THEN
           [state |-> lState, updatedAt |-> lTime, tombAt |-> newTomb]
       ELSE IF ~localAlive /\ remoteAlive THEN
           [state |-> rState, updatedAt |-> rTime, tombAt |-> newTomb]
       ELSE \* Both alive and strictly newer than newTomb
           IF rTime > lTime THEN
               [state |-> rState, updatedAt |-> rTime, tombAt |-> newTomb]
           ELSE IF lTime > rTime THEN
               [state |-> lState, updatedAt |-> lTime, tombAt |-> newTomb]
           ELSE \* Equal timestamp: conservative hide-wins ("enabled" beats "disabled")
               [state |-> IF lState = "enabled" \/ rState = "enabled" THEN "enabled" ELSE "disabled",
                updatedAt |-> lTime,
                tombAt |-> newTomb]

MergeSharedPref(lVal, lTime, rVal, rTime) ==
    IF rTime > lTime THEN
        [val |-> rVal, time |-> rTime]
    ELSE IF lTime > rTime THEN
        [val |-> lVal, time |-> lTime]
    ELSE
        \* Deterministic tie-break on equal timestamp: max value (canonical ordering)
        [val |-> Max(lVal, rVal), time |-> lTime]

SnapshotOf(d) ==
    [sender |-> d,
     state |-> ruleState[d],
     updatedAt |-> ruleUpdatedAt[d],
     tombAt |-> tombstoneAt[d],
     prefVal |-> sharedPref[d],
     prefAt |-> sharedPrefAt[d]]

Init ==
    /\ clock = 0
    /\ ruleState = [d \in Devices |-> "absent"]
    /\ ruleUpdatedAt = [d \in Devices |-> 0]
    /\ tombstoneAt = [d \in Devices |-> 0]
    /\ sharedPref = [d \in Devices |-> 0]
    /\ sharedPrefAt = [d \in Devices |-> 0]
    /\ localPref = [d \in Devices |-> IF d = Mac THEN 0 ELSE 1]
    /\ cloudBatches = {}
    /\ lastOp = "init"

\* User creates or re-creates (undoes removal of) a hide rule on device d at strictly newer time.
LocalAddRule(d) ==
    /\ d \in Devices
    /\ clock < MaxTime
    /\ LET t == clock + 1
       IN /\ clock' = t
          /\ ruleState' = [ruleState EXCEPT ![d] = "enabled"]
          /\ ruleUpdatedAt' = [ruleUpdatedAt EXCEPT ![d] = t]
          /\ lastOp' = "local_edit"
          /\ UNCHANGED <<tombstoneAt, sharedPref, sharedPrefAt, localPref, cloudBatches>>

\* User disables an existing hide rule on device d.
LocalDisableRule(d) ==
    /\ d \in Devices
    /\ ruleState[d] = "enabled"
    /\ clock < MaxTime
    /\ LET t == clock + 1
       IN /\ clock' = t
          /\ ruleState' = [ruleState EXCEPT ![d] = "disabled"]
          /\ ruleUpdatedAt' = [ruleUpdatedAt EXCEPT ![d] = t]
          /\ lastOp' = "local_edit"
          /\ UNCHANGED <<tombstoneAt, sharedPref, sharedPrefAt, localPref, cloudBatches>>

\* User removes (deletes) a hide rule on device d, recording a timestamped tombstone.
LocalRemoveRule(d) ==
    /\ d \in Devices
    /\ ruleState[d] # "absent"
    /\ clock < MaxTime
    /\ LET t == clock + 1
       IN /\ clock' = t
          /\ ruleState' = [ruleState EXCEPT ![d] = "absent"]
          /\ tombstoneAt' = [tombstoneAt EXCEPT ![d] = Max(@, t)]
          /\ lastOp' = "local_edit"
          /\ UNCHANGED <<ruleUpdatedAt, sharedPref, sharedPrefAt, localPref, cloudBatches>>

\* Concurrent equal-timestamp edits: both devices edit offline at the same wall-clock second.
ConcurrentConflictingRuleEdit ==
    /\ clock < MaxTime
    /\ LET t == clock + 1
       IN /\ clock' = t
          /\ ruleState' = [d \in Devices |-> IF d = Mac THEN "enabled" ELSE "disabled"]
          /\ ruleUpdatedAt' = [d \in Devices |-> t]
          /\ lastOp' = "local_edit"
          /\ UNCHANGED <<tombstoneAt, sharedPref, sharedPrefAt, localPref, cloudBatches>>

\* User changes a shared preference on device d.
LocalSetSharedPref(d, val) ==
    /\ d \in Devices
    /\ val \in SharedPrefValues
    /\ sharedPref[d] # val
    /\ clock < MaxTime
    /\ LET t == clock + 1
       IN /\ clock' = t
          /\ sharedPref' = [sharedPref EXCEPT ![d] = val]
          /\ sharedPrefAt' = [sharedPrefAt EXCEPT ![d] = t]
          /\ lastOp' = "local_edit"
          /\ UNCHANGED <<ruleState, ruleUpdatedAt, tombstoneAt, localPref, cloudBatches>>

\* User changes a device-local preference on device d (must never be overwritten by sync).
LocalSetDevicePref(d, val) ==
    /\ d \in Devices
    /\ val \in LocalPrefValues
    /\ localPref[d] # val
    /\ localPref' = [localPref EXCEPT ![d] = val]
    /\ lastOp' = "local_device_pref"
    /\ UNCHANGED <<clock, ruleState, ruleUpdatedAt, tombstoneAt, sharedPref, sharedPrefAt, cloudBatches>>

\* Paired device pushes its current snapshot to CloudKit (idempotent if already present).
PushSnapshot(d) ==
    /\ d \in Devices
    /\ cloudBatches' = cloudBatches \cup {SnapshotOf(d)}
    /\ lastOp' = "sync_push"
    /\ UNCHANGED <<clock, ruleState, ruleUpdatedAt, tombstoneAt, sharedPref, sharedPrefAt, localPref>>

\* Paired device pulls ANY snapshot from CloudKit (models retries, duplicate delivery,
\* and out-of-order stale batch delivery).
PullBatch(d, batch) ==
    /\ d \in Devices
    /\ batch \in cloudBatches
    /\ batch.sender # d
    /\ LET mergedRule == MergeRule(
               ruleState[d], ruleUpdatedAt[d], tombstoneAt[d],
               batch.state, batch.updatedAt, batch.tombAt)
           mergedPref == MergeSharedPref(
               sharedPref[d], sharedPrefAt[d],
               batch.prefVal, batch.prefAt)
       IN /\ ruleState' = [ruleState EXCEPT ![d] = mergedRule.state]
          /\ ruleUpdatedAt' = [ruleUpdatedAt EXCEPT ![d] = mergedRule.updatedAt]
          /\ tombstoneAt' = [tombstoneAt EXCEPT ![d] = mergedRule.tombAt]
          /\ sharedPref' = [sharedPref EXCEPT ![d] = mergedPref.val]
          /\ sharedPrefAt' = [sharedPrefAt EXCEPT ![d] = mergedPref.time]
          /\ lastOp' = "sync_pull"
          /\ UNCHANGED <<clock, localPref, cloudBatches>>

Next ==
    \/ \E d \in Devices : LocalAddRule(d)
    \/ \E d \in Devices : LocalDisableRule(d)
    \/ \E d \in Devices : LocalRemoveRule(d)
    \/ ConcurrentConflictingRuleEdit
    \/ \E d \in Devices, v \in SharedPrefValues : LocalSetSharedPref(d, v)
    \/ \E d \in Devices, v \in LocalPrefValues : LocalSetDevicePref(d, v)
    \/ \E d \in Devices : PushSnapshot(d)
    \/ \E d \in Devices, b \in cloudBatches : PullBatch(d, b)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ clock \in 0..MaxTime
    /\ ruleState \in [Devices -> RuleStates]
    /\ ruleUpdatedAt \in [Devices -> 0..MaxTime]
    /\ tombstoneAt \in [Devices -> 0..MaxTime]
    /\ sharedPref \in [Devices -> SharedPrefValues]
    /\ sharedPrefAt \in [Devices -> 0..MaxTime]
    /\ localPref \in [Devices -> LocalPrefValues]

\* Active rule must always have an updatedAt strictly greater than its tombstone timestamp.
DeleteSuppressesStaleRule ==
    \A d \in Devices :
        (tombstoneAt[d] > 0 /\ ruleUpdatedAt[d] <= tombstoneAt[d])
            => (ruleState[d] = "absent")

\* Tombstones and timestamps are monotonic per device: pulling stale/duplicate batches
\* can never roll back a device's tombstone or shared preference timestamp.
SyncMetadataMonotonic == [][
    \A d \in Devices :
        /\ tombstoneAt'[d] >= tombstoneAt[d]
        /\ sharedPrefAt'[d] >= sharedPrefAt[d]
        /\ ruleUpdatedAt'[d] >= ruleUpdatedAt[d]
    ]_vars

\* Stale remote pull never reverts an active rule to an older version or resurrects
\* a rule whose timestamp is <= the local tombstone.
StaleRemoteNeverOverwritesNewer == [][
    (lastOp' = "sync_pull") =>
        \A d \in Devices :
            /\ (ruleState[d] # "absent" /\ tombstoneAt'[d] < ruleUpdatedAt[d])
                => (ruleUpdatedAt'[d] >= ruleUpdatedAt[d])
            /\ (ruleState[d] = "enabled" /\ ruleUpdatedAt'[d] = ruleUpdatedAt[d] /\ tombstoneAt'[d] < ruleUpdatedAt[d])
                => (ruleState'[d] = "enabled")
    ]_vars

\* Sync push/pull never modifies device-local preferences.
DeviceLocalPrefsUntouchedBySync == [][
    (lastOp' \in {"sync_push", "sync_pull"}) => (localPref' = localPref)
    ]_vars

\* Commutativity / convergence check: merging Mac's snapshot into iPhone and iPhone's
\* snapshot into Mac always yields the exact same rule state and shared preference!
MergeIsCommutativeAndConvergent ==
    LET mIntoI == MergeRule(
            ruleState[IPhone], ruleUpdatedAt[IPhone], tombstoneAt[IPhone],
            ruleState[Mac], ruleUpdatedAt[Mac], tombstoneAt[Mac])
        iIntoM == MergeRule(
            ruleState[Mac], ruleUpdatedAt[Mac], tombstoneAt[Mac],
            ruleState[IPhone], ruleUpdatedAt[IPhone], tombstoneAt[IPhone])
        pMIntoI == MergeSharedPref(sharedPref[IPhone], sharedPrefAt[IPhone], sharedPref[Mac], sharedPrefAt[Mac])
        pIIntoM == MergeSharedPref(sharedPref[Mac], sharedPrefAt[Mac], sharedPref[IPhone], sharedPrefAt[IPhone])
    IN /\ mIntoI = iIntoM
       /\ pMIntoI = pIIntoM
=============================================================================
