# HNU DASH Mobile — Agent Guidance

## Ownership and authority

- This repository owns the Flutter Android attendance collector, not the Web UI or authoritative backend.
- Mobile scans physical HNU ID QR codes, uses assigned frozen rosters for offline matching, and queues provisional records in local SQLite. It communicates directly with approved backend interfaces, never through Web.
- Supabase/PostgreSQL alone enforces identity, permissions, event lifecycle, scan validation, reconciliation, and official attendance. Mobile must not declare a student officially present.
- The proposed shared contract is maintained by Backend: [integration-v0 (Backend PR #2)](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/pull/2). **It is unapproved and unimplemented.** Reference it; do not copy its payloads, invent endpoints, or treat proposed decisions as settled. Shared changes require WhiteTree Orchestrator approval.

## Offline attendance invariants

- Persist a confirmed-by-staff capture locally before attempting upload. Preserve the same scan UUID and immutable capture evidence on retries, including after restart or network failure.
- Local persistence means **queued evidence**, not server acceptance. A durable per-record upload receipt means **server ingest**, not final validation or official attendance. Reconciliation outcomes are provisional until the backend finalizes the event.
- Distinguish pending, durably acknowledged, rejected, and unresolved uploads. Do not silently delete unacknowledged or failed records. A request timeout is not proof of success.
- Do not reject Time-Out solely because Time-In is absent on this device; another assigned device may have recorded it.
- New capture is allowed only while the event is OPEN. SYNCING permits uploading earlier captures, not new capture. FINALIZED and LOCKED prohibit uploads. The backend must enforce these rules regardless of cached UI state.

## Security and privacy gates

- **No real student-data collection yet.** Existing SQLite storage is unencrypted and lacks authenticated staff isolation. Use synthetic data only until authentication, roster-data protection, session switching/expiry, encryption, retention, and recovery policies are approved and implemented.
- Staff ownership follows the authenticated account, not the borrowed phone. Protect cached records and rosters from other users; never expose credentials or student identifiers in logs or fixtures.
- Never ship backend service-role keys, commit secrets, proxy HNU MIS passwords, or implement client-only authorization.
- Never purge pending records merely because a session ends, synchronization fails, or an event closes; follow an approved recovery and retention policy.

## Development procedure

1. Inspect current `main`, open PRs, README, Flutter code, tests, CI, and the relevant backend contract **before** editing. Preserve concurrent work, existing branches, and open pull requests. Do not overwrite unrelated changes.
2. Follow ordinary Dart/Flutter conventions. Keep changes narrow, tests meaningful, and dependencies minimal. Do not introduce QR capture, live sync, domain models, or new backend contracts without an approved feature assignment.
3. Use a focused feature branch and PR for a significant milestone; use logically scoped Conventional Commits within that milestone. Avoid trivial PRs, giant commits, and manufactured commit counts; respect WhiteTree's 50-commit ceiling.
4. Keep `main` protected; never push directly, weaken rulesets, change CODEOWNERS (`@Syris-EkzD`), or merge without human authorization. The required CI check is `Repository integrity` and applies to everyone.
5. Run relevant checks and report actual results, not assumptions:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

Mobile Maintainer reviews implementation and CI independently; WhiteTree Orchestrator decides cross-repository architecture and scope; the human owner makes the final merge decision.
