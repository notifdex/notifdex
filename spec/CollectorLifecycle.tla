------------------------- MODULE CollectorLifecycle -------------------------
EXTENDS Naturals
CONSTANTS Collectors, NoOwner, MaxSteps, MaxUnchanged, MaxWakeRetries

GapReasons == {"collector_stopped", "unavailable", "partial_scan", "recovery_navigation"}

VARIABLES lockOwner, openGaps, permission, paused, sleeping, screenLocked,
          selectedNonEmpty, pendingRecovery, wakeRetries,
          recovering, recoveryFailed, panelOpen, steps, unchanged

vars == <<lockOwner, openGaps, permission, paused, sleeping, screenLocked,
          selectedNonEmpty, pendingRecovery, wakeRetries,
          recovering, recoveryFailed, panelOpen, steps, unchanged>>

CanCollect ==
    /\ lockOwner # NoOwner
    /\ permission
    /\ ~paused
    /\ ~sleeping
    /\ selectedNonEmpty

CanRecover ==
    /\ CanCollect
    /\ ~screenLocked

Init ==
    /\ lockOwner = NoOwner
    /\ openGaps = {}
    /\ permission = FALSE
    /\ paused = FALSE
    /\ sleeping = FALSE
    /\ screenLocked = FALSE
    /\ selectedNonEmpty = TRUE
    /\ pendingRecovery = FALSE
    /\ wakeRetries = 0
    /\ recovering = FALSE
    /\ recoveryFailed = FALSE
    /\ panelOpen = FALSE
    /\ steps = 0
    /\ unchanged = 0

AcquireLock(c) ==
    /\ lockOwner = NoOwner
    /\ lockOwner' = c
    /\ openGaps' = openGaps \cup {"collector_stopped"}
    /\ recoveryFailed' = FALSE
    /\ wakeRetries' = 0
    /\ UNCHANGED <<permission, paused, sleeping, screenLocked, selectedNonEmpty,
                   pendingRecovery, recovering, panelOpen, steps, unchanged>>

ReleaseLock(c) ==
    /\ lockOwner = c
    /\ lockOwner' = NoOwner
    /\ recovering' = FALSE
    /\ panelOpen' = FALSE
    /\ steps' = 0
    /\ unchanged' = 0
    /\ pendingRecovery' = FALSE
    /\ wakeRetries' = 0
    /\ UNCHANGED <<openGaps, permission, paused, sleeping, screenLocked,
                   selectedNonEmpty, recoveryFailed>>

SetPermission(b) ==
    /\ b # permission
    /\ permission' = b
    /\ IF ~b
       THEN /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ steps' = 0
            /\ unchanged' = 0
            /\ openGaps' = IF lockOwner # NoOwner THEN openGaps \cup {"unavailable"} ELSE openGaps
       ELSE UNCHANGED <<openGaps, recovering, panelOpen, steps, unchanged>>
    /\ UNCHANGED <<lockOwner, paused, sleeping, screenLocked, selectedNonEmpty,
                   pendingRecovery, wakeRetries, recoveryFailed>>

SetPaused(b) ==
    /\ b # paused
    /\ paused' = b
    /\ IF b
       THEN /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ steps' = 0
            /\ unchanged' = 0
            /\ openGaps' = IF lockOwner # NoOwner THEN openGaps \cup {"unavailable"} ELSE openGaps
       ELSE UNCHANGED <<openGaps, recovering, panelOpen, steps, unchanged>>
    /\ UNCHANGED <<lockOwner, permission, sleeping, screenLocked, selectedNonEmpty,
                   pendingRecovery, wakeRetries, recoveryFailed>>

SetSleeping(b) ==
    /\ b # sleeping
    /\ sleeping' = b
    /\ IF b
       THEN /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ steps' = 0
            /\ unchanged' = 0
            /\ pendingRecovery' = FALSE
            /\ wakeRetries' = 0
            /\ openGaps' = IF lockOwner # NoOwner THEN openGaps \cup {"unavailable"} ELSE openGaps
       ELSE /\ pendingRecovery' = (lockOwner # NoOwner)
            /\ wakeRetries' = 0
            /\ UNCHANGED <<openGaps, recovering, panelOpen, steps, unchanged>>
    /\ UNCHANGED <<lockOwner, permission, paused, screenLocked, selectedNonEmpty, recoveryFailed>>

