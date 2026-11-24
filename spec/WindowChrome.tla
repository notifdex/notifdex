-------------------------- MODULE WindowChrome --------------------------
CONSTANTS Modes, PrimaryModes, LibraryModes, SystemModes, MaxTitlebarHeight

WidthClasses == {"wide", "compact"}
ToolbarOwners == {"swiftui_toolbar", "manual_view", "both"}
ToolbarStyles == {"unifiedCompact", "unified"}

VARIABLES widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
          statusInToolbar, appearanceInToolbar, statusPopoverOpen, appearancePopoverOpen
vars == <<widthClass, activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
          statusInToolbar, appearanceInToolbar, statusPopoverOpen, appearancePopoverOpen>>

TitlebarHeight ==
    CASE toolbarOwner = "both" -> 104
      [] toolbarStyle = "unifiedCompact" -> 38
      [] OTHER -> 52

ControlsOccluded ==
    toolbarOwner = "both"

BrandVisible ==
    brandInToolbar /\ ~ControlsOccluded

StatusReachable ==
    statusInToolbar /\ ~ControlsOccluded

AppearanceReachable ==
    appearanceInToolbar /\ ~ControlsOccluded

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
    /\ statusInToolbar = TRUE
    /\ appearanceInToolbar = TRUE
    /\ statusPopoverOpen = FALSE
    /\ appearancePopoverOpen = FALSE

ResizeWindow(w) ==
    /\ w \in WidthClasses
    /\ widthClass' = w
    /\ UNCHANGED <<activeMode, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInToolbar, appearanceInToolbar, statusPopoverOpen, appearancePopoverOpen>>

SelectMode(m) ==
    /\ m \in Modes
    /\ activeMode' = m
    /\ UNCHANGED <<widthClass, toolbarOwner, toolbarStyle, brandInToolbar,
                   statusInToolbar, appearanceInToolbar, statusPopoverOpen, appearancePopoverOpen>>

ToggleStatusPopover ==
    /\ StatusReachable
    /\ statusPopoverOpen' = ~statusPopoverOpen
    /\ appearancePopoverOpen' = IF statusPopoverOpen' THEN FALSE ELSE appearancePopoverOpen
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle,
                   brandInToolbar, statusInToolbar, appearanceInToolbar>>

ToggleAppearancePopover ==
    /\ AppearanceReachable
    /\ appearancePopoverOpen' = ~appearancePopoverOpen
    /\ statusPopoverOpen' = IF appearancePopoverOpen' THEN FALSE ELSE statusPopoverOpen
    /\ UNCHANGED <<widthClass, activeMode, toolbarOwner, toolbarStyle,
                   brandInToolbar, statusInToolbar, appearanceInToolbar>>

Next ==
    \/ \E w \in WidthClasses : ResizeWindow(w)
    \/ \E m \in Modes : SelectMode(m)
    \/ ToggleStatusPopover
    \/ ToggleAppearancePopover

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ widthClass \in WidthClasses
    /\ activeMode \in Modes
    /\ toolbarOwner \in ToolbarOwners
    /\ toolbarStyle \in ToolbarStyles
    /\ brandInToolbar \in BOOLEAN
    /\ statusInToolbar \in BOOLEAN
    /\ appearanceInToolbar \in BOOLEAN
    /\ statusPopoverOpen \in BOOLEAN
    /\ appearancePopoverOpen \in BOOLEAN

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
=============================================================================
