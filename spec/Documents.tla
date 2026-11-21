--------------------------- MODULE Documents ---------------------------
CONSTANTS IDs, Revisions, Missing
VARIABLES documents, draft

vars == <<documents, draft>>
NoDraft == [id |-> Missing, revision |-> Missing]

Init ==
    /\ documents = [d \in IDs |-> Missing]
    /\ draft = NoDraft

Begin(d, r) ==
    /\ draft = NoDraft
    /\ draft' = [id |-> d, revision |-> r]
    /\ UNCHANGED documents

Cancel ==
    /\ draft # NoDraft
    /\ draft' = NoDraft
    /\ UNCHANGED documents

Save ==
    /\ draft # NoDraft
    /\ documents' = [documents EXCEPT ![draft.id] = draft.revision]
    /\ draft' = NoDraft

Remove(d) ==
    /\ draft = NoDraft
    /\ documents[d] # Missing
    /\ documents' = [documents EXCEPT ![d] = Missing]
    /\ UNCHANGED draft

Next ==
    \/ \E d \in IDs, r \in Revisions: Begin(d, r)
    \/ Cancel
    \/ Save
    \/ \E d \in IDs: Remove(d)

Spec == Init /\ [][Next]_vars

Valid ==
    /\ documents \in [IDs -> Revisions \cup {Missing}]
    /\ draft = NoDraft \/ draft \in [id : IDs, revision : Revisions]

OnlySavedDraftChangesDocument == [][
    draft # NoDraft /\ documents' # documents =>
        /\ draft' = NoDraft
        /\ documents' = [documents EXCEPT ![draft.id] = draft.revision]
]_vars
========================================================================
