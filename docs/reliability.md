# Capture coverage and recovery

The system guarantees transactional persistence for observations that reach its
successful commit path. SQLite runs with foreign keys, WAL, synchronous FULL,
and bounded lock waiting. A uniqueness constraint provides effect idempotence
for identical source/banner/rendering tuples. The OS controls notification delivery
and Accessibility exposure. Hardware/storage durability depends on the OS and device
honoring SQLite's synchronization requests.

## Failure and acceptance matrix

Each device test should record macOS/iOS/app versions, preview and notification
settings, sent test IDs, accessible alerts after recovery, stored rows, and gaps.
Run the same case for native Mac alerts and mirrored iPhone alerts where applicable.
Statuses below distinguish implemented paths from pending real-device verification.

| Condition | Current handling | Acceptance evidence still required |
| --- | --- | --- |
| Same banner across polls | UNIQUE rendering identity | Swift/SQL tests; real adapter repeat test pending |
| Identical DMs, distinct IDs | Preserve both | Live probe observed distinct IDs; automated storage tests |
| Preview changes, same ID | Preserve both rendering revisions | Storage tests; live grouped/expanded banner trial pending |
| Same content from different apps/devices | Source-scoped ID plus description | Storage test for source scope; multi-app trials pending |
| Collector stopped normally | Next run records interval from prior end | Swift test; end-to-end restart trial pending |
| Collector killed/crashes | Last heartbeat bounds an unclean gap; next run rescans accessible UI | SQL process-death test and Swift reopen test; adapter kill/restart pending |
| Kill before SQLite commit | Roll back transaction; retry if alert is still accessible | Real SQLite process-death test |
| Commit succeeds, process dies before acknowledgement | Replay yields one row | Reopen/replay tests; real adapter trial pending |
| Mac sleeps/wakes | Open sleep gap; suspend polling; rescan after wake | Real-device test pending |
| Mac powered off/reboots | Restart interval from last durable heartbeat/end | Auto-start UI milestone and device test pending |
| Mac login locked/logged out | Poll failures/discontinuities create gaps when observable | Locked-screen/relogin test pending; capture coverage unknown |
| iPhone off/reboots | Upstream delivery completeness stays unknown | Device test pending; no local proof of upstream power state |
| iPhone disconnected or mirroring disabled | Upstream coverage stays unknown, even if local scans succeed | Device test pending; no inferred disconnect from silence |
| Mac/iPhone Focus or notification summary | Capture only what becomes accessible | Trial per Focus/summary setting pending; no lossless claim |
| Previews hidden/redacted | Preserve what UI exposes; later text is another revision | Locked/unlocked preview trials pending |
| Alert dismissed before polling | May be missed | Measure capture window and observer feasibility; no automatic recovery promise |
| Alert retained inside Notification Center | `--recover` scans for 30 seconds while user opens/expands/scrolls the panel | Batch backfill/replay tests; real retained-UI traversal pending |
| Accessibility permission revoked | Record scan gap; periodically retry and recover after successful scan | Grant/revoke/restart trial pending |
| Notification Center process restarts | Look up current PID each scan; failed traversal opens gap | Process-restart trial pending |
| One banner malformed/disappears during scan | Report per-banner errors, retain a partial-scan gap, and commit readable observations | Adapter fault-injection pending; batch rollback test covers invalid accepted input |
| Missing/changed banner ID | Surface attribution/ID error | New macOS/app fixture required; no fabricated stable ID |
| Locale changes | Recognize only tested English description format; otherwise gap/unknown origin | Locale fixtures pending |
| Clock jumps or poll delay exceeds 3s | Persist poll-interruption gap using conservative local bound | Device clock test pending |
| Two collectors, same DB | Advisory file lock permits one owner | Process-level acceptance pending; SQLite contention contract test passes |
| SQLite busy | Bounded retry inside SQLite; unrecovered error stops collector | Contention SQL test; Swift busy case pending |
| Disk full/I/O failure/read-only volume | Exit with storage error; next startup records unclean interval if DB writable | Injected full/read-only/I/O trials pending |
| Database corrupt or unsupported schema | Fail startup with error | Swift corrupt-file test passes; unsupported-version test pending |
| Crash before first durable run record | No persisted record exists to describe that interval | UI must retain best-effort coverage status |
| Collector app update changes permission identity | Permission must be re-established if required | Signed app/update milestone pending |

## Meaning of a gap

Gap recovery marks when the collector resumed a successful local scan. It retains
the historical gap row. A recovery timestamp supplies no proof that notifications
during that interval were replayed. The collector never marks upstream delivery
complete. Startup with no previous run has an initial-scan gap and unknown prior
coverage. Sleep/poll interruption and permission gaps can overlap.

The iPhone's power, Focus, and notification settings may be inaccessible to this
collector. Their state remains unknown until independently established. Silence
does not establish a healthy iPhone connection. Source-specific APIs or exports
could later reconcile missing messages if they provide authorized history.

## Release gate

The current CLI is a foundation for controlled local experiments. Before calling
it reliable for daily collection, complete the pending adapter fault-injection
tests, at least X and two other app fixtures, sleep/Focus/power and permission
trials, and the packaged application's restart/permission checks. Record failures
and measured losses. Add deterministic regressions before implementing each fix.

Apple documents notification forwarding and its settings, but supplies no
lossless-history contract for this collector. Sources checked on 2026-11-17:

- https://support.apple.com/guide/iphone/control-your-iphone-from-your-mac-iph505911a40/ios
- https://support.apple.com/en-sg/120684
- https://developer.apple.com/documentation/applicationservices/1459475-axuielementcopyattributenames
- https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue
