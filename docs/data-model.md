# Evidence and people

The baseline SQLite schema (version 1) lives in `Sources/NotifdexCore/schema.sql`. The core
installs it transactionally, rejects unknown versions, and refuses a populated
version-zero database from an older application. Future changes need migrations
that preserve observations and explicit user decisions.

| Entity | Purpose and identity |
| --- | --- |
| Capture run | UUID for one process lifecycle, startup, last committed heartbeat, end time |
| Observation | Source namespace, banner ID, rendering fields, parser version, first capture time, run |
| Coverage gap | Reason, approximate start/end bounds, optional recovery-scan completion |
| Person | User-managed entity with a stable UUID and display name |
| Identity | Exact platform identifier such as a handle or email, optionally linked to a person |
| Person observation | Explicit assignment with manual or verified-identifier provenance |

The app uses person and identity records for the People view. Later migrations
add saved alerts, follow-ups, Inbox filters, and user-approved app-and-title
match rules. Rule matches are derived links. Explicit links and unlinks take
precedence. Verified identifier extraction and AI summaries are future work.

## Notification identity and revisions

`source_id` combines a stable device/login namespace with `notificationcenter`.
`source_event_id` is the AX banner identifier. It identifies an observed banner;
the platform's conversation/message ID remains unknown. Replay identity includes
the origin, title, subtitle, body, raw Accessibility description, and parser version.
The SQL UNIQUE constraint excludes capture time and run ID so process restarts
preserve idempotence. One banner can produce several rendering revisions, for
example when a generic preview expands to text. A repeated rendering contributes
no additional row. Grouping those revisions into one interaction is downstream work.

SQL bindings must preserve Unicode and embedded NUL characters. Future bounded
excerpt retention must retain a digest of the full rendering for identity rather
than deduplicating truncated strings.

The first native experiment found `X, <title>, <body>, from iPhone` in an
NSAttributedString. The parser derives the app prefix using the separately
observed title, preserving commas in names/previews. Only the observed English
origin suffix is recognized. Unknown origin stays `unknown`, including native
Mac alerts without a recognized origin marker. Description parsing is heuristic.
Unrecognized descriptions become a surfaced scan gap. App labels need per-app
and locale fixtures before broad support. A display label supplies attribution
for review, not authenticated platform identity.

## Time and provenance

`captured_at` is wall-clock time on this Mac, in Unix seconds. It supplies no
message send timestamp, platform account, handle, conversation ID, or read/reply
status. Unknowns remain unknown. Gap bounds use local observations and heartbeats.
Clock changes can widen those estimates; a polling discontinuity triggers a gap.

## Relationships

`Inference Exchange` from the experiment is an actor display name. It does not
automatically create an identity or person. The user can later assign the evidence
to a Person. Any automatic match needs an observed exact identifier or a separately
verified mapping, with provenance. AI summaries should reference the observations
used and describe the incomplete coverage. Reply obligations need user confirmation
or an independently adequate conversation source.

## Notes

Schema version 10 adds independent personal notes and one level of personal folders.
A missing folder reference means Unfiled. SQLite applies `ON DELETE SET NULL` in
the folder deletion statement, preserving note IDs, content, and timestamps.
The Notebook TLA+ model treats each committed SQL write as one step. It checks
folder references and preservation of notes across folder changes. It abstracts
away note text, title, time, and UI state.

Version 10 also adds optional-in-the-editor titles to the existing `person_notes`
records, using an empty title for older notes. Both People Notes and the person
profile use the same person-scoped reads and writes. The migration preserves note
ownership, body, and timestamps. The existing PersonNotes model checks ownership.
SQL and Swift tests check migration, folder deletion, and shared People note IDs.

Existing databases that previously migrated to schema version 11 remain accepted
non-destructively on open without exposing Saved Documents in the app.
