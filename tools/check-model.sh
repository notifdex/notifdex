#!/usr/bin/env bash
set -euo pipefail
: "${TLA_JAR:?Set TLA_JAR to a local tla2tools.jar path}"
cd "$(dirname "$0")/../spec"

checked=()
run_tlc() {
    local cfg="$1"
    local tla="$2"
    checked+=("$cfg")
    echo "==> TLC: $cfg ($tla)"
    java -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 1 -config "$cfg" "$tla"
}

run_tlc Capture.cfg Capture.tla
run_tlc Progress.cfg Capture.tla
run_tlc Recovery.cfg Capture.tla
run_tlc AppRecovery.cfg AppRecovery.tla
run_tlc CollectorLifecycle.cfg CollectorLifecycle.tla
run_tlc InboxWorkflow.cfg InboxWorkflow.tla
run_tlc InboxSelection.cfg InboxSelection.tla
run_tlc PersonMatch.cfg PersonMatch.tla
run_tlc PersonNotes.cfg PersonNotes.tla
run_tlc RelationshipTemplates.cfg RelationshipTemplates.tla
run_tlc PeopleWorkspaces.cfg PeopleWorkspaces.tla
run_tlc Notebook.cfg Notebook.tla

# Verify every .cfg file in spec/ was checked so new models can never silently skip CI.
for cfg in *.cfg; do
    found=0
    for ran in "${checked[@]}"; do
        if [[ "$ran" == "$cfg" ]]; then
            found=1
            break
        fi
    done
    if [[ "$found" -ne 1 ]]; then
        echo "ERROR: spec/$cfg is not executed by tools/check-model.sh" >&2
        exit 1
    fi
done
echo "All ${#checked[@]} TLC model configurations verified."
