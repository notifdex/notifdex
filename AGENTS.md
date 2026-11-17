# Notifdex engineering

- This is a fresh Swift/macOS implementation. Use the archive branch as historical inspiration.
- Start every behavior change with an executable acceptance condition and a failing
  test where the behavior is deterministic. Record the failure and passing result.
- Model stateful durability/recovery changes in TLA+ before implementation.
  Keep spec assumptions, implementation mapping, test cases, and limitations together.
- Use one SQLite database with atomic transactions. Acknowledge only committed evidence.
  Scope IDs to the collector source; retain changed renderings as revisions.
- Distinguish observation time, source event time, UI visibility, delivery coverage,
  and workflow state. Absence of a notification does not establish absence of activity.
- Preserve provenance and parser version. App labels and sender display names remain
  observed text. Never create or merge people solely by a display name.
- Record possible gaps on restart/revocation/interruption. A recovery scan only reports
  its own completion. Keep the historical gap and delivery uncertainty.
- Test synthetic fixtures and failure paths. Keep personal messages, databases,
  credentials, and machine-specific capture files out of Git and CI output.
- External AI processing requires user opt-in. Keep capture and storage usable offline.
- Run `swift test`, the SQL contract suite, and all TLC configurations for foundation
  changes. Test the macOS adapter manually against the matrix for release claims.
- Implement in small usable milestones. The next UI is a SwiftUI menu bar app.
  CRM inference and outbound actions require their own explicit product contracts.
