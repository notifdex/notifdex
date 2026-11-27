------------------------------ MODULE AutoSync ------------------------------
EXTENDS Naturals

CONSTANTS MaxFailures

SyncStates == {"idle", "debouncing", "running", "backoff"}

VARIABLES paired, autoEnabled, syncState, pendingTrigger, failureStreak, inFlight

vars == <<paired, autoEnabled, syncState, pendingTrigger, failureStreak, inFlight>>

Init ==
    /\ paired = FALSE
    /\ autoEnabled = TRUE
    /\ syncState = "idle"
    /\ pendingTrigger = FALSE
    /\ failureStreak = 0
    /\ inFlight = 0

\* User opts in to iCloud sync pairing.
\* If a prior run is still unwinding in flight, stay in "running" (SingleFlight) and queue a follow-up.
Pair ==
    /\ ~paired
    /\ paired' = TRUE
    /\ IF syncState = "running"
       THEN /\ syncState' = "running"
            /\ pendingTrigger' = autoEnabled
       ELSE /\ syncState' = IF autoEnabled THEN "debouncing" ELSE "idle"
            /\ UNCHANGED pendingTrigger
    /\ UNCHANGED <<autoEnabled, failureStreak, inFlight>>

\* One-tap revocation immediately cancels scheduled work and blocks future auto-syncs.
\* If a run is already in flight, it will not schedule any follow-up on completion.
Revoke ==
    /\ paired
    /\ paired' = FALSE
    /\ pendingTrigger' = FALSE
    /\ failureStreak' = 0
    /\ syncState' = IF syncState = "running" THEN "running" ELSE "idle"
    /\ UNCHANGED <<autoEnabled, inFlight>>

\* User toggles automatic background/foreground sync on or off while staying paired.
SetAutoEnabled(flag) ==
    /\ flag \in BOOLEAN
    /\ flag # autoEnabled
    /\ autoEnabled' = flag
    /\ IF ~flag /\ syncState \in {"debouncing", "backoff"}
       THEN /\ syncState' = "idle"
            /\ pendingTrigger' = FALSE
       ELSE IF flag /\ paired /\ syncState = "idle"
            THEN /\ syncState' = "debouncing"
                 /\ pendingTrigger' = pendingTrigger
            ELSE UNCHANGED <<syncState, pendingTrigger>>
    /\ UNCHANGED <<paired, failureStreak, inFlight>>

\* Automatic trigger (local capture, local workflow edit, foreground, periodic tick, or remote push).
AutoTrigger ==
    /\ paired
    /\ autoEnabled
    /\ IF syncState = "idle"
       THEN /\ syncState' = "debouncing"
            /\ UNCHANGED pendingTrigger
       ELSE IF syncState = "running"
            THEN /\ pendingTrigger' = TRUE
                 /\ UNCHANGED syncState
            ELSE IF syncState = "backoff"
                 THEN /\ pendingTrigger' = TRUE
                      /\ UNCHANGED syncState
                 ELSE UNCHANGED <<syncState, pendingTrigger>>
    /\ UNCHANGED <<paired, autoEnabled, failureStreak, inFlight>>

\* Explicit manual "Sync Now" tap bypasses debounce/backoff while preserving single-flight.
ManualTrigger ==
    /\ paired
    /\ IF syncState = "running"
       THEN /\ pendingTrigger' = TRUE
            /\ UNCHANGED <<syncState, inFlight>>
       ELSE /\ syncState' = "running"
            /\ inFlight' = 1
            /\ pendingTrigger' = FALSE
    /\ UNCHANGED <<paired, autoEnabled, failureStreak>>

\* Debounce or backoff timer fires and launches the single in-flight sync run.
StartScheduledRun ==
    /\ paired
    /\ autoEnabled
    /\ syncState \in {"debouncing", "backoff"}
    /\ syncState' = "running"
    /\ inFlight' = 1
    /\ pendingTrigger' = FALSE
    /\ UNCHANGED <<paired, autoEnabled, failureStreak>>

\* In-flight sync succeeds: clear failure streak; coalesce any mid-sync trigger into a follow-up debounce.
FinishSuccess ==
    /\ syncState = "running"
    /\ inFlight' = 0
    /\ failureStreak' = 0
    /\ IF paired /\ autoEnabled /\ pendingTrigger
       THEN /\ syncState' = "debouncing"
            /\ pendingTrigger' = FALSE
       ELSE /\ syncState' = "idle"
            /\ pendingTrigger' = FALSE
    /\ UNCHANGED <<paired, autoEnabled>>

\* In-flight sync fails transiently (offline, iCloud unavailable, rate-limited): enter bounded backoff.
FinishFailure ==
    /\ syncState = "running"
    /\ inFlight' = 0
    /\ IF paired /\ autoEnabled
       THEN /\ failureStreak' = IF failureStreak < MaxFailures THEN failureStreak + 1 ELSE MaxFailures
            /\ syncState' = "backoff"
            /\ pendingTrigger' = TRUE
       ELSE /\ failureStreak' = 0
            /\ syncState' = "idle"
            /\ pendingTrigger' = FALSE
    /\ UNCHANGED <<paired, autoEnabled>>

Next ==
    \/ Pair
    \/ Revoke
    \/ \E b \in BOOLEAN : SetAutoEnabled(b)
    \/ AutoTrigger
    \/ ManualTrigger
    \/ StartScheduledRun
    \/ FinishSuccess
    \/ FinishFailure

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ paired \in BOOLEAN
    /\ autoEnabled \in BOOLEAN
    /\ syncState \in SyncStates
    /\ pendingTrigger \in BOOLEAN
    /\ failureStreak \in 0..MaxFailures
    /\ inFlight \in 0..1

\* At most one sync execution may be in flight at any instant.
SingleFlight ==
    /\ inFlight <= 1
    /\ (syncState = "running") <=> (inFlight = 1)

\* Unpaired or revoked devices never hold scheduled debounce/backoff timers or pending follow-ups.
UnpairedNeverSchedules ==
    ~paired => (syncState \in {"idle", "running"} /\ ~pendingTrigger /\ failureStreak = 0)

\* Disabling automatic sync never leaves debounce or backoff timers armed.
DisabledAutoNeverArmsTimer ==
    ~autoEnabled => (syncState \in {"idle", "running"})

\* Backoff state always corresponds to a positive, bounded failure streak.
BackoffBounded ==
    /\ failureStreak <= MaxFailures
    /\ (syncState = "backoff") => (failureStreak > 0 /\ paired /\ autoEnabled)

\* A mid-sync trigger while paired and auto-enabled is never dropped silently on success.
MidSyncTriggerNotDropped == [][
    (syncState = "running" /\ paired /\ autoEnabled /\ pendingTrigger /\ syncState' # "running")
        => (syncState' \in {"debouncing", "backoff"})
    ]_vars
=============================================================================
