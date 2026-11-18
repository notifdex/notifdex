------------------------------ MODULE InboxWorkflow ------------------------------
EXTENDS TLC
CONSTANTS Alerts, People, DueDates, TitleMatches, BodyMatches
VARIABLES saved, links, tasks, done, enabledRules, hiddenEntries, readEntries, flags

vars == <<saved, links, tasks, done, enabledRules, hiddenEntries, readEntries, flags>>
NoLink == "unassigned"
NoTask == "unscheduled"
RuleFields == {"title", "body"}

Init ==
    /\ saved = {}
    /\ links = [a \in Alerts |-> NoLink]
    /\ tasks = [a \in Alerts |-> NoTask]
    /\ done = {}
    /\ enabledRules = {}
    /\ hiddenEntries = {}
    /\ readEntries = {}
    /\ flags = {}

SetSaved(a, enabled) ==
    /\ saved' = IF enabled THEN saved \cup {a} ELSE saved \ {a}
    /\ UNCHANGED <<links, tasks, done, enabledRules, hiddenEntries, readEntries, flags>>

Link(a, p) ==
    /\ links' = [links EXCEPT ![a] = p]
    /\ UNCHANGED <<saved, tasks, done, enabledRules, hiddenEntries, readEntries, flags>>

Schedule(a, due) ==
    /\ tasks' = [tasks EXCEPT ![a] = due]
    /\ done' = done \ {a}
    /\ UNCHANGED <<saved, links, enabledRules, hiddenEntries, readEntries, flags>>

Complete(a) ==
    /\ tasks[a] # NoTask
    /\ done' = done \cup {a}
    /\ UNCHANGED <<saved, links, tasks, enabledRules, hiddenEntries, readEntries, flags>>

SetRule(field, enabled) ==
    /\ enabledRules' = IF enabled THEN enabledRules \cup {field} ELSE enabledRules \ {field}
    /\ UNCHANGED <<saved, links, tasks, done, hiddenEntries, readEntries, flags>>

SetHidden(a, enabled) ==
    /\ hiddenEntries' = IF enabled THEN hiddenEntries \cup {a} ELSE hiddenEntries \ {a}
    /\ UNCHANGED <<saved, links, tasks, done, enabledRules, readEntries, flags>>

SetRead(a, enabled) ==
    /\ readEntries' = IF enabled THEN readEntries \cup {a} ELSE readEntries \ {a}
    /\ UNCHANGED <<saved, links, tasks, done, enabledRules, hiddenEntries, flags>>

SetFlag(a, enabled) ==
    /\ flags' = IF enabled THEN flags \cup {a} ELSE flags \ {a}
    /\ UNCHANGED <<saved, links, tasks, done, enabledRules, hiddenEntries, readEntries>>

TitleHidden == IF "title" \in enabledRules THEN TitleMatches ELSE {}
BodyHidden == IF "body" \in enabledRules THEN BodyMatches ELSE {}
Hidden == hiddenEntries \cup TitleHidden \cup BodyHidden
Visible == Alerts \ Hidden
Flagged == flags \cap Visible
Read(items) == items \cap readEntries
Unread(items) == items \ readEntries
Next ==
    \/ \E field \in RuleFields, b \in BOOLEAN : SetRule(field, b)
    \/ \E a \in Alerts, b \in BOOLEAN : SetFlag(a, b)
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
    /\ enabledRules \subseteq RuleFields
    /\ hiddenEntries \subseteq Alerts
    /\ readEntries \subseteq Alerts
    /\ flags \subseteq Alerts
CompleteRequiresSchedule == \A a \in done : tasks[a] # NoTask
InboxPartition ==
    /\ Hidden \union Visible = Alerts
    /\ Hidden \intersect Visible = {}
    /\ Hidden \subseteq (TitleMatches \cup BodyMatches \cup hiddenEntries)
IndependentHideReasons ==
    [][
        /\ ("title" \in enabledRules /\ "title" \notin enabledRules'
            => hiddenEntries \cup BodyHidden \subseteq Hidden')
        /\ ("body" \in enabledRules /\ "body" \notin enabledRules'
            => hiddenEntries \cup TitleHidden \subseteq Hidden')
        ]_vars

FlaggedVisibility ==
    /\ Flagged \cap Hidden = {}
    /\ Flagged \cup (flags \cap Hidden) = flags

ReadPartition ==
    \A items \in {Visible, Flagged} :
        /\ Read(items) \cup Unread(items) = items
        /\ Read(items) \cap Unread(items) = {}

FlagStateIndependence ==
    [][(flags' # flags) => UNCHANGED <<readEntries, saved, links, tasks, done, Hidden>>]_vars
=============================================================================
