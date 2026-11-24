-------------------------- MODULE WindowChrome --------------------------
EXTENDS Naturals

CONSTANTS Modes, PrimaryModes, LibraryModes, SystemModes, MaxTitlebarHeight

WidthClasses == {"wide", "compact"}
ToolbarOwners == {"swiftui_toolbar", "manual_view", "both"}
ToolbarStyles == {"unifiedCompact", "unified"}
DoubleClickPrefs == {"maximize", "minimize", "none"}

VARIABLES widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
          statusInSidebarFooter, appearanceInSidebarFooter,
          statusInCompactHeader, appearanceInCompactHeader,
          statusPopoverOpen, appearancePopoverOpen,
          doubleClickPref, zoomed, minimized, action
vars == <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
          statusInSidebarFooter, appearanceInSidebarFooter,
          statusInCompactHeader, appearanceInCompactHeader,
          statusPopoverOpen, appearancePopoverOpen,
          doubleClickPref, zoomed, minimized, action>>

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
    /\ statusInSidebarFooter = TRUE
    /\ appearanceInSidebarFooter = TRUE
    /\ statusInCompactHeader = TRUE
    /\ appearanceInCompactHeader = TRUE
    /\ statusPopoverOpen = FALSE
    /\ appearancePopoverOpen = FALSE
    /\ doubleClickPref \in DoubleClickPrefs
    /\ zoomed = FALSE
    /\ minimized = FALSE
    /\ action = "init"

ResizeWindow(w) ==
    /\ w \in WidthClasses
    /\ widthClass' = w
    /\ action' = "resize"
    /\ UNCHANGED <<activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized>>

SelectMode(m) ==
    /\ m \in Modes
    /\ activeMode' = m
    /\ action' = "select_mode"
    /\ UNCHANGED <<widthClass, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized>>

ToggleStatusPopover ==
    /\ StatusReachable
    /\ statusPopoverOpen' = ~statusPopoverOpen
    /\ appearancePopoverOpen' = IF statusPopoverOpen' THEN FALSE ELSE appearancePopoverOpen
    /\ action' = "toggle_status"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   doubleClickPref, zoomed, minimized>>

ToggleAppearancePopover ==
    /\ AppearanceReachable
    /\ appearancePopoverOpen' = ~appearancePopoverOpen
    /\ statusPopoverOpen' = IF appearancePopoverOpen' THEN FALSE ELSE statusPopoverOpen
    /\ action' = "toggle_appearance"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   doubleClickPref, zoomed, minimized>>

DoubleClickEmptyTitlebar ==
    /\ ~ControlsOccluded
    /\ ~minimized
    /\ zoomed' = IF doubleClickPref = "maximize" THEN ~zoomed ELSE zoomed
    /\ minimized' = IF doubleClickPref = "minimize" THEN TRUE ELSE minimized
    /\ action' = "double_click_empty_titlebar"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen, doubleClickPref>>

DoubleClickTitlebarControl ==
    /\ ~minimized
    /\ action' = "double_click_control"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed, minimized>>

Deminiaturize ==
    /\ minimized
    /\ minimized' = FALSE
    /\ action' = "deminiaturize"
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInSidebarFooter, appearanceInSidebarFooter,
                   statusInCompactHeader, appearanceInCompactHeader,
                   statusPopoverOpen, appearancePopoverOpen,
                   doubleClickPref, zoomed>>

Next ==
    \/ \E w \in WidthClasses : ResizeWindow(w)
    \/ \E m \in Modes : SelectMode(m)
    \/ ToggleStatusPopover
    \/ ToggleAppearancePopover
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
    /\ statusInSidebarFooter \in BOOLEAN
    /\ appearanceInSidebarFooter \in BOOLEAN
    /\ statusInCompactHeader \in BOOLEAN
    /\ appearanceInCompactHeader \in BOOLEAN
    /\ statusPopoverOpen \in BOOLEAN
    /\ appearancePopoverOpen \in BOOLEAN
    /\ doubleClickPref \in DoubleClickPrefs
    /\ zoomed \in BOOLEAN
    /\ minimized \in BOOLEAN

SingleTitlebarOwner ==
    toolbarOwner = "swiftui_toolbar"

TitlebarHeightBounded ==
    TitlebarHeight <= MaxTitlebarHeight

BrandAlwaysVisibleInTitlebar ==
    BrandVisible

GlobalControlsAlwaysReachable ==
    StatusReachable /\ AppearanceReachable

AtMostOneToolbarPopoverOpen ==
    ~(statusPopoverOpen /\ appearancePopoverOpen)

SidebarCompleteAndDisjoint ==
    SidebarSectionsPartitionModes

DoubleClickTitlebarBehavior == [][
    /\ (action' = "double_click_empty_titlebar" /\ doubleClickPref = "maximize") => (zoomed' # zoomed /\ minimized' = minimized)
    /\ (action' = "double_click_empty_titlebar" /\ doubleClickPref = "minimize") => (minimized' = TRUE /\ zoomed' = zoomed)
    /\ (action' = "double_click_empty_titlebar" /\ doubleClickPref = "none") => (zoomed' = zoomed /\ minimized' = minimized)
    /\ (action' = "double_click_control") => (zoomed' = zoomed /\ minimized' = minimized)
    ]_vars
=============================================================================
