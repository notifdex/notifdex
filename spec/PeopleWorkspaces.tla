------------------------- MODULE PeopleWorkspaces -------------------------
CONSTANTS People, Workspaces, Alerts, Empty

VARIABLES available, members, routes, links, operation
durable == <<available, members, routes, links>>
vars == <<durable, operation>>

Init ==
    /\ available = {}
    /\ members = {}
    /\ routes = [a \in Alerts |-> Empty]
    /\ links = [a \in Alerts |-> Empty]
    /\ operation = "start"

Create(w) ==
    /\ available' = available \cup {w}
    /\ UNCHANGED <<members, routes, links>>
    /\ operation' = "create"

SetMember(p, w, enabled) ==
    /\ w \in available
    /\ members' = IF enabled THEN members \cup {<<p,w>>} ELSE members \ {<<p,w>>}
    /\ UNCHANGED <<available, routes, links>>
    /\ operation' = "member"

Route(a, w) ==
    /\ w \in available \cup {Empty}
    /\ routes' = [routes EXCEPT ![a] = w]
    /\ UNCHANGED <<available, members, links>>
    /\ operation' = "route"

Link(a, p) ==
    /\ p \in People \cup {Empty}
    /\ links' = [links EXCEPT ![a] = p]
    /\ UNCHANGED <<available, members, routes>>
    /\ operation' = "link"

FailedWrite ==
    /\ UNCHANGED durable
    /\ operation' = "failure"

Next ==
    \/ \E w \in Workspaces : Create(w)
    \/ \E p \in People, w \in Workspaces, b \in BOOLEAN : SetMember(p, w, b)
    \/ \E a \in Alerts, w \in Workspaces \cup {Empty} : Route(a, w)
    \/ \E a \in Alerts, p \in People \cup {Empty} : Link(a, p)
    \/ FailedWrite

Spec == Init /\ [][Next]_vars

ValidReferences ==
    /\ available \subseteq Workspaces
    /\ members \subseteq People \X available
    /\ routes \in [Alerts -> available \cup {Empty}]
    /\ links \in [Alerts -> People \cup {Empty}]

PeopleIn(w) == IF w = Empty THEN People ELSE {p \in People : <<p,w>> \in members}
Timeline(p, w) ==
    IF p \in PeopleIn(w)
    THEN {a \in Alerts : links[a] = p /\ (w = Empty \/ routes[a] \in {w, Empty})}
    ELSE {}

ScopedTimeline ==
    \A w \in Workspaces, p \in People : \A a \in Timeline(p, w) :
        /\ <<p,w>> \in members
        /\ links[a] = p
        /\ routes[a] \in {w, Empty}
        /\ a \in Timeline(p, Empty)

TimelineComplete ==
    \A w \in Workspaces, p \in People, a \in Alerts :
        (<<p,w>> \in members /\ links[a] = p /\ routes[a] \in {w, Empty}) =>
            a \in Timeline(p, w)

CrossPersonWorkspaceIsolation ==
    \A w \in Workspaces \cup {Empty}, p1 \in People, p2 \in People :
        p1 # p2 => Timeline(p1, w) \cap Timeline(p2, w) = {}

IndependentChanges == [][
    /\ available \subseteq available'
    /\ operation' = "member" => UNCHANGED <<routes, links>>
    /\ operation' = "route" => UNCHANGED <<members, links>>
    /\ operation' = "link" => UNCHANGED <<available, members, routes>>
    /\ operation' = "failure" => UNCHANGED durable
    ]_vars
=============================================================================
