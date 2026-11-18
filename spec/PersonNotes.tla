-------------------------- MODULE PersonNotes --------------------------
CONSTANTS People, Notes, Bodies, Missing
VARIABLE notes

Init == notes = [n \in Notes |-> [owner |-> Missing, body |-> Missing]]

Add(p, n, b) ==
    /\ notes[n].owner = Missing
    /\ notes' = [notes EXCEPT ![n] = [owner |-> p, body |-> b]]

Edit(p, n, b) ==
    /\ notes[n].owner = p
    /\ notes' = [notes EXCEPT ![n].body = b]

Remove(p, n) ==
    /\ notes[n].owner = p
    /\ notes' = [notes EXCEPT ![n] = [owner |-> Missing, body |-> Missing]]

Next ==
    \E p \in People, n \in Notes:
        Remove(p, n) \/ (\E b \in Bodies: Add(p, n, b) \/ Edit(p, n, b))

Spec == Init /\ [][Next]_notes

ValidNotes ==
    \A n \in Notes:
        \/ notes[n] = [owner |-> Missing, body |-> Missing]
        \/ notes[n] \in [owner : People, body : Bodies]

StableOwner == [][\A n \in Notes:
    (notes[n].owner # Missing /\ notes'[n].owner # Missing)
        => notes[n].owner = notes'[n].owner]_notes
=========================================================================
