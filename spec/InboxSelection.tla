------------------------- MODULE InboxSelection -------------------------
CONSTANTS Alerts, RuleMatches, NoAlert

Views == {"inbox", "unread", "flagged", "hidden"}

VARIABLES view, selected, readEntries, flags, hiddenEntries, ruleEnabled, lastHide, action
vars == <<view, selected, readEntries, flags, hiddenEntries, ruleEnabled, lastHide, action>>

RuleHidden(enabled) == IF enabled THEN RuleMatches ELSE {}
HiddenOf(h, enabled) == h \cup RuleHidden(enabled)
Hidden == HiddenOf(hiddenEntries, ruleEnabled)

RowsIn(v, r, f, h) ==
    CASE v = "inbox" -> Alerts \ h
      [] v = "unread" -> (Alerts \ h) \ r
      [] v = "flagged" -> (Alerts \ h) \cap f
      [] v = "hidden" -> h

SelectedAllowed(v, a, h) ==
    /\ a \in Alerts
    /\ IF v = "hidden" THEN a \in h ELSE a \notin h

ReconcileSelected(v, sel, h) ==
    IF sel # NoAlert /\ SelectedAllowed(v, sel, h) THEN sel ELSE NoAlert

Init ==
    /\ view = "inbox"
    /\ selected = NoAlert
    /\ readEntries = {}
    /\ flags = {}
    /\ hiddenEntries = {}
    /\ ruleEnabled = FALSE
    /\ lastHide = NoAlert
    /\ action = "init"

Select(a) ==
    /\ a \in RowsIn(view, readEntries, flags, Hidden)
    /\ selected' = a
    /\ action' = "select"
    /\ UNCHANGED <<view, readEntries, flags, hiddenEntries, ruleEnabled, lastHide>>

ClearSelection ==
    /\ selected # NoAlert
    /\ selected' = NoAlert
    /\ action' = "clear"
    /\ UNCHANGED <<view, readEntries, flags, hiddenEntries, ruleEnabled, lastHide>>

SwitchView(v) ==
    /\ v \in Views
    /\ v # view
    /\ view' = v
    /\ selected' = ReconcileSelected(v, selected, Hidden)
    /\ action' = "switch"
    /\ UNCHANGED <<readEntries, flags, hiddenEntries, ruleEnabled, lastHide>>

SetRead(a, b) ==
    /\ a \in Alerts
    /\ readEntries' = IF b THEN readEntries \cup {a} ELSE readEntries \ {a}
    /\ selected' = ReconcileSelected(view, selected, Hidden)
    /\ action' = IF b /\ a = selected THEN "mark_read_selected" ELSE "set_read"
    /\ UNCHANGED <<view, flags, hiddenEntries, ruleEnabled, lastHide>>

SetFlag(a, b) ==
    /\ a \in Alerts
    /\ flags' = IF b THEN flags \cup {a} ELSE flags \ {a}
    /\ selected' = ReconcileSelected(view, selected, Hidden)
    /\ action' = IF ~b /\ a = selected THEN "unflag_selected" ELSE "set_flag"
    /\ UNCHANGED <<view, readEntries, hiddenEntries, ruleEnabled, lastHide>>

HideAlert(a) ==
    /\ a \in Alerts
    /\ a \notin hiddenEntries
    /\ hiddenEntries' = hiddenEntries \cup {a}
    /\ lastHide' = a
    /\ selected' = ReconcileSelected(view, selected, HiddenOf(hiddenEntries', ruleEnabled))
    /\ action' = "hide"
    /\ UNCHANGED <<view, readEntries, flags, ruleEnabled>>

RestoreAlert(a) ==
    /\ a \in hiddenEntries
    /\ hiddenEntries' = hiddenEntries \ {a}
    /\ lastHide' = IF lastHide = a THEN NoAlert ELSE lastHide
    /\ selected' = ReconcileSelected(view, selected, HiddenOf(hiddenEntries', ruleEnabled))
    /\ action' = "restore"
    /\ UNCHANGED <<view, readEntries, flags, ruleEnabled>>

UndoLastHide ==
    /\ lastHide # NoAlert
    /\ hiddenEntries' = hiddenEntries \ {lastHide}
    /\ lastHide' = NoAlert
    /\ selected' = ReconcileSelected(view, selected, HiddenOf(hiddenEntries', ruleEnabled))
    /\ action' = "undo_hide"
    /\ UNCHANGED <<view, readEntries, flags, ruleEnabled>>

ToggleRule ==
    /\ ruleEnabled' = ~ruleEnabled
    /\ selected' = ReconcileSelected(view, selected, HiddenOf(hiddenEntries, ruleEnabled'))
    /\ action' = "rule"
    /\ UNCHANGED <<view, readEntries, flags, hiddenEntries, lastHide>>

Next ==
    \/ \E a \in Alerts : Select(a)
    \/ ClearSelection
    \/ \E v \in Views : SwitchView(v)
    \/ \E a \in Alerts, b \in BOOLEAN : SetRead(a, b)
    \/ \E a \in Alerts, b \in BOOLEAN : SetFlag(a, b)
    \/ \E a \in Alerts : HideAlert(a)
    \/ \E a \in Alerts : RestoreAlert(a)
    \/ UndoLastHide
    \/ ToggleRule

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ view \in Views
    /\ selected \in Alerts \cup {NoAlert}
    /\ readEntries \subseteq Alerts
    /\ flags \subseteq Alerts
    /\ hiddenEntries \subseteq Alerts
    /\ ruleEnabled \in BOOLEAN
    /\ lastHide \in Alerts \cup {NoAlert}

SelectedNeverHiddenInVisibleViews ==
    (view # "hidden" /\ selected # NoAlert) => selected \notin Hidden

SelectedAlwaysHiddenInHiddenView ==
    (view = "hidden" /\ selected # NoAlert) => selected \in Hidden

LastHideIsHidden ==
    lastHide # NoAlert => lastHide \in hiddenEntries

DetailContinuity == [][
    /\ (selected # NoAlert /\ view = "flagged" /\ action' = "unflag_selected") => selected' = selected
    /\ (selected # NoAlert /\ view = "unread" /\ action' = "mark_read_selected") => selected' = selected
    /\ (selected # NoAlert /\ view # "hidden" /\ selected \in Hidden') => selected' = NoAlert
    /\ (action' = "undo_hide") => (lastHide \notin hiddenEntries' /\ lastHide' = NoAlert)
    ]_vars
=============================================================================
