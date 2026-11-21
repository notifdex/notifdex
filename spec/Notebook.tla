---------------------------- MODULE Notebook ----------------------------
CONSTANTS Folders, Notes, Missing, Unfiled
VARIABLES folders, notes
vars == <<folders, notes>>

Init ==
    /\ folders = {}
    /\ notes = [n \in Notes |-> Missing]

CreateFolder(f) ==
    /\ f \notin folders
    /\ folders' = folders \cup {f}
    /\ UNCHANGED notes

DeleteFolder(f) ==
    /\ f \in folders
    /\ folders' = folders \ {f}
    /\ notes' = [n \in Notes |-> IF notes[n] = f THEN Unfiled ELSE notes[n]]

Save(n, f) ==
    /\ f \in folders \cup {Unfiled}
    /\ notes' = [notes EXCEPT ![n] = f]
    /\ UNCHANGED folders

DeleteNote(n) ==
    /\ notes[n] # Missing
    /\ notes' = [notes EXCEPT ![n] = Missing]
    /\ UNCHANGED folders

Next ==
    \/ \E f \in Folders: CreateFolder(f) \/ DeleteFolder(f)
    \/ \E n \in Notes: DeleteNote(n) \/ (\E f \in Folders \cup {Unfiled}: Save(n, f))

Spec == Init /\ [][Next]_vars

ValidFolders ==
    /\ folders \subseteq Folders
    /\ notes \in [Notes -> folders \cup {Missing, Unfiled}]

FolderChangesKeepNotes == [][
    folders' # folders => \A n \in Notes: (notes[n] = Missing) = (notes'[n] = Missing)
]_vars
=========================================================================