SetScreenLocked(b) ==
    /\ b # screenLocked
    /\ screenLocked' = b
    /\ IF b
       THEN /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ steps' = 0
            /\ unchanged' = 0
            /\ pendingRecovery' = IF recovering THEN TRUE ELSE pendingRecovery
       ELSE UNCHANGED <<recovering, panelOpen, steps, unchanged, pendingRecovery>>
    /\ UNCHANGED <<lockOwner, openGaps, permission, paused, sleeping,
                   selectedNonEmpty, wakeRetries, recoveryFailed>>

SetSelected(b) ==
    /\ b # selectedNonEmpty
    /\ selectedNonEmpty' = b
    /\ IF ~b
       THEN /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ steps' = 0
            /\ unchanged' = 0
            /\ openGaps' = IF lockOwner # NoOwner THEN openGaps \cup {"unavailable"} ELSE openGaps
       ELSE UNCHANGED <<openGaps, recovering, panelOpen, steps, unchanged>>
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, screenLocked,
                   pendingRecovery, wakeRetries, recoveryFailed>>

BeginRecoverySuccess(c) ==
    /\ CanRecover
    /\ lockOwner = c
    /\ ~recovering
    /\ recovering' = TRUE
    /\ panelOpen' = TRUE
    /\ recoveryFailed' = FALSE
    /\ pendingRecovery' = FALSE
    /\ wakeRetries' = 0
    /\ steps' = 0
    /\ unchanged' = 0
    /\ UNCHANGED <<lockOwner, openGaps, permission, paused, sleeping, screenLocked, selectedNonEmpty>>

BeginRecoveryFail(c) ==
    /\ CanRecover
    /\ lockOwner = c
    /\ ~recovering
    /\ recoveryFailed' = TRUE
    /\ openGaps' = openGaps \cup {"recovery_navigation"}
    /\ IF pendingRecovery /\ wakeRetries < MaxWakeRetries
       THEN /\ wakeRetries' = wakeRetries + 1
            /\ pendingRecovery' = TRUE
       ELSE /\ pendingRecovery' = FALSE
            /\ UNCHANGED wakeRetries
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, screenLocked, selectedNonEmpty,
                   recovering, panelOpen, steps, unchanged>>

LiveScanClean(c) ==
    /\ CanCollect
    /\ lockOwner = c
    /\ openGaps' = IF recoveryFailed THEN openGaps \cap {"recovery_navigation"} ELSE {}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, screenLocked, selectedNonEmpty,
                   pendingRecovery, wakeRetries, recovering, recoveryFailed, panelOpen, steps, unchanged>>

LiveScanPartial(c) ==
    /\ CanCollect
    /\ lockOwner = c
    /\ openGaps' = openGaps \cup {"partial_scan"}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, screenLocked, selectedNonEmpty,
                   pendingRecovery, wakeRetries, recovering, recoveryFailed, panelOpen, steps, unchanged>>

RecoveryStepProgress(c) ==
    /\ CanRecover
    /\ lockOwner = c
    /\ recovering
    /\ steps < MaxSteps
    /\ unchanged < MaxUnchanged
    /\ LET nextSteps == steps + 1 IN
       IF nextSteps < MaxSteps
       THEN /\ steps' = nextSteps
            /\ unchanged' = 0
            /\ recovering' = TRUE
            /\ panelOpen' = TRUE
            /\ UNCHANGED <<openGaps, recoveryFailed>>
       ELSE /\ steps' = 0
            /\ unchanged' = 0
            /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ recoveryFailed' = FALSE
            /\ openGaps' = openGaps \ {"recovery_navigation"}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, screenLocked,
                   selectedNonEmpty, pendingRecovery, wakeRetries>>

