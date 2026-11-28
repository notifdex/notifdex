---------------------------- MODULE StorageCleanup ----------------------------
EXTENDS Naturals, FiniteSets

(*
  Formal model for Issue #110: safe database storage cleanup & SQLite maintenance
  across macOS and iOS.

  Models:
  - Observations categorized by age ("old", "recent") and protection status
    ("normal", "protected" = saved, flagged, active follow-up, person-linked, or workspace-routed)
  - User-created data ("people", "notes", "workspaces", "rules") that must NEVER be deleted
  - Atomic transactional deletion with possible mid-cleanup crash/interruption rollback
  - Post-commit WAL checkpoint + VACUUM maintenance + integrity verification
  - Device-local `prunedOld` watermark preventing paired CloudKit sync from resurrecting
    cleaned-up historical observations on this device without deleting the peer's history
*)

CONSTANTS OldNormal, OldProtected, RecentNormal, RecentProtected

AllObservations == {OldNormal, OldProtected, RecentNormal, RecentProtected}
OldObservations == {OldNormal, OldProtected}
ProtectedObservations == {OldProtected, RecentProtected}
UserDataSet == {"people", "notes", "workspaces", "rules"}
Phases == {"idle", "deleting_age", "deleting_all", "vacuuming"}

VARIABLES
    observations,       \* Committed set of observations in SQLite
    pendingDelete,      \* Uncommitted staging set during an active transaction
    userData,           \* Committed user-created data (people, notes, workspaces, rules)
    phase,              \* Cleanup execution phase
    walPending,         \* TRUE when deleted pages/WAL space awaits checkpoint + VACUUM
    prunedOld,          \* Device-local retention watermark (old alerts pruned locally)
    prunedAll,          \* Device-local clear-all watermark
    integrityOK,        \* SQLite PRAGMA integrity_check status
    usedClearAll        \* Tracks whether user explicitly confirmed Clear All History

vars == <<observations, pendingDelete, userData, phase, walPending,
          prunedOld, prunedAll, integrityOK, usedClearAll>>

Init ==
    /\ observations = AllObservations
    /\ pendingDelete = {}
    /\ userData = UserDataSet
    /\ phase = "idle"
    /\ walPending = FALSE
    /\ prunedOld = FALSE
    /\ prunedAll = FALSE
    /\ integrityOK = TRUE
    /\ usedClearAll = FALSE

\* User initiates age-based retention cleanup (e.g. Older than 30/90/180/365 days),
\* which targets ONLY old, non-protected observations inside an atomic transaction.
BeginAgeCleanup ==
    /\ phase = "idle"
    /\ LET targets == {o \in observations : o \in OldObservations /\ o \notin ProtectedObservations}
       IN /\ targets # {}
          /\ pendingDelete' = targets
          /\ phase' = "deleting_age"
    /\ UNCHANGED <<observations, userData, walPending, prunedOld, prunedAll, integrityOK, usedClearAll>>

\* User explicitly confirms "Clear All Notification History", targeting all observations
\* while leaving all user-created data (people, notes, workspaces, rules) untouched.
BeginClearAll ==
    /\ phase = "idle"
    /\ observations # {}
    /\ pendingDelete' = observations
    /\ phase' = "deleting_all"
    /\ UNCHANGED <<observations, userData, walPending, prunedOld, prunedAll, integrityOK, usedClearAll>>

\* Atomic COMMIT of the active deletion transaction.
CommitDelete ==
    /\ phase \in {"deleting_age", "deleting_all"}
    /\ observations' = observations \ pendingDelete
    /\ pendingDelete' = {}
    /\ walPending' = TRUE
    /\ prunedOld' = TRUE
    /\ prunedAll' = IF phase = "deleting_all" THEN TRUE ELSE prunedAll
    /\ usedClearAll' = IF phase = "deleting_all" THEN TRUE ELSE usedClearAll
    /\ phase' = "vacuuming"
    /\ UNCHANGED <<userData, integrityOK>>

\* Crash or interruption before COMMIT rolls back atomically; committed state & integrity stay intact.
CrashDuringDelete ==
    /\ phase \in {"deleting_age", "deleting_all"}
    /\ pendingDelete' = {}
    /\ phase' = "idle"
    /\ UNCHANGED <<observations, userData, walPending, prunedOld, prunedAll, integrityOK, usedClearAll>>

