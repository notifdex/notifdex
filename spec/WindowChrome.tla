-------------------------- MODULE WindowChrome --------------------------
EXTENDS Naturals

CONSTANTS Modes, PrimaryModes, LibraryModes, SystemModes, Screens, MaxTitlebarHeight

WidthClasses == {"wide", "compact"}
ToolbarOwners == {"swiftui_toolbar", "manual_view", "both"}
ToolbarStyles == {"unifiedCompact", "unified"}
DoubleClickPrefs == {"maximize", "minimize", "none"}

VARIABLES widthClass, activeMode, toolbarOwner, toolbarStyle,
          brandInToolbar, brandPillHidden,
          statusInSidebarFooter, appearanceInSidebarFooter,
          statusInCompactHeader, appearanceInCompactHeader,
          statusPopoverOpen, appearancePopoverOpen,
          doubleClickPref, zoomed, minimized,
          screen, dragging, draggedSinceMouseDown,
          chromeApplied, desiredTransparent, appliedTransparent,
          pendingChromeSync, chromeMutatedDuringDrag,
          action

vars == <<widthClass, activeMode, toolbarOwner, toolbarStyle,
          brandInToolbar, brandPillHidden,
          statusInSidebarFooter, appearanceInSidebarFooter,
          statusInCompactHeader, appearanceInCompactHeader,
          statusPopoverOpen, appearancePopoverOpen,
          doubleClickPref, zoomed, minimized,
          screen, dragging, draggedSinceMouseDown,
          chromeApplied, desiredTransparent, appliedTransparent,
          pendingChromeSync, chromeMutatedDuringDrag,
          action>>

TitlebarHeight ==
    CASE toolbarOwner = "both" -> 104
      [] toolbarStyle = "unifiedCompact" -> 38
      [] OTHER -> 52

ControlsOccluded ==
    toolbarOwner = "both"

BrandVisible ==
    brandInToolbar /\ ~ControlsOccluded

StatusReachable ==
    IF widthClass = "wide" THEN statusInSidebarFooter ELSE statusInCompactHeader

AppearanceReachable ==
    IF widthClass = "wide" THEN appearanceInSidebarFooter ELSE appearanceInCompactHeader

ShowsSidebar ==
    widthClass = "wide"

ShowsCompactPicker ==
    widthClass = "compact"

ShowsMainPanelHeading ==
    FALSE

SidebarSectionsPartitionModes ==
    /\ PrimaryModes \cup LibraryModes \cup SystemModes = Modes
    /\ PrimaryModes \cap LibraryModes = {}
    /\ PrimaryModes \cap SystemModes = {}
    /\ LibraryModes \cap SystemModes = {}

Init ==
    /\ widthClass = "wide"
    /\ activeMode \in PrimaryModes
    /\ toolbarOwner = "swiftui_toolbar"
    /\ toolbarStyle = "unifiedCompact"
    /\ brandInToolbar = TRUE
    /\ brandPillHidden = TRUE
    /\ statusInSidebarFooter = TRUE
    /\ appearanceInSidebarFooter = TRUE
    /\ statusInCompactHeader = TRUE
    /\ appearanceInCompactHeader = TRUE
    /\ statusPopoverOpen = FALSE
    /\ appearancePopoverOpen = FALSE
    /\ doubleClickPref \in DoubleClickPrefs
    /\ zoomed = FALSE
    /\ minimized = FALSE
    /\ screen \in Screens
    /\ dragging = FALSE
    /\ draggedSinceMouseDown = FALSE
    /\ chromeApplied = TRUE
    /\ desiredTransparent = TRUE
    /\ appliedTransparent = TRUE
    /\ pendingChromeSync = FALSE
    /\ chromeMutatedDuringDrag = FALSE
    /\ action = "init"

ResizeWindow(w) ==
    /\ ~dragging
    /\ w \in WidthClasses
    /\ widthClass' = w
    /\ action' = "resize"
    /\ UNCHANGED <<activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

SelectMode(m) ==
    /\ m \in Modes
    /\ activeMode' = m
    /\ action' = "select_mode"
    /\ UNCHANGED <<widthClass, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

ToggleStatusPopover ==
    /\ StatusReachable
    /\ statusPopoverOpen' = ~statusPopoverOpen
    /\ appearancePopoverOpen' = IF statusPopoverOpen' THEN FALSE ELSE appearancePopoverOpen
    /\ action' = "toggle_status"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   doubleClickPref, zoomed, minimized,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

ToggleAppearancePopover ==
    /\ AppearanceReachable
    /\ appearancePopoverOpen' = ~appearancePopoverOpen
    /\ statusPopoverOpen' = IF appearancePopoverOpen' THEN FALSE ELSE statusPopoverOpen
    /\ action' = "toggle_appearance"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   doubleClickPref, zoomed, minimized,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

BeginWindowDrag ==
    /\ ~minimized
    /\ ~dragging
    /\ dragging' = TRUE
    /\ draggedSinceMouseDown' = FALSE
    /\ action' = "begin_drag"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   screen, chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

MoveAcrossMonitor(s) ==
    /\ dragging
    /\ s \in Screens
    /\ screen' = s
    /\ draggedSinceMouseDown' = TRUE
    /\ action' = "move_across_monitor"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   dragging, chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

ChangeTransparency(t) ==
    /\ t \in BOOLEAN
    /\ t # desiredTransparent
    /\ desiredTransparent' = t
    /\ IF dragging
          THEN /\ appliedTransparent' = appliedTransparent
               /\ pendingChromeSync' = (t # appliedTransparent)
          ELSE /\ appliedTransparent' = t
               /\ pendingChromeSync' = FALSE
    /\ action' = "change_transparency"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, chromeMutatedDuringDrag>>

