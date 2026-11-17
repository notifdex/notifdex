# Formal model and implementation correspondence

`spec/Capture.tla` has two executable TLC configurations. Both use two abstract
event revisions. Larger instances can be checked by changing `Events` in a copy
of the configuration. Checking one finite instance establishes the listed
properties for that instance and abstraction. It does not establish arbitrary
OS behavior, runtime correctness, cryptographic identity, or indefinite hardware durability.

| Model | Implementation/assumption | Verification |
| --- | --- | --- |
| `Events` | Source/banner/rendering tuples, each abstracted to one symbol | SQL uniqueness, different IDs/revisions/source tests |
| `visible` | UI available to collector | `Show`/`Hide` arbitrary; real adapter tests required |
| `pending` | Snapshot in volatile memory | Process crash may discard it |
| `stored` | Committed observations | SQLite transaction, WAL, FULL; process-death/reopen tests |
| `acknowledged` | Successful return / saved status | Print only after record returns successfully |
| `running` | Collector lifecycle | Crash/restart; durable heartbeat bounds gap |
| `accessible` | Combined availability of UI/permissions/polling | Suspend/restore abstraction; no inferred phone state |
| `gap` | Active interruption requiring scan | Historical intervals persist separately in SQLite |
| `Scan` | One successful local UI snapshot | Empty success leaves upstream completeness unknown |

## Safety

- `TypeOK` bounds all state to the configured events and booleans.
- `AcknowledgedIsDurable` requires acknowledgements to refer to committed evidence.
- `DurableNeverDisappears` checks that stored observations survive every modeled action.
- `UnavailableIsMarked` requires an active gap whenever capture is stopped,
  unavailable, or awaiting a recovery scan.

Set-valued storage abstracts effect idempotence. The implementation's UNIQUE
constraint is independently tested, since the abstract set cannot represent
duplicate database rows. Individual transactions map to atomic `Commit(e)`.
Disk-write failure is a stuttering step followed by an error/exit, with no
acknowledgement. Source events hidden before scanning may disappear forever.
Observations read into RAM can also be lost before durable commit. The model
deliberately allows that loss.

The invariant refers to abstract failures visible to the model. An actual crash
cannot synchronously write a gap. The implementation records an unclean interval
on the next successful startup. An external UI observing a dead process must
also treat its heartbeat as stale. Phone power and Focus are not observable
model inputs in this milestone, so they never produce invented certainty.

## Conditional progress

`Progress.cfg` starts with both events visible and checks that both eventually
reach durable storage. The environment then stays running and accessible, and
each continuously enabled scan/commit receives weak fairness. Real storage
must eventually succeed and the collector must keep running for this claim to
apply. `Capture.cfg` permits repeated crashes and hides, so it asserts safety
without unconditional eventual capture.

## TDD and refinement workflow

For the next change, write a failing contract test, identify the model transition
and assumption it changes, run TLC, implement the smallest passing change, then
run the full suite. An adapter bug needs a synthetic Accessibility fixture plus
a regression test, followed by an actual device acceptance trace. Keep proofs
about committed evidence distinct from tests about delivery/visibility.

Foundation validation in this workspace on 2026-11-17 found 224 reachable safety
states and 10 stable-progress states with no violation. The eight supplemental
SQLite tests passed, including process death during an uncommitted transaction.
Swift/macOS checks run in GitHub Actions because this workspace has no Swift SDK.
An acknowledgement-before-storage mutation of the model produced the expected
`AcknowledgedIsDurable` counterexample. The native NUL regression failed before
switching SQLite text bindings to explicit UTF-8 byte lengths.