\* Post-commit SQLite maintenance: WAL checkpoint (TRUNCATE) + VACUUM + integrity check.
CompleteMaintenance ==
    /\ phase = "vacuuming"
    /\ walPending' = FALSE
    /\ phase' = "idle"
    /\ UNCHANGED <<observations, pendingDelete, userData, prunedOld, prunedAll, integrityOK, usedClearAll>>

\* Crash or SQLITE_BUSY during VACUUM leaves committed deletions intact and DB integral;
\* walPending remains TRUE until a subsequent compaction succeeds.
InterruptMaintenance ==
    /\ phase = "vacuuming"
    /\ phase' = "idle"
    /\ UNCHANGED <<observations, pendingDelete, userData, walPending, prunedOld, prunedAll, integrityOK, usedClearAll>>

\* Manual compaction ("Compact Database") reclaims pending WAL/freelist space without deleting data.
RunStandaloneCompaction ==
    /\ phase = "idle"
    /\ walPending = TRUE
    /\ walPending' = FALSE
    /\ UNCHANGED <<observations, pendingDelete, userData, phase, prunedOld, prunedAll, integrityOK, usedClearAll>>

\* Paired CloudKit sync pulls remote alerts from another device:
\* - Old alerts are filtered out when `prunedOld` is TRUE.
\* - Alerts older than clear-all cutoff are filtered out when `prunedAll` is TRUE.
\* - Fresh alerts arriving after cleanup can still be captured normally (modeled when ~prunedAll).
RemoteSyncPull(o) ==
    /\ phase = "idle"
    /\ o \in {OldNormal, RecentNormal}
    /\ o \notin observations
    /\ ~(prunedOld /\ o \in OldObservations)
    /\ ~prunedAll
    /\ observations' = observations \cup {o}
    /\ UNCHANGED <<pendingDelete, userData, phase, walPending, prunedOld, prunedAll, integrityOK, usedClearAll>>

\* Read-only storage usage refresh is always available while idle (prevents artificial terminal deadlock).
RefreshStorageUsage ==
    /\ phase = "idle"
    /\ UNCHANGED vars

Next ==
    \/ BeginAgeCleanup
    \/ BeginClearAll
    \/ CommitDelete
    \/ CrashDuringDelete
    \/ CompleteMaintenance
    \/ InterruptMaintenance
    \/ RunStandaloneCompaction
    \/ \E o \in {OldNormal, RecentNormal} : RemoteSyncPull(o)
    \/ RefreshStorageUsage

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ observations \subseteq AllObservations
    /\ pendingDelete \subseteq AllObservations
    /\ userData \subseteq UserDataSet
    /\ phase \in Phases
    /\ walPending \in BOOLEAN
    /\ prunedOld \in BOOLEAN
    /\ prunedAll \in BOOLEAN
    /\ integrityOK \in BOOLEAN
    /\ usedClearAll \in BOOLEAN

\* People, notes, workspaces, and hide rules are NEVER deleted by notification cleanup.
UserDataAlwaysPreserved ==
    userData = UserDataSet

\* Standard age-based cleanup NEVER removes protected (saved/flagged/follow-up/person-linked) alerts.
ProtectedAlertsPreservedByAgeCleanup ==
    (~usedClearAll) => (ProtectedObservations \subseteq observations)

\* Database integrity always holds across deletes, crashes, and VACUUM interruptions.
IntegrityAlwaysOK ==
    integrityOK = TRUE

\* Once old alerts have been pruned locally, remote CloudKit sync never resurrects them.
PrunedOldNeverResurrected ==
    prunedOld => (OldNormal \notin observations)

\* Crash during uncommitted delete leaves committed observations unchanged.
UncommittedDeleteNeverMutatesObservations == [][
    (phase \in {"deleting_age", "deleting_all"} /\ phase' = "idle") => (observations' = observations)
    ]_vars

\* Device-local prune watermarks are monotonic.
PruneWatermarksMonotonic == [][
    /\ (prunedOld => prunedOld')
    /\ (prunedAll => prunedAll')
    ]_vars
=============================================================================