RecoveryStepStalled(c) ==
    /\ CanRecover
    /\ lockOwner = c
    /\ recovering
    /\ steps < MaxSteps
    /\ unchanged < MaxUnchanged
    /\ LET nextSteps == steps + 1
           nextUnchanged == unchanged + 1 IN
       IF nextSteps < MaxSteps /\ nextUnchanged < MaxUnchanged
       THEN /\ steps' = nextSteps
            /\ unchanged' = nextUnchanged
            /\ recovering' = TRUE
            /\ panelOpen' = TRUE
            /\ UNCHANGED <<openGaps, recoveryFailed>>
       ELSE /\ steps' = 0
            /\ unchanged' = 0
            /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ recoveryFailed' = FALSE
            /\ openGaps' = openGaps \ {"recovery_navigation"}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, screenLocked,
                   selectedNonEmpty, pendingRecovery, wakeRetries>>

RecoveryStepFail(c) ==
    /\ CanRecover
    /\ lockOwner = c
    /\ recovering
    /\ recovering' = FALSE
    /\ panelOpen' = FALSE
    /\ steps' = 0
    /\ unchanged' = 0
    /\ recoveryFailed' = TRUE
    /\ openGaps' = openGaps \cup {"recovery_navigation"}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, screenLocked,
                   selectedNonEmpty, pendingRecovery, wakeRetries>>

Next ==
    \/ \E c \in Collectors : AcquireLock(c)
    \/ \E c \in Collectors : ReleaseLock(c)
    \/ \E b \in BOOLEAN : SetPermission(b)
    \/ \E b \in BOOLEAN : SetPaused(b)
    \/ \E b \in BOOLEAN : SetSleeping(b)
    \/ \E b \in BOOLEAN : SetScreenLocked(b)
    \/ \E b \in BOOLEAN : SetSelected(b)
    \/ \E c \in Collectors : BeginRecoverySuccess(c)
    \/ \E c \in Collectors : BeginRecoveryFail(c)
    \/ \E c \in Collectors : LiveScanClean(c)
    \/ \E c \in Collectors : LiveScanPartial(c)
    \/ \E c \in Collectors : RecoveryStepProgress(c)
    \/ \E c \in Collectors : RecoveryStepStalled(c)
    \/ \E c \in Collectors : RecoveryStepFail(c)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ lockOwner \in Collectors \cup {NoOwner}
    /\ openGaps \subseteq GapReasons
    /\ permission \in BOOLEAN
    /\ paused \in BOOLEAN
    /\ sleeping \in BOOLEAN
    /\ screenLocked \in BOOLEAN
    /\ selectedNonEmpty \in BOOLEAN
    /\ pendingRecovery \in BOOLEAN
    /\ wakeRetries \in 0..MaxWakeRetries
    /\ recovering \in BOOLEAN
    /\ recoveryFailed \in BOOLEAN
    /\ panelOpen \in BOOLEAN
    /\ steps \in 0..MaxSteps
    /\ unchanged \in 0..MaxUnchanged

AtMostOneWriter ==
    lockOwner = NoOwner => (~recovering /\ ~panelOpen)

FailedRecoveryNotMaskedByLiveScan ==
    recoveryFailed => "recovery_navigation" \in openGaps

UnavailableStopsRecovery ==
    (~permission \/ paused \/ sleeping \/ screenLocked \/ ~selectedNonEmpty) => (~recovering /\ ~panelOpen)

LockedNeverRunsRecovery ==
    screenLocked => (~recovering /\ ~panelOpen)

WakeRetriesBounded ==
    wakeRetries <= MaxWakeRetries

NoLeakedPanel ==
    panelOpen => recovering

BudgetBoundsRecovery ==
    /\ (~recovering => steps = 0 /\ unchanged = 0)
    /\ (recovering => steps < MaxSteps /\ unchanged < MaxUnchanged)

ExclusiveWriteActions == [][
    (openGaps' # openGaps \/ recovering' # recovering \/ panelOpen' # panelOpen) =>
        (lockOwner # NoOwner \/ lockOwner' # NoOwner)
    ]_vars
=============================================================================
