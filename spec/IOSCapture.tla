----------------------------- MODULE IOSCapture -----------------------------
EXTENDS FiniteSets

CONSTANTS Apps, Events, NoEvent, AppX, AppGmail, EvX, EvGmail

AppOf(e) == IF e = EvX THEN AppX ELSE AppGmail

Results == {"none", "captured", "duplicate", "skipped", "failed"}

VARIABLES selectedApps, configuredAutomations, verifiedApps, paused,
          inFlight, stored, acknowledged, lastResult

vars == <<selectedApps, configuredAutomations, verifiedApps, paused,
          inFlight, stored, acknowledged, lastResult>>

Init ==
    /\ selectedApps = {AppX, AppGmail}
    /\ configuredAutomations = {}
    /\ verifiedApps = {}
    /\ paused = FALSE
    /\ inFlight = NoEvent
    /\ stored = {}
    /\ acknowledged = {}
    /\ lastResult = "none"

\* User toggles an app inside Notifdex iOS.
\* Selecting an app never configures or verifies an Apple Shortcuts automation.
ToggleSelectedApp(a) ==
    /\ a \in Apps
    /\ selectedApps' = IF a \in selectedApps
                       THEN selectedApps \ {a}
                       ELSE selectedApps \cup {a}
    /\ UNCHANGED <<configuredAutomations, verifiedApps, paused, inFlight,
                   stored, acknowledged, lastResult>>

\* User toggles global capture pause inside Notifdex iOS.
SetPaused(b) ==
    /\ b \in BOOLEAN
    /\ b # paused
    /\ paused' = b
    /\ UNCHANGED <<selectedApps, configuredAutomations, verifiedApps,
                   inFlight, stored, acknowledged, lastResult>>

\* External user action in Apple's Shortcuts app (unobservable by Notifdex).
ConfigureAutomation(a) ==
    /\ a \in Apps
    /\ a \notin configuredAutomations
    /\ configuredAutomations' = configuredAutomations \cup {a}
    /\ UNCHANGED <<selectedApps, verifiedApps, paused, inFlight,
                   stored, acknowledged, lastResult>>

DisableAutomation(a) ==
    /\ a \in configuredAutomations
    /\ configuredAutomations' = configuredAutomations \ {a}
    /\ UNCHANGED <<selectedApps, verifiedApps, paused, inFlight,
                   stored, acknowledged, lastResult>>

\* Shortcuts invokes CaptureNotificationIntent for an app whose automation is enabled.
ShortcutInvoke(e) ==
    /\ e \in Events
    /\ inFlight = NoEvent
    /\ AppOf(e) \in configuredAutomations
    /\ inFlight' = e
    /\ verifiedApps' = verifiedApps \cup {AppOf(e)}
    /\ UNCHANGED <<selectedApps, configuredAutomations, paused,
                   stored, acknowledged, lastResult>>

\* App Intent checks in-app pause and per-app allowlist before writing to SQLite.
IntentSkip ==
    /\ inFlight # NoEvent
    /\ (paused \/ AppOf(inFlight) \notin selectedApps)
    /\ inFlight' = NoEvent
    /\ lastResult' = "skipped"
    /\ UNCHANGED <<selectedApps, configuredAutomations, verifiedApps,
                   paused, stored, acknowledged>>

\* App Intent commits a brand-new notification durably to SQLite.
IntentCommitNew ==
    /\ inFlight # NoEvent
    /\ ~paused
    /\ AppOf(inFlight) \in selectedApps
    /\ inFlight \notin stored
    /\ stored' = stored \cup {inFlight}
    /\ acknowledged' = acknowledged \cup {inFlight}
    /\ inFlight' = NoEvent
    /\ lastResult' = "captured"
    /\ UNCHANGED <<selectedApps, configuredAutomations, verifiedApps, paused>>

\* Duplicate delivery / retry of an already stored notification is idempotent.
IntentCommitDuplicate ==
    /\ inFlight # NoEvent
    /\ ~paused
    /\ AppOf(inFlight) \in selectedApps
    /\ inFlight \in stored
    /\ acknowledged' = acknowledged \cup {inFlight}
    /\ inFlight' = NoEvent
    /\ lastResult' = "duplicate"
    /\ UNCHANGED <<selectedApps, configuredAutomations, verifiedApps, paused, stored>>

\* Storage write failure (e.g., locked filesystem / SQLite error):
\* nothing is stored and the event is never acknowledged as captured.
IntentCommitFail ==
    /\ inFlight # NoEvent
    /\ ~paused
    /\ AppOf(inFlight) \in selectedApps
    /\ inFlight \notin stored
    /\ inFlight' = NoEvent
    /\ lastResult' = "failed"
    /\ UNCHANGED <<selectedApps, configuredAutomations, verifiedApps,
                   paused, stored, acknowledged>>

Next ==
    \/ \E a \in Apps : ToggleSelectedApp(a)
    \/ \E b \in BOOLEAN : SetPaused(b)
    \/ \E a \in Apps : ConfigureAutomation(a)
    \/ \E a \in Apps : DisableAutomation(a)
    \/ \E e \in Events : ShortcutInvoke(e)
    \/ IntentSkip
    \/ IntentCommitNew
    \/ IntentCommitDuplicate
    \/ IntentCommitFail

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ selectedApps \subseteq Apps
    /\ configuredAutomations \subseteq Apps
    /\ verifiedApps \subseteq Apps
    /\ paused \in BOOLEAN
    /\ inFlight \in Events \cup {NoEvent}
    /\ stored \subseteq Events
    /\ acknowledged \subseteq Events
    /\ lastResult \in Results

\* Never claim a notification was captured unless it was durably committed.
AcknowledgedIsDurable == acknowledged \subseteq stored

\* Stored observations only ever belong to apps that actually delivered via Shortcuts.
StoredImpliesVerifiedApp ==
    \A e \in stored : AppOf(e) \in verifiedApps

\* Committed observations never vanish when apps are toggled, paused, or disabled.
DurableNeverDisappears == [][stored \subseteq stored']_vars

\* Skipped or failed intent executions never mutate committed storage.
SkipAndFailNeverWrite == [][
    ((inFlight # NoEvent /\ inFlight' = NoEvent /\ lastResult' \in {"skipped", "failed"})
        => (stored' = stored /\ acknowledged' = acknowledged))
    /\ ((inFlight # NoEvent /\ inFlight' = NoEvent /\ (paused \/ AppOf(inFlight) \notin selectedApps))
        => (stored' = stored /\ lastResult' = "skipped"))
    ]_vars

\* Toggling app selections in Notifdex never fabricates Shortcuts verification.
ToggleNeverFabricatesVerification == [][
    (selectedApps' # selectedApps) => (verifiedApps' = verifiedApps /\ stored' = stored)
    ]_vars
=============================================================================
