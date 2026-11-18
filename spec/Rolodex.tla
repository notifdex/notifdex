------------------------------ MODULE Rolodex ------------------------------
EXTENDS TLC
CONSTANTS Alerts, People, DueDates
VARIABLES saved, links, tasks, done

vars == <<saved, links, tasks, done>>
NoLink == "unassigned"
NoTask == "unscheduled"

Init ==
    /\ saved = {}
    /\ links = [a \in Alerts |-> NoLink]
    /\ tasks = [a \in Alerts |-> NoTask]
    /\ done = {}

SetSaved(a, enabled) ==
    /\ saved' = IF enabled THEN saved \cup {a} ELSE saved \ {a}
    /\ UNCHANGED <<links, tasks, done>>

Link(a, p) ==
    /\ links' = [links EXCEPT ![a] = p]
    /\ UNCHANGED <<saved, tasks, done>>

Schedule(a, due) ==
    /\ tasks' = [tasks EXCEPT ![a] = due]
    /\ done' = done \ {a}
    /\ UNCHANGED <<saved, links>>

Complete(a) ==
    /\ tasks[a] # NoTask
    /\ done' = done \cup {a}
    /\ UNCHANGED <<saved, links, tasks>>

Next ==
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
CompleteRequiresSchedule == \A a \in done : tasks[a] # NoTask
=============================================================================
