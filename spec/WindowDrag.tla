---------------------------- MODULE WindowDrag ----------------------------
EXTENDS Integers

(*
  Formal state machine for Notifdex's native AppKit App Center window lifecycle,
  deterministic anchor-based multi-monitor titlebar dragging (bypassing macOS 27.2's
  broken SkyLight client-initiated drag trait gesture), activation policy ordering,
  SwiftUI sizing isolation, and offscreen bounds recovery.

  Design correspondence:
  - Sources/NotifdexApp/AppCenterWindowController.swift
  - Sources/NotifdexCore/WindowChromeLayout.swift (TitlebarDragSession,
    TitlebarDragZone, WindowChromeSyncState, WindowPlacementGeometry)
*)

WindowOwners == {"appkit_window_controller", "swiftui_window_scene"}
HitTargets == {"native_theme_frame", "swiftui_hosting_view"}
DragEngines == {"direct_anchor_tracking", "client_drag_gesture"}
ActivationPolicies == {"regular", "accessory"}
Placements == {"on_a", "on_b", "straddling", "offscreen"}
VisiblePlacements == {"on_a", "on_b", "straddling"}

(* Finite discrete X coordinate grid across two adjacent displays:
   Display A: 0..2, Display B: 3..5; window origin can glide smoothly across all positions. *)
MousePositions == 0..4
OriginPositions == -2..6

VARIABLES windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
          hostingSizingIsolated,
          windowOpen, activationPolicy, placement, dragging,
          startMouseX, startOriginX, mouseX, windowX,
          desiredTransparent, appliedTransparent,
          pendingChromeSync, pendingBoundsRecovery,
          chromeMutatedDuringDrag,
          action

vars == <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
          hostingSizingIsolated,
          windowOpen, activationPolicy, placement, dragging,
          startMouseX, startOriginX, mouseX, windowX,
          desiredTransparent, appliedTransparent,
          pendingChromeSync, pendingBoundsRecovery,
          chromeMutatedDuringDrag,
          action>>

PlacementForX(x) ==
    IF x <= 1 THEN "on_a"
    ELSE IF x = 2 THEN "straddling"
    ELSE "on_b"

Init ==
    /\ windowOwner = "appkit_window_controller"
    /\ titlebarHitTarget = "native_theme_frame"
    /\ dragEngine = "direct_anchor_tracking"
    /\ systemDragGestureEnabled = FALSE
    /\ hostingSizingIsolated = TRUE
    /\ windowOpen = FALSE
    /\ activationPolicy = "accessory"
    /\ placement = "on_a"
    /\ dragging = FALSE
    /\ startMouseX = 1
    /\ startOriginX = 1
    /\ mouseX = 1
    /\ windowX = 1
    /\ desiredTransparent = TRUE
    /\ appliedTransparent = TRUE
    /\ pendingChromeSync = FALSE
    /\ pendingBoundsRecovery = FALSE
    /\ chromeMutatedDuringDrag = FALSE
    /\ action = "init"

OpenWindow ==
    /\ ~windowOpen
    /\ activationPolicy' = "regular"
    /\ windowOpen' = TRUE
    /\ placement' = IF placement = "offscreen" THEN "on_a" ELSE placement
    /\ windowX' = IF placement = "offscreen" THEN 1 ELSE windowX
    /\ appliedTransparent' = desiredTransparent
    /\ pendingChromeSync' = FALSE
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "open_window"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   dragging, startMouseX, startOriginX, mouseX, desiredTransparent,
                   chromeMutatedDuringDrag>>

CloseWindow ==
    /\ windowOpen
    /\ ~dragging
    /\ windowOpen' = FALSE
    /\ activationPolicy' = "accessory"
    /\ pendingChromeSync' = FALSE
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "close_window"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   placement, dragging, startMouseX, startOriginX, mouseX, windowX,
                   desiredTransparent, appliedTransparent,
                   chromeMutatedDuringDrag>>

BeginDrag(m) ==
    /\ windowOpen
    /\ ~dragging
    /\ placement \in VisiblePlacements
    /\ m \in MousePositions
    /\ dragging' = TRUE
    /\ startMouseX' = m
    /\ startOriginX' = windowX
    /\ mouseX' = m
    /\ action' = "begin_drag"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   windowOpen, activationPolicy, placement, windowX,
                   desiredTransparent, appliedTransparent,
                   pendingChromeSync, pendingBoundsRecovery,
                   chromeMutatedDuringDrag>>

DragTo(m) ==
    /\ windowOpen
    /\ dragging
    /\ m \in MousePositions
    /\ LET nextX == startOriginX + (m - startMouseX) IN
       /\ nextX \in OriginPositions
       /\ mouseX' = m
       /\ windowX' = nextX
       /\ placement' = PlacementForX(nextX)
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "drag_to"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   windowOpen, activationPolicy, dragging,
                   startMouseX, startOriginX,
                   desiredTransparent, appliedTransparent,
                   pendingChromeSync,
                   chromeMutatedDuringDrag>>

SwiftUIWorkerTick ==
    /\ windowOpen
    /\ IF dragging
          THEN /\ appliedTransparent' = appliedTransparent
               /\ pendingChromeSync' = (desiredTransparent # appliedTransparent)
          ELSE /\ appliedTransparent' = desiredTransparent
               /\ pendingChromeSync' = FALSE
    /\ action' = "swiftui_worker_tick"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   windowOpen, activationPolicy, placement, dragging,
                   startMouseX, startOriginX, mouseX, windowX,
                   desiredTransparent, pendingBoundsRecovery,
                   chromeMutatedDuringDrag>>

