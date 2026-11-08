# HNU DASH Mobile — Agent Guidance

## Ownership and authority

- This repository owns the Flutter Android Staff client and online attendance capture UI, not the Web UI or authoritative Backend.
- Mobile reads assigned events and checkpoints through the merged Backend M2.1 contract and submits confirmed online scan evidence only through the merged M2.3 `ingest_attendance_scan` RPC.
- Backend owns identity verification, Staff membership/assignment, event and checkpoint ownership/state, server-time capture windows, frozen-roster eligibility, duplicate classification, and immutable receipts. The client must never grant itself Staff privileges or declare official attendance.
- Backend contracts: [M2.1 Staff assignment and activation](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/integration/milestone-2-part-1.md) and [M2.3 online scan ingestion](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/integration/milestone-2-part-3-scan-ingestion.md). Closed Backend PR #2 is superseded and is not an API specification. Shared contract changes require WhiteTree Orchestrator approval.

## Online scan invariants

- New captures require an assigned event whose current client-visible state is `OPEN`, a Staff-selected checkpoint, a camera-decoded canonical Student ID, and explicit confirmation. Backend remains authoritative and rejects stale/unauthorized requests.
- The approved M2.5 QR rule is plain-text canonical Student ID Number. Preserve the exact string, including leading zeros, case, and hyphens; accept only `^[A-Za-z0-9-]{1,64}$`. Do not trim, parse as a number, or infer URL/JSON/encoded formats.
- Generate one UUIDv4 after confirmation, persist the exact event/checkpoint/student payload and authenticated Staff UUID, then submit immediately. Never create a replacement UUID after timeout.
- Local `pending` means **no authoritative receipt**. Only a validated Backend receipt with `scan_id`, `outcome`, `received_at`, and `replayed` can become accepted/rejected/duplicate in local storage. A replay must preserve the original outcome and server timestamp.
- Retry is explicit and one record at a time, using the same UUID and unchanged payload. No automatic retry, background synchronization, bulk upload, or offline scanning. Block new scanning while a pending or conflicting attempt remains unresolved.
- Accepted evidence is not finalized attendance. Rejected reasons must not reveal frozen-roster membership or checkpoint-window details. Never display raw SQL, internal Backend messages, or full Student IDs in logs/UI.
- Device time is presentation-only. Never use it as proof that a checkpoint window is open.

## Encrypted storage and account isolation

- New scan records live in SQLCipher-encrypted SQLite using `sqlite3` 3.x and its SQLCipher build hook. Generate a cryptographically random key and store it separately in Android Keystore-backed `flutter_secure_storage`; never hardcode or store the key beside the database.
- Bind each active store handle to the authenticated Supabase user UUID. Scope every read/write/retry to that UUID. Close the handle and clear in-memory state on account changes/sign-out; never delete unresolved records on sign-out.
- Do not cache the student roster or save camera images. QR scanning is camera-only and QR-format-only.
- Migrate any existing plaintext `hnu_dash_scans.db` records into encrypted storage as legacy/unassigned unless Staff and checkpoint attribution is provable. Never assign legacy rows to the first account that signs in and never upload them. Verify encrypted copies before deleting the plaintext database and sidecars. If migration, key verification, or plaintext cleanup fails, preserve source data and disable new capture.
- Supabase Flutter remains on v2.18.3. Implement both v2 `FlutterAuthClientOptions.localStorage` and `pkceAsyncStorage` using secure storage. Migrate only the old project session key and PKCE verifier, verify secure copies before removing those exact old keys, and preserve unrelated preferences.
- Android app backups must exclude database and secure-storage material. Do not add backup/export behavior without explicit approval.

## Security and privacy gates

- **Synthetic Student IDs only.** Do not collect real student identifiers or process real attendance until retention, recovery, and device-security requirements are formally approved. SQLCipher and account scoping do not themselves authorize production data.
- Never ship Backend service-role keys, Google client secrets, commit credentials, proxy HNU MIS passwords, or implement client-only authorization.
- Do not read or cache frozen rosters, decide local eligibility, infer rejected reasons, or mutate event lifecycle.
- Do not purge pending/legacy records because a session ends, an event closes, an upload fails, or a user signs out. Follow an approved recovery and retention policy.

## Development procedure

1. Inspect current `main`, open PRs, README, Flutter code, tests, CI, and the relevant Backend contracts before editing. Preserve concurrent work and existing PRs.
2. Keep changes narrow and dependencies minimal. Do not introduce new Backend endpoints, migrations, Edge Functions, Middleware, offline sync, or new local attendance models without a separate approved assignment.
3. Use a focused feature branch and draft PR for a milestone; use Conventional Commits; respect the 50-commit ceiling.
4. Keep `main` protected; never push directly, weaken rulesets, change CODEOWNERS (`@Syris-EkzD`), or merge/deploy without human authorization. The mandatory CI check is `Repository integrity`.
5. Run the complete validation pipeline and report actual results:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

Mobile Maintainer reviews implementation and CI independently; WhiteTree Orchestrator decides cross-repository architecture and scope; the human owner makes the final merge decision.
