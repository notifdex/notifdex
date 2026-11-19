------------------------- MODULE PeopleWorkspaces -------------------------
CONSTANTS People, Workspaces, Alerts, Linked, Empty
ExampleLinks == [a \in Alerts |-> CHOOSE p \in People : TRUE]

VARIABLES available, members, routes, operation
durable == <<available, members, routes>>
vars == <<durable, operation>>

Init ==
    /\ available = {}
    /\ members = {}
    /\ routes = [a \in Alerts |-> Empty]
    /\ operation = "start"

Create(w) ==
    /\ available' = available \cup {w}
    /\ UNCHANGED <<members, routes>>
    /\ operation' = "create"

SetMember(p, w, enabled) ==
    /\ w \in available
    /\ members' = IF enabled THEN members \cup {<<p,w>>} ELSE members \ {<<p,w>>}
    /\ UNCHANGED <<available, routes>>
    /\ operation' = "member"

Route(a, w) ==
    /\ w \in available \cup {Empty}
    /\ routes' = [routes EXCEPT ![a] = w]
    /\ UNCHANGED <<available, members>>
    /\ operation' = "route"

FailedWrite ==
    /\ UNCHANGED durable
    /\ operation' = "failure"

Next ==
    \/ \E w \in Workspaces : Create(w)
    \/ \E p \in People, w \in Workspaces, b \in BOOLEAN : SetMember(p, w, b)
    \/ \E a \in Alerts, w \in Workspaces \cup {Empty} : Route(a, w)
    \/ FailedWrite

Spec == Init /\ [][Next]_vars

ValidReferences ==
    /\ available \subseteq Workspaces
    /\ members \subseteq People \X available
    /\ routes \in [Alerts -> available \cup {Empty}]

PeopleIn(w) == IF w = Empty THEN People ELSE {p \in People : <<p,w>> \in members}
Timeline(p, w) ==
    IF p \in PeopleIn(w)
    THEN {a \in Alerts : Linked[a] = p /\ (w = Empty \/ routes[a] \in {w, Empty})}
    ELSE {}

ScopedTimeline ==
    \A w \in Workspaces, p \in People : \A a \in Timeline(p, w) :
        /\ <<p,w>> \in members
        /\ routes[a] \in {w, Empty}
        /\ a \in Timeline(p, Empty)

TimelineComplete ==
    \A w \in Workspaces, p \in People, a \in Alerts :
        (<<p,w>> \in members /\ Linked[a] = p /\ routes[a] \in {w, Empty}) =>
            a \in Timeline(p, w)

IndependentChanges == [][
    /\ available \subseteq available'
    /\ operation' = "member" => UNCHANGED routes
    /\ operation' = "route" => UNCHANGED members
    /\ operation' = "failure" => UNCHANGED durable
    ]_vars
=============================================================================