ChangeAppearanceTransparency(t) ==
    /\ t \in BOOLEAN
    /\ t # desiredTransparent
    /\ desiredTransparent' = t
    /\ IF windowOpen /\ ~dragging
          THEN /\ appliedTransparent' = t
               /\ pendingChromeSync' = FALSE
          ELSE IF windowOpen /\ dragging
                  THEN /\ appliedTransparent' = appliedTransparent
                       /\ pendingChromeSync' = (t # appliedTransparent)
                  ELSE /\ appliedTransparent' = appliedTransparent
                       /\ pendingChromeSync' = FALSE
    /\ action' = "change_transparency"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   windowOpen, activationPolicy, placement, dragging,
                   startMouseX, startOriginX, mouseX, windowX,
                   pendingBoundsRecovery,
                   chromeMutatedDuringDrag>>

DisplayDisconnected ==
    /\ IF ~windowOpen
          THEN /\ placement' = "offscreen"
               /\ pendingBoundsRecovery' = TRUE
               /\ windowX' = windowX
          ELSE IF dragging
                  THEN /\ placement' = "offscreen"
                       /\ pendingBoundsRecovery' = TRUE
                       /\ windowX' = windowX
                  ELSE /\ placement' = "on_a"
                       /\ pendingBoundsRecovery' = FALSE
                       /\ windowX' = 1
    /\ action' = "display_disconnected"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   windowOpen, activationPolicy, dragging,
                   startMouseX, startOriginX, mouseX,
                   desiredTransparent, appliedTransparent, pendingChromeSync,
                   chromeMutatedDuringDrag>>

EndDrag ==
    /\ windowOpen
    /\ dragging
    /\ dragging' = FALSE
    /\ appliedTransparent' = desiredTransparent
    /\ pendingChromeSync' = FALSE
    /\ IF pendingBoundsRecovery \/ placement = "offscreen"
          THEN /\ placement' = "on_a"
               /\ windowX' = 1
          ELSE /\ placement' = placement
               /\ windowX' = windowX
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "end_drag"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   windowOpen, activationPolicy,
                   startMouseX, startOriginX, mouseX,
                   desiredTransparent, chromeMutatedDuringDrag>>

ResignKeyMidDrag ==
    /\ windowOpen
    /\ dragging
    /\ dragging' = FALSE
    /\ appliedTransparent' = desiredTransparent
    /\ pendingChromeSync' = FALSE
    /\ IF pendingBoundsRecovery \/ placement = "offscreen"
          THEN /\ placement' = "on_a"
               /\ windowX' = 1
          ELSE /\ placement' = placement
               /\ windowX' = windowX
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "resign_key_mid_drag"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, dragEngine, systemDragGestureEnabled,
                   hostingSizingIsolated,
                   windowOpen, activationPolicy,
                   startMouseX, startOriginX, mouseX,
                   desiredTransparent, chromeMutatedDuringDrag>>

Next ==
    \/ OpenWindow
    \/ CloseWindow
    \/ \E m \in MousePositions : BeginDrag(m)
    \/ \E m \in MousePositions : DragTo(m)
    \/ SwiftUIWorkerTick
    \/ \E t \in BOOLEAN : ChangeAppearanceTransparency(t)
    \/ DisplayDisconnected
    \/ EndDrag
    \/ ResignKeyMidDrag

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ windowOwner \in WindowOwners
    /\ titlebarHitTarget \in HitTargets
    /\ dragEngine \in DragEngines
    /\ systemDragGestureEnabled \in BOOLEAN
    /\ hostingSizingIsolated \in BOOLEAN
    /\ windowOpen \in BOOLEAN
    /\ activationPolicy \in ActivationPolicies
    /\ placement \in Placements
    /\ dragging \in BOOLEAN
    /\ startMouseX \in MousePositions
    /\ startOriginX \in OriginPositions
    /\ mouseX \in MousePositions
    /\ windowX \in OriginPositions
    /\ desiredTransparent \in BOOLEAN
    /\ appliedTransparent \in BOOLEAN
    /\ pendingChromeSync \in BOOLEAN
    /\ pendingBoundsRecovery \in BOOLEAN
    /\ chromeMutatedDuringDrag \in BOOLEAN

NativeAppKitOwnership ==
    /\ windowOwner = "appkit_window_controller"
    /\ titlebarHitTarget = "native_theme_frame"
    /\ dragEngine = "direct_anchor_tracking"
    /\ hostingSizingIsolated

NoCompetingSystemDragGesture ==
    ~systemDragGestureEnabled

ActivationPolicyMatchesWindow ==
    /\ (windowOpen => activationPolicy = "regular")
    /\ (~windowOpen => activationPolicy = "accessory")

ZeroCumulativeDragDrift ==
    dragging => (windowX = startOriginX + (mouseX - startMouseX))

NoChromeMutationDuringDrag ==
    ~chromeMutatedDuringDrag

PendingSyncFlushedWhenIdle ==
    (windowOpen /\ ~dragging) => (appliedTransparent = desiredTransparent /\ ~pendingChromeSync)

TitlebarReachableWhenOpenAndIdle ==
    (windowOpen /\ ~dragging) => (placement \in VisiblePlacements /\ ~pendingBoundsRecovery)

DragStabilityProperty == [][
    /\ (action' = "drag_to") =>
        (appliedTransparent' = appliedTransparent /\ ~chromeMutatedDuringDrag')
    /\ (action' = "swiftui_worker_tick") =>
        (windowX' = windowX /\ placement' = placement)
    /\ (action' = "swiftui_worker_tick" /\ dragging) =>
        (appliedTransparent' = appliedTransparent)
    /\ ((action' = "end_drag" \/ action' = "resign_key_mid_drag") /\ ~pendingBoundsRecovery /\ placement \in VisiblePlacements) =>
        (windowX' = windowX /\ placement' = placement)
    ]_vars
=============================================================================
