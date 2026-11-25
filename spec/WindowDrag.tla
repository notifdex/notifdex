---------------------------- MODULE WindowDrag ----------------------------
EXTENDS Naturals

(*
  Formal state machine for Notifdex's native AppKit App Center window lifecycle,
  cross-monitor drag stability, activation policy ordering, SwiftUI sizing
  isolation, and offscreen bounds recovery.

  Design correspondence:
  - Sources/NotifdexApp/AppCenterWindowController.swift
  - Sources/NotifdexCore/WindowChromeLayout.swift (WindowChromeSyncState,
    WindowPlacementGeometry, WindowArchitecturePolicy)
*)

WindowOwners == {"appkit_window_controller", "swiftui_window_scene"}
HitTargets == {"native_theme_frame", "swiftui_hosting_view"}
ActivationPolicies == {"regular", "accessory"}
Placements == {"on_a", "on_b", "straddling", "offscreen"}
VisiblePlacements == {"on_a", "on_b", "straddling"}

VARIABLES windowOwner, titlebarHitTarget, hostingSizingIsolated,
          windowOpen, activationPolicy, placement, dragging,
          desiredTransparent, appliedTransparent,
          pendingChromeSync, pendingBoundsRecovery,
          chromeMutatedDuringDrag, frameMutatedDuringDrag,
          action

vars == <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
          windowOpen, activationPolicy, placement, dragging,
          desiredTransparent, appliedTransparent,
          pendingChromeSync, pendingBoundsRecovery,
          chromeMutatedDuringDrag, frameMutatedDuringDrag,
          action>>

Init ==
    /\ windowOwner = "appkit_window_controller"
    /\ titlebarHitTarget = "native_theme_frame"
    /\ hostingSizingIsolated = TRUE
    /\ windowOpen = FALSE
    /\ activationPolicy = "accessory"
    /\ placement = "on_a"
    /\ dragging = FALSE
    /\ desiredTransparent = TRUE
    /\ appliedTransparent = TRUE
    /\ pendingChromeSync = FALSE
    /\ pendingBoundsRecovery = FALSE
    /\ chromeMutatedDuringDrag = FALSE
    /\ frameMutatedDuringDrag = FALSE
    /\ action = "init"

OpenWindow ==
    /\ ~windowOpen
    /\ activationPolicy' = "regular"
    /\ windowOpen' = TRUE
    /\ placement' = IF placement = "offscreen" THEN "on_a" ELSE placement
    /\ appliedTransparent' = desiredTransparent
    /\ pendingChromeSync' = FALSE
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "open_window"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   dragging, desiredTransparent,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

CloseWindow ==
    /\ windowOpen
    /\ ~dragging
    /\ windowOpen' = FALSE
    /\ activationPolicy' = "accessory"
    /\ pendingChromeSync' = FALSE
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "close_window"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   placement, dragging, desiredTransparent, appliedTransparent,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

BeginDrag ==
    /\ windowOpen
    /\ ~dragging
    /\ placement \in VisiblePlacements
    /\ dragging' = TRUE
    /\ action' = "begin_drag"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   windowOpen, activationPolicy, placement,
                   desiredTransparent, appliedTransparent,
                   pendingChromeSync, pendingBoundsRecovery,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

DragTo(p) ==
    /\ windowOpen
    /\ dragging
    /\ p \in VisiblePlacements
    /\ placement' = p
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "drag_to"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   windowOpen, activationPolicy, dragging,
                   desiredTransparent, appliedTransparent,
                   pendingChromeSync,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

SwiftUIWorkerTick ==
    /\ windowOpen
    /\ IF dragging
          THEN /\ appliedTransparent' = appliedTransparent
               /\ pendingChromeSync' = (desiredTransparent # appliedTransparent)
          ELSE /\ appliedTransparent' = desiredTransparent
               /\ pendingChromeSync' = FALSE
    /\ action' = "swiftui_worker_tick"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   windowOpen, activationPolicy, placement, dragging,
                   desiredTransparent, pendingBoundsRecovery,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

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
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   windowOpen, activationPolicy, placement, dragging,
                   pendingBoundsRecovery,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

