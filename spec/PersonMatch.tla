--------------------------- MODULE PersonMatch ---------------------------
EXTENDS TLC
CONSTANTS Alerts, People, SameTitleAndApp
VARIABLES seen, manual, rule, eligible

vars == <<seen, manual, rule, eligible>>
None == "none"
Skip == "skip"

Init ==
    /\ seen = {}
    /\ manual = [a \in Alerts |-> None]
    /\ rule = None
    /\ eligible = {}

Capture(a) ==
    /\ a \notin seen
    /\ seen' = seen \cup {a}
    /\ eligible' = IF rule # None THEN eligible \cup {a} ELSE eligible
    /\ UNCHANGED <<manual, rule>>

Confirm(p, backfill) ==
    /\ rule = None
    /\ (\E a \in seen \intersect SameTitleAndApp : manual[a] = p)
    /\ (\A a \in seen \intersect SameTitleAndApp : manual[a] \notin People \/ manual[a] = p)
    /\ rule' = p
    /\ eligible' = IF backfill THEN seen ELSE {}
    /\ UNCHANGED <<seen, manual>>

Remove ==
    /\ rule # None
    /\ rule' = None
    /\ eligible' = {}
    /\ UNCHANGED <<seen, manual>>

SetManual(a, p) ==
    /\ a \in seen
    /\ manual' = [manual EXCEPT ![a] = p]
    /\ UNCHANGED <<seen, rule, eligible>>

HasConflict ==
    \E a \in seen \intersect SameTitleAndApp : manual[a] \in People /\ manual[a] # rule

Resolved(a) ==
    IF manual[a] = Skip THEN None
    ELSE IF manual[a] # None THEN manual[a]
    ELSE IF a \in eligible \intersect SameTitleAndApp /\ ~HasConflict THEN rule ELSE None

Next ==
    \/ \E a \in Alerts : Capture(a)
    \/ \E p \in People, b \in BOOLEAN : Confirm(p, b)
    \/ Remove
    \/ \E a \in Alerts, p \in People \cup {Skip} : SetManual(a, p)

Spec == Init /\ [][Next]_vars
TypeOK ==
    /\ seen \subseteq Alerts
    /\ manual \in [Alerts -> People \cup {None, Skip}]
    /\ rule \in People \cup {None}
    /\ eligible \subseteq seen
    /\ rule = None => eligible = {}

ExplicitChoiceWins ==
    \A a \in seen :
        /\ manual[a] \in People => Resolved(a) = manual[a]
        /\ manual[a] = Skip => Resolved(a) = None

OnlyEligibleMatches ==
    \A a \in seen :
        manual[a] = None /\ Resolved(a) # None =>
            a \in SameTitleAndApp \intersect eligible /\ Resolved(a) = rule /\ ~HasConflict
===========================================================================
