----------------------------- MODULE Capture -----------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Events
VARIABLES visible, pending, stored, acknowledged, running, accessible,
          gap, resumeNeeded

vars == <<visible, pending, stored, acknowledged, running, accessible,
          gap, resumeNeeded>>

Init == /\ visible = {} /\ pending = {} /\ stored = {}
        /\ acknowledged = {} /\ running = TRUE /\ accessible = TRUE
        /\ gap = TRUE /\ resumeNeeded = TRUE

Show(e) == /\ visible' = visible \cup {e}
           /\ UNCHANGED <<pending, stored, acknowledged, running, accessible,
                          gap, resumeNeeded>>
Hide(e) == /\ visible' = visible \ {e}
           /\ UNCHANGED <<pending, stored, acknowledged, running, accessible,
                          gap, resumeNeeded>>

Scan == /\ running /\ accessible
        /\ pending' = pending \cup visible
        /\ resumeNeeded' = FALSE /\ gap' = FALSE
        /\ UNCHANGED <<visible, stored, acknowledged, running, accessible>>

Commit(e) == /\ running /\ accessible /\ e \in pending
             /\ stored' = stored \cup {e}
             /\ acknowledged' = acknowledged \cup {e}
             /\ pending' = pending \ {e}
             /\ UNCHANGED <<visible, running, accessible, gap, resumeNeeded>>

CommitBatch == \E batch \in SUBSET pending :
    /\ running /\ accessible /\ batch # {}
    /\ stored' = stored \cup batch
    /\ acknowledged' = acknowledged \cup batch
    /\ pending' = pending \ batch
    /\ UNCHANGED <<visible, running, accessible, gap, resumeNeeded>>

Crash == /\ running /\ running' = FALSE /\ pending' = {}
         /\ gap' = TRUE /\ resumeNeeded' = TRUE
         /\ UNCHANGED <<visible, stored, acknowledged, accessible>>
Restart == /\ ~running /\ running' = TRUE /\ gap' = TRUE
           /\ resumeNeeded' = TRUE
           /\ UNCHANGED <<visible, pending, stored, acknowledged, accessible>>
Suspend == /\ accessible /\ accessible' = FALSE /\ gap' = TRUE
           /\ resumeNeeded' = TRUE
           /\ UNCHANGED <<visible, pending, stored, acknowledged, running>>
Restore == /\ ~accessible /\ accessible' = TRUE /\ gap' = TRUE
           /\ resumeNeeded' = TRUE
           /\ UNCHANGED <<visible, pending, stored, acknowledged, running>>

Next == \/ \E e \in Events : Show(e) \/ Hide(e) \/ Commit(e)
        \/ Scan \/ CommitBatch \/ Crash \/ Restart \/ Suspend \/ Restore
Spec == Init /\ [][Next]_vars

TypeOK == /\ visible \subseteq Events /\ pending \subseteq Events
          /\ stored \subseteq Events /\ acknowledged \subseteq Events
          /\ running \in BOOLEAN /\ accessible \in BOOLEAN
          /\ gap \in BOOLEAN /\ resumeNeeded \in BOOLEAN
AcknowledgedIsDurable == acknowledged \subseteq stored
UnavailableIsMarked == (~running \/ ~accessible \/ resumeNeeded) => gap
DurableNeverDisappears == [][stored \subseteq stored']_vars

\* Conditional progress only. Environment failures can otherwise occur forever.
StableNext == Scan \/ CommitBatch \/ (\E e \in Events : Commit(e))
StableSpec == Init /\ [][StableNext]_vars
              /\ WF_vars(Scan)
              /\ (\A e \in Events : WF_vars(Commit(e)))
StableInit == /\ visible = Events /\ pending = {} /\ stored = {}
              /\ acknowledged = {} /\ running = TRUE /\ accessible = TRUE
              /\ gap = TRUE /\ resumeNeeded = TRUE
ProgressSpec == StableInit /\ [][StableNext]_vars
                /\ WF_vars(Scan)
                /\ (\A e \in Events : WF_vars(Commit(e)))
VisibleEventuallyStored == <> (stored = Events)

\* Retained history overlaps an earlier durable capture after a restart.
RecoveryInit == /\ visible = Events /\ pending = {}
                /\ stored = {CHOOSE e \in Events : TRUE}
                /\ acknowledged = stored
                /\ running = TRUE /\ accessible = TRUE
                /\ gap = TRUE /\ resumeNeeded = TRUE
RecoverySpec == RecoveryInit /\ [][StableNext]_vars
                /\ WF_vars(Scan)
                /\ (\A e \in Events : WF_vars(Commit(e)))
=============================================================================