DisplayDisconnected ==
    /\ IF ~windowOpen
          THEN /\ placement' = "offscreen"
               /\ pendingBoundsRecovery' = TRUE
          ELSE IF dragging
                  THEN /\ placement' = "offscreen"
                       /\ pendingBoundsRecovery' = TRUE
                  ELSE /\ placement' = "on_a"
                       /\ pendingBoundsRecovery' = FALSE
    /\ action' = "display_disconnected"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   windowOpen, activationPolicy, dragging,
                   desiredTransparent, appliedTransparent, pendingChromeSync,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

EndDrag ==
    /\ windowOpen
    /\ dragging
    /\ dragging' = FALSE
    /\ appliedTransparent' = desiredTransparent
    /\ pendingChromeSync' = FALSE
    /\ placement' = IF pendingBoundsRecovery \/ placement = "offscreen"
                       THEN "on_a"
                       ELSE placement
    /\ pendingBoundsRecovery' = FALSE
    /\ action' = "end_drag"
    /\ UNCHANGED <<windowOwner, titlebarHitTarget, hostingSizingIsolated,
                   windowOpen, activationPolicy, desiredTransparent,
                   chromeMutatedDuringDrag, frameMutatedDuringDrag>>

Next ==
    \/ OpenWindow
    \/ CloseWindow
    \/ BeginDrag
    \/ \E p \in VisiblePlacements : DragTo(p)
    \/ SwiftUIWorkerTick
    \/ \E t \in BOOLEAN : ChangeAppearanceTransparency(t)
    \/ DisplayDisconnected
    \/ EndDrag

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ windowOwner \in WindowOwners
    /\ titlebarHitTarget \in HitTargets
    /\ hostingSizingIsolated \in BOOLEAN
    /\ windowOpen \in BOOLEAN
    /\ activationPolicy \in ActivationPolicies
    /\ placement \in Placements
    /\ dragging \in BOOLEAN
    /\ desiredTransparent \in BOOLEAN
    /\ appliedTransparent \in BOOLEAN
    /\ pendingChromeSync \in BOOLEAN
    /\ pendingBoundsRecovery \in BOOLEAN
    /\ chromeMutatedDuringDrag \in BOOLEAN
    /\ frameMutatedDuringDrag \in BOOLEAN

NativeAppKitOwnership ==
    /\ windowOwner = "appkit_window_controller"
    /\ titlebarHitTarget = "native_theme_frame"
    /\ hostingSizingIsolated

ActivationPolicyMatchesWindow ==
    /\ (windowOpen => activationPolicy = "regular")
    /\ (~windowOpen => activationPolicy = "accessory")

NoChromeMutationDuringDrag ==
    ~chromeMutatedDuringDrag

NoFrameMutationDuringDrag ==
    ~frameMutatedDuringDrag

PendingSyncFlushedWhenIdle ==
    (windowOpen /\ ~dragging) => (appliedTransparent = desiredTransparent /\ ~pendingChromeSync)

TitlebarReachableWhenOpenAndIdle ==
    (windowOpen /\ ~dragging) => (placement \in VisiblePlacements /\ ~pendingBoundsRecovery)

DragStabilityProperty == [][
    /\ (action' = "drag_to") =>
        (appliedTransparent' = appliedTransparent /\ ~frameMutatedDuringDrag' /\ ~chromeMutatedDuringDrag')
    /\ (action' = "swiftui_worker_tick" /\ dragging) =>
        (placement' = placement /\ appliedTransparent' = appliedTransparent)
    /\ (action' = "swiftui_worker_tick" /\ ~dragging) =>
        (placement' = placement)
    /\ (action' = "end_drag" /\ ~pendingBoundsRecovery /\ placement \in VisiblePlacements) =>
        (placement' = placement)
    ]_vars
=============================================================================
