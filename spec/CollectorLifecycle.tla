------------------------- MODULE CollectorLifecycle -------------------------
EXTENDS Naturals
CONSTANTS Collectors, NoOwner, MaxSteps, MaxUnchanged

GapReasons == {"collector_stopped", "unavailable", "partial_scan", "recovery_navigation"}

VARIABLES lockOwner, openGaps, permission, paused, sleeping, selectedNonEmpty,
          recovering, recoveryFailed, panelOpen, steps, unchanged

vars == <<lockOwner, openGaps, permission, paused, sleeping, selectedNonEmpty,
          recovering, recoveryFailed, panelOpen, steps, unchanged>>

CanCollect ==
    /\ lockOwner # NoOwner
    /\ permission
    /\ ~paused
    /\ ~sleeping
    /\ selectedNonEmpty

Init ==
    /\ lockOwner = NoOwner
    /\ openGaps = {}
    /\ permission = FALSE
    /\ paused = FALSE
    /\ sleeping = FALSE
    /\ selectedNonEmpty = TRUE
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
    /\ UNCHANGED <<permission, paused, sleeping, selectedNonEmpty,
                   recovering, panelOpen, steps, unchanged>>

ReleaseLock(c) ==
    /\ lockOwner = c
    /\ lockOwner' = NoOwner
    /\ recovering' = FALSE
    /\ panelOpen' = FALSE
    /\ steps' = 0
    /\ unchanged' = 0
    /\ UNCHANGED <<openGaps, permission, paused, sleeping, selectedNonEmpty, recoveryFailed>>

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
    /\ UNCHANGED <<lockOwner, paused, sleeping, selectedNonEmpty, recoveryFailed>>

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
    /\ UNCHANGED <<lockOwner, permission, sleeping, selectedNonEmpty, recoveryFailed>>

SetSleeping(b) ==
    /\ b # sleeping
    /\ sleeping' = b
    /\ IF b
       THEN /\ recovering' = FALSE
            /\ panelOpen' = FALSE
            /\ steps' = 0
            /\ unchanged' = 0
            /\ openGaps' = IF lockOwner # NoOwner THEN openGaps \cup {"unavailable"} ELSE openGaps
       ELSE UNCHANGED <<openGaps, recovering, panelOpen, steps, unchanged>>
    /\ UNCHANGED <<lockOwner, permission, paused, selectedNonEmpty, recoveryFailed>>

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
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, recoveryFailed>>

BeginRecoverySuccess(c) ==
    /\ CanCollect
    /\ lockOwner = c
    /\ ~recovering
    /\ recovering' = TRUE
    /\ panelOpen' = TRUE
    /\ recoveryFailed' = FALSE
    /\ steps' = 0
    /\ unchanged' = 0
    /\ UNCHANGED <<lockOwner, openGaps, permission, paused, sleeping, selectedNonEmpty>>

BeginRecoveryFail(c) ==
    /\ CanCollect
    /\ lockOwner = c
    /\ ~recovering
    /\ recoveryFailed' = TRUE
    /\ openGaps' = openGaps \cup {"recovery_navigation"}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, selectedNonEmpty,
                   recovering, panelOpen, steps, unchanged>>

LiveScanClean(c) ==
    /\ CanCollect
    /\ lockOwner = c
    /\ openGaps' = IF recoveryFailed THEN openGaps \cap {"recovery_navigation"} ELSE {}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, selectedNonEmpty,
                   recovering, recoveryFailed, panelOpen, steps, unchanged>>

LiveScanPartial(c) ==
    /\ CanCollect
    /\ lockOwner = c
    /\ openGaps' = openGaps \cup {"partial_scan"}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, selectedNonEmpty,
                   recovering, recoveryFailed, panelOpen, steps, unchanged>>

RecoveryStepProgress(c) ==
    /\ CanCollect
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
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, selectedNonEmpty>>

RecoveryStepStalled(c) ==
    /\ CanCollect
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
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, selectedNonEmpty>>

RecoveryStepFail(c) ==
    /\ CanCollect
    /\ lockOwner = c
    /\ recovering
    /\ recovering' = FALSE
    /\ panelOpen' = FALSE
    /\ steps' = 0
    /\ unchanged' = 0
    /\ recoveryFailed' = TRUE
    /\ openGaps' = openGaps \cup {"recovery_navigation"}
    /\ UNCHANGED <<lockOwner, permission, paused, sleeping, selectedNonEmpty>>

Next ==
    \/ \E c \in Collectors : AcquireLock(c)
    \/ \E c \in Collectors : ReleaseLock(c)
    \/ \E b \in BOOLEAN : SetPermission(b)
    \/ \E b \in BOOLEAN : SetPaused(b)
    \/ \E b \in BOOLEAN : SetSleeping(b)
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
    /\ selectedNonEmpty \in BOOLEAN
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
    (~permission \/ paused \/ sleeping \/ ~selectedNonEmpty) => (~recovering /\ ~panelOpen)

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
