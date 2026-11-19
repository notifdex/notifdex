----------------------- MODULE RelationshipTemplates -----------------------
EXTENDS Naturals, FiniteSets

CONSTANTS People, Versions, Definitions, Stages, Milestones, InitialStage, Empty
VARIABLES installed, assignments, stage, milestones, operation
durable == <<installed, assignments, stage, milestones>>
vars == <<durable, operation>>

Init ==
    /\ operation = "none"
    /\ installed = [v \in Versions |-> Empty]
    /\ assignments = [p \in People |-> Empty]
    /\ stage = [p \in People |-> Empty]
    /\ milestones = [p \in People |-> Empty]

Install(v, d) ==
    /\ operation' = "install"
    /\ installed' = IF installed[v] = Empty THEN [installed EXCEPT ![v] = d] ELSE installed
    /\ UNCHANGED <<assignments, stage, milestones>>

Apply(p, v) ==
    /\ operation' = "apply"
    /\ installed[v] # Empty
    /\ IF assignments[p] = Empty
          THEN /\ assignments' = [assignments EXCEPT ![p] = v]
               /\ stage' = [stage EXCEPT ![p] = InitialStage]
               /\ milestones' = [milestones EXCEPT ![p] = [m \in Milestones |-> FALSE]]
          ELSE UNCHANGED <<assignments, stage, milestones>>
    /\ UNCHANGED installed

SetStage(p, s) ==
    /\ operation' = "stage"
    /\ assignments[p] # Empty
    /\ stage' = [stage EXCEPT ![p] = s]
    /\ UNCHANGED <<installed, assignments, milestones>>

SetMilestone(p, m, completed) ==
    /\ operation' = "milestone"
    /\ assignments[p] # Empty
    /\ milestones' = [milestones EXCEPT ![p][m] = completed]
    /\ UNCHANGED <<installed, assignments, stage>>

Remove(p, v) ==
    /\ operation' = "remove"
    /\ IF assignments[p] = v
          THEN /\ assignments' = [assignments EXCEPT ![p] = Empty]
               /\ stage' = [stage EXCEPT ![p] = Empty]
               /\ milestones' = [milestones EXCEPT ![p] = Empty]
          ELSE UNCHANGED <<assignments, stage, milestones>>
    /\ UNCHANGED installed

FailedWrite ==
    /\ operation' = "failure"
    /\ UNCHANGED durable

Next ==
    \/ \E v \in Versions, d \in Definitions : Install(v, d)
    \/ \E p \in People, v \in Versions : Apply(p, v)
    \/ \E p \in People, s \in Stages : SetStage(p, s)
    \/ \E p \in People, m \in Milestones, b \in BOOLEAN : SetMilestone(p, m, b)
    \/ \E p \in People, v \in Versions : Remove(p, v)
    \/ FailedWrite

Spec == Init /\ [][Next]_vars

CompleteAssignments ==
    /\ installed \in [Versions -> Definitions \cup {Empty}]
    /\ assignments \in [People -> Versions \cup {Empty}]
    /\ \A p \in People :
          IF assignments[p] = Empty
             THEN stage[p] = Empty /\ milestones[p] = Empty
             ELSE /\ installed[assignments[p]] # Empty
                  /\ stage[p] \in Stages
                  /\ milestones[p] \in [Milestones -> BOOLEAN]

PreserveExisting ==
    /\ \A v \in Versions : installed[v] # Empty => installed'[v] = installed[v]
    /\ \A p \in People :
          assignments[p] # Empty =>
             /\ assignments'[p] = assignments[p] \/ (operation' = "remove" /\ assignments'[p] = Empty)
             /\ (operation' \in {"install", "apply", "failure"} \/
                  (operation' = "remove" /\ assignments'[p] # Empty)) =>
                   <<stage'[p], milestones'[p]>> = <<stage[p], milestones[p]>>

SafeSteps == [][
    /\ PreserveExisting
    /\ operation' = "remove" =>
          /\ UNCHANGED installed
          /\ Cardinality({p \in People : assignments'[p] # assignments[p]}) <= 1
          /\ \A p \in People : assignments'[p] # assignments[p] => assignments'[p] = Empty
    /\ operation' = "failure" => UNCHANGED durable
    /\ operation' = "stage" => UNCHANGED milestones
    /\ operation' = "milestone" => UNCHANGED stage
    ]_vars

=============================================================================
