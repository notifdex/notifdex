------------------------------ MODULE Rolodex ------------------------------
EXTENDS TLC
CONSTANTS Alerts, People, DueDates, Matches
VARIABLES saved, links, tasks, done, filterEnabled, hiddenEntries, readEntries

vars == <<saved, links, tasks, done, filterEnabled, hiddenEntries, readEntries>>
NoLink == "unassigned"
NoTask == "unscheduled"

Init ==
    /\ saved = {}
    /\ links = [a \in Alerts |-> NoLink]
    /\ tasks = [a \in Alerts |-> NoTask]
    /\ done = {}
    /\ filterEnabled = FALSE
    /\ hiddenEntries = {}
    /\ readEntries = {}

SetSaved(a, enabled) ==
    /\ saved' = IF enabled THEN saved \cup {a} ELSE saved \ {a}
    /\ UNCHANGED <<links, tasks, done, filterEnabled, hiddenEntries, readEntries>>

Link(a, p) ==
    /\ links' = [links EXCEPT ![a] = p]
    /\ UNCHANGED <<saved, tasks, done, filterEnabled, hiddenEntries, readEntries>>

Schedule(a, due) ==
    /\ tasks' = [tasks EXCEPT ![a] = due]
    /\ done' = done \ {a}
    /\ UNCHANGED <<saved, links, filterEnabled, hiddenEntries, readEntries>>

Complete(a) ==
    /\ tasks[a] # NoTask
    /\ done' = done \cup {a}
    /\ UNCHANGED <<saved, links, tasks, filterEnabled, hiddenEntries, readEntries>>

ToggleFilter ==
    /\ filterEnabled' = ~filterEnabled
    /\ UNCHANGED <<saved, links, tasks, done, hiddenEntries, readEntries>>

SetHidden(a, enabled) ==
    /\ hiddenEntries' = IF enabled THEN hiddenEntries \cup {a} ELSE hiddenEntries \ {a}
    /\ UNCHANGED <<saved, links, tasks, done, filterEnabled, readEntries>>

SetRead(a, enabled) ==
    /\ readEntries' = IF enabled THEN readEntries \cup {a} ELSE readEntries \ {a}
    /\ UNCHANGED <<saved, links, tasks, done, filterEnabled, hiddenEntries>>

Hidden == hiddenEntries \cup (IF filterEnabled THEN Matches ELSE {})
Visible == Alerts \ Hidden
Next ==
    \/ ToggleFilter
    \/ \E a \in Alerts, b \in BOOLEAN : SetRead(a, b)
    \/ \E a \in Alerts, b \in BOOLEAN : SetHidden(a, b)
    \/ \E a \in Alerts, b \in BOOLEAN : SetSaved(a, b)
    \/ \E a \in Alerts, p \in People \cup {NoLink} : Link(a, p)
    \/ \E a \in Alerts, d \in DueDates : Schedule(a, d)
    \/ \E a \in Alerts : Complete(a)

Spec == Init /\ [][Next]_vars
TypeOK ==
    /\ saved \subseteq Alerts
    /\ links \in [Alerts -> People \cup {NoLink}]
    /\ tasks \in [Alerts -> DueDates \cup {NoTask}]
    /\ done \subseteq Alerts
    /\ filterEnabled \in BOOLEAN
    /\ hiddenEntries \subseteq Alerts
    /\ readEntries \subseteq Alerts
CompleteRequiresSchedule == \A a \in done : tasks[a] # NoTask
InboxPartition ==
    /\ Hidden \union Visible = Alerts
    /\ Hidden \intersect Visible = {}
    /\ Hidden \subseteq (Matches \cup hiddenEntries)
=============================================================================
