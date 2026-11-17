-------------------------- MODULE AppRecovery --------------------------
EXTENDS Naturals
CONSTANTS Apps, MaxSteps
VARIABLES selected, snapshot, lastWrite, active, paused, steps, action
vars == <<selected, snapshot, lastWrite, active, paused, steps, action>>
Init == /\ selected = {} /\ snapshot = {} /\ lastWrite = {}
        /\ active = FALSE /\ paused = FALSE /\ steps = 0 /\ action = "none"
Configure == \E apps \in SUBSET Apps :
    /\ selected' = apps /\ lastWrite' = {} /\ active' = FALSE
    /\ action' = "none" /\ UNCHANGED <<snapshot, paused, steps>>
Observe == \E apps \in SUBSET Apps :
    /\ snapshot' = apps
    /\ UNCHANGED <<selected, lastWrite, active, paused, steps, action>>
Persist == /\ ~paused /\ lastWrite' = snapshot \cap selected
           /\ UNCHANGED <<selected, snapshot, active, paused, steps, action>>
Pause == /\ paused' = ~paused /\ active' = FALSE /\ action' = "none"
         /\ lastWrite' = {} /\ UNCHANGED <<selected, snapshot, steps>>
Start == /\ ~active /\ ~paused /\ selected # {}
         /\ active' = TRUE /\ steps' = 0 /\ action' = "clock"
         /\ UNCHANGED <<selected, snapshot, lastWrite, paused>>
Step == /\ active /\ steps < MaxSteps
        /\ steps' = steps + 1 /\ action' \in {"expand-stack", "scroll"}
        /\ active' = (steps' < MaxSteps)
        /\ UNCHANGED <<selected, snapshot, lastWrite, paused>>
Stop == /\ active /\ active' = FALSE /\ action' = "none"
        /\ UNCHANGED <<selected, snapshot, lastWrite, paused, steps>>
Next == Configure \/ Observe \/ Persist \/ Pause \/ Start \/ Step \/ Stop
Spec == Init /\ [][Next]_vars /\ WF_vars(Step)
TypeOK == /\ selected \subseteq Apps /\ snapshot \subseteq Apps
          /\ lastWrite \subseteq Apps /\ active \in BOOLEAN /\ paused \in BOOLEAN
          /\ steps \in 0..MaxSteps
OnlyEnabledPersist == lastWrite \subseteq selected
PausedStopsRecovery == paused => ~active
PausedStopsWrites == paused => lastWrite = {}
RecoveryNeedsSelection == active => selected # {}
OnlyNavigationActions == action \in {"none", "clock", "expand-stack", "scroll"}
RecoveryTerminates == active ~> ~active
=============================================================================