SwiftUIUpdateTick ==
    /\ IF dragging
          THEN /\ appliedTransparent' = appliedTransparent
               /\ pendingChromeSync' = (desiredTransparent # appliedTransparent)
               /\ chromeMutatedDuringDrag' = chromeMutatedDuringDrag
          ELSE /\ appliedTransparent' = desiredTransparent
               /\ pendingChromeSync' = FALSE
               /\ chromeMutatedDuringDrag' = chromeMutatedDuringDrag
    /\ action' = "swiftui_update_tick"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent>>

EndWindowDrag ==
    /\ dragging
    /\ dragging' = FALSE
    /\ draggedSinceMouseDown' = FALSE
    /\ appliedTransparent' = desiredTransparent
    /\ pendingChromeSync' = FALSE
    /\ action' = "end_drag"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   screen, chromeApplied, desiredTransparent, chromeMutatedDuringDrag>>

DoubleClickEmptyTitlebar ==
    /\ ~ControlsOccluded
    /\ ~minimized
    /\ ~dragging
    /\ ~draggedSinceMouseDown
    /\ zoomed' = IF doubleClickPref = "maximize" THEN ~zoomed ELSE zoomed
    /\ minimized' = IF doubleClickPref = "minimize" THEN TRUE ELSE minimized
    /\ action' = "double_click_empty_titlebar"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen, doubleClickPref,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

DoubleClickTitlebarControl ==
    /\ ~minimized
    /\ action' = "double_click_control"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

Deminiaturize ==
    /\ minimized
    /\ minimized' = FALSE
    /\ action' = "deminiaturize"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar, brandPillHidden,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed,
                   screen, dragging, draggedSinceMouseDown,
                   chromeApplied, desiredTransparent, appliedTransparent,
                   pendingChromeSync, chromeMutatedDuringDrag>>

Next ==
    \/ \E w \in WidthClasses : ResizeWindow(w)
    \/ \E m \in Modes : SelectMode(m)
    \/ ToggleStatusPopover
    \/ ToggleAppearancePopover
    \/ BeginWindowDrag
    \/ \E s \in Screens : MoveAcrossMonitor(s)
    \/ \E t \in BOOLEAN : ChangeTransparency(t)
    \/ SwiftUIUpdateTick
    \/ EndWindowDrag
    \/ DoubleClickEmptyTitlebar
    \/ DoubleClickTitlebarControl
    \/ Deminiaturize

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ widthClass \in WidthClasses
    /\ activeMode \in Modes
    /\ toolbarOwner \in ToolbarOwners
    /\ toolbarStyle \in ToolbarStyles
    /\ brandInToolbar \in BOOLEAN
    /\ brandPillHidden \in BOOLEAN
    /\ statusInSidebarFooter \in BOOLEAN
    /\ appearanceInSidebarFooter \in BOOLEAN
    /\ statusInCompactHeader \in BOOLEAN
    /\ appearanceInCompactHeader \in BOOLEAN
    /\ statusPopoverOpen \in BOOLEAN
    /\ appearancePopoverOpen \in BOOLEAN
    /\ doubleClickPref \in DoubleClickPrefs
    /\ zoomed \in BOOLEAN
    /\ minimized \in BOOLEAN
    /\ screen \in Screens
    /\ dragging \in BOOLEAN
    /\ draggedSinceMouseDown \in BOOLEAN
    /\ chromeApplied \in BOOLEAN
    /\ desiredTransparent \in BOOLEAN
    /\ appliedTransparent \in BOOLEAN
    /\ pendingChromeSync \in BOOLEAN
    /\ chromeMutatedDuringDrag \in BOOLEAN

SingleTitlebarOwner ==
    toolbarOwner = "swiftui_toolbar"

TitlebarHeightBounded ==
    TitlebarHeight <= MaxTitlebarHeight

BrandAlwaysVisibleInTitlebar ==
    BrandVisible

NoBrandToolbarBubble ==
    brandPillHidden

GlobalControlsAlwaysReachable ==
    StatusReachable /\ AppearanceReachable

AtMostOneToolbarPopoverOpen ==
    ~(statusPopoverOpen /\ appearancePopoverOpen)

SidebarCompleteAndDisjoint ==
    SidebarSectionsPartitionModes

ActiveModeAlwaysIndicated ==
    ShowsSidebar \/ ShowsCompactPicker

NoDuplicateActiveModeHeading ==
    ~(ShowsSidebar /\ ShowsMainPanelHeading)

NoWindowChromeMutationDuringDrag ==
    ~chromeMutatedDuringDrag

PendingChromeSyncFlushedWhenIdle ==
    (~dragging /\ chromeApplied) => (appliedTransparent = desiredTransparent /\ ~pendingChromeSync)

DoubleClickTitlebarBehavior == [][
    /\ (action' = "double_click_empty_titlebar" /\ doubleClickPref = "maximize") => (zoomed' # zoomed /\ minimized' = minimized)
    /\ (action' = "double_click_empty_titlebar" /\ doubleClickPref = "minimize") => (minimized' = TRUE /\ zoomed' = zoomed)
    /\ (action' = "double_click_empty_titlebar" /\ doubleClickPref = "none") => (zoomed' = zoomed /\ minimized' = minimized)
    /\ (action' = "double_click_control") => (zoomed' = zoomed /\ minimized' = minimized)
    /\ (action' = "end_drag") => (zoomed' = zoomed /\ minimized' = minimized)
    /\ (action' = "move_across_monitor") => (appliedTransparent' = appliedTransparent /\ zoomed' = zoomed /\ minimized' = minimized)
    ]_vars
=============================================================================
