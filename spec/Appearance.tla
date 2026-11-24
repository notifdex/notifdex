--------------------------- MODULE Appearance ---------------------------
CONSTANTS Themes, DefaultTheme

Surfaces == {"clearGlass", "ambientGlass", "customImage", "standard"}

VARIABLES surface, theme, hasCustomBackdrop, reduceTransparency, increaseContrast, action
vars == <<surface, theme, hasCustomBackdrop, reduceTransparency, increaseContrast, action>>

UsesGlass ==
    surface # "standard" /\ ~reduceTransparency /\ ~increaseContrast

RequestsTransparentWindow ==
    (surface = "clearGlass" \/ (surface = "customImage" /\ ~hasCustomBackdrop))
    /\ ~reduceTransparency
    /\ ~increaseContrast

AppliesSolidPigment ==
    surface = "standard" /\ ~increaseContrast

Init ==
    /\ surface = "clearGlass"
    /\ theme = DefaultTheme
    /\ hasCustomBackdrop = FALSE
    /\ reduceTransparency = FALSE
    /\ increaseContrast = FALSE
    /\ action = "init"

SelectSurface(s) ==
    /\ s \in Surfaces
    /\ surface' = s
    /\ action' = "select_surface"
    /\ UNCHANGED <<theme, hasCustomBackdrop, reduceTransparency, increaseContrast>>

SelectTheme(t) ==
    /\ t \in Themes
    /\ theme' = t
    /\ action' = "select_theme"
    /\ UNCHANGED <<surface, hasCustomBackdrop, reduceTransparency, increaseContrast>>

ImportBackdrop ==
    /\ hasCustomBackdrop' = TRUE
    /\ surface' = "customImage"
    /\ action' = "import_backdrop"
    /\ UNCHANGED <<theme, reduceTransparency, increaseContrast>>

RemoveBackdrop ==
    /\ hasCustomBackdrop
    /\ hasCustomBackdrop' = FALSE
    /\ surface' = IF surface = "customImage" THEN "clearGlass" ELSE surface
    /\ action' = "remove_backdrop"
    /\ UNCHANGED <<theme, reduceTransparency, increaseContrast>>

ToggleReduceTransparency ==
    /\ reduceTransparency' = ~reduceTransparency
    /\ action' = "toggle_accessibility"
    /\ UNCHANGED <<surface, theme, hasCustomBackdrop, increaseContrast>>

ToggleIncreaseContrast ==
    /\ increaseContrast' = ~increaseContrast
    /\ action' = "toggle_accessibility"
    /\ UNCHANGED <<surface, theme, hasCustomBackdrop, reduceTransparency>>

Next ==
    \/ \E s \in Surfaces : SelectSurface(s)
    \/ \E t \in Themes : SelectTheme(t)
    \/ ImportBackdrop
    \/ RemoveBackdrop
    \/ ToggleReduceTransparency
    \/ ToggleIncreaseContrast

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ surface \in Surfaces
    /\ theme \in Themes
    /\ hasCustomBackdrop \in BOOLEAN
    /\ reduceTransparency \in BOOLEAN
    /\ increaseContrast \in BOOLEAN

SolidNeverTransparent ==
    surface = "standard" => (~UsesGlass /\ ~RequestsTransparentWindow)

AccessibilityForcesOpaque ==
    (reduceTransparency \/ increaseContrast) => (~UsesGlass /\ ~RequestsTransparentWindow)

SolidAppliesPigmentUnlessHighContrast ==
    (surface = "standard" /\ ~increaseContrast) => AppliesSolidPigment

OrthogonalPreferences == [][
    /\ (action' = "select_theme") => (surface' = surface /\ hasCustomBackdrop' = hasCustomBackdrop)
    /\ (action' = "select_surface") => (theme' = theme /\ hasCustomBackdrop' = hasCustomBackdrop)
    /\ (action' = "import_backdrop") => (theme' = theme /\ surface' = "customImage" /\ hasCustomBackdrop' = TRUE)
    /\ (action' = "remove_backdrop") => (
           theme' = theme
        /\ ~hasCustomBackdrop'
        /\ (surface = "customImage" => surface' = "clearGlass")
        /\ (surface # "customImage" => surface' = surface)
       )
    /\ (action' = "toggle_accessibility") => (surface' = surface /\ theme' = theme /\ hasCustomBackdrop' = hasCustomBackdrop)
    ]_vars
=============================================================================
