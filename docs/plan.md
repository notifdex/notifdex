# Development order

1. **Evidence foundation.** Specify observation identity, revisions, provenance,
   capture gaps, transactions, and human identity boundaries. Keep the Swift core,
   SQLite contract tests, and TLA+ model executable. This is the current milestone.
2. **Collector resilience.** Extract a fakeable Accessibility transport, isolate
   malformed banners, inject OS and SQLite failures, measure capture gaps, and
   add X plus two other app/locale fixtures. Test every power/sleep/Focus row.
3. **Menu bar application (prototype implemented).** SwiftUI MenuBarExtra with
   capture/pause status, permissions, app toggles, recent observations, login-item
   registration, and bounded automated retained-alert recovery. Local app packaging
   and packaged-resource checks run in CI. Real device acceptance, permission
   persistence across updates, and per-macOS navigation fixtures remain pending.
4. **People workflow.** User creates/links people and verified platform identities,
   reviews unresolved actors, and browses evidence timelines. Introduce reversible
   attribution and explicit review/reply/follow-up workflow tests.
5. **Relationship intelligence.** Opt-in evidence-grounded summaries, suggested
   follow-ups, tags, user-defined funnels, and optional authorized history sources.
   Handle unobserved replies explicitly. Keep AI suggestions and user decisions
   separately attributable.

The previous Python/web application informs product choices. The new implementation
uses Swift with direct SQLite access and a single local database. A second backend
process is unnecessary for this first native collector. Revisit integration when
a concrete connector or model provider needs it.
