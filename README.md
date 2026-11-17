# HNU DASH Mobile

Flutter Android companion for HNU DASH. M2.5 adds a **development-only, online attendance-scanning workflow** to the authenticated Staff workspace:

1. Select an assigned event whose Backend state is `OPEN`.
2. Select one of that event's configured IN/OUT checkpoints.
3. Scan a clearly synthetic development QR test identifier using the camera. Real HNU student IDs are not allowed in development.
4. Confirm the event, checkpoint, and masked identifier.
5. Persist one UUIDv4 capture in SQLCipher-encrypted SQLite.
6. Submit immediately through the existing `ingest_attendance_scan` RPC.
7. Persist and display the Backend's original receipt, or retain an unresolved attempt for explicit same-UUID retry.

The Backend remains authoritative for Staff identity and assignment, event/checkpoint ownership, event state, server-time capture windows, frozen-roster eligibility, and receipt outcomes. An accepted receipt is capture evidence, **not finalized attendance**.

## Development setup

Requires Flutter stable and Android SDK. Run:

```bash
flutter pub get
flutter run --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR-PUBLISHABLE-KEY
```

Use only a Supabase publishable or supported public anon key, **never service-role credentials or Google client secrets**. Build-time defines are embedded into the client and are **not** secret storage. Missing or failed secure configuration disables sign-in and scanning.

An authorized operator must configure the Google OAuth provider in Supabase Auth / Google Cloud, permit **dev.hnudash.mobile://login-callback** under Supabase Authentication → URL Configuration → Redirect URLs, and enable the existing verified `@hnu.edu.ph` account policy. No hosted settings are changed by this repository. Existing Android application ID: `dev.hnudash.hnu_dash_mobile`; production identifier still requires approval.

## Authentication and secure storage

The app remains on `supabase_flutter` **2.18.3**. It supplies the v2 `FlutterAuthClientOptions.localStorage` and `pkceAsyncStorage` interfaces using `flutter_secure_storage` 11.x. On Android, the plugin protects values with Android Keystore-backed encryption.

At first initialization, the app migrates the existing project-specific Supabase session and the old PKCE verifier from SharedPreferences to secure storage. Each secure copy is read back and verified before only its matching legacy authentication key is removed. Unrelated preferences are not cleared. OAuth callbacks and session restoration continue through the SDK's v2 interfaces. If secure storage cannot be initialized, authentication and scanning remain disabled.

Android app backups are disabled. This prevents the encrypted attendance database and secure-storage material from being copied into cloud or device-transfer backups.

## Online scanning and Backend receipts

- Scanner: `mobile_scanner` camera preview restricted to QR format. Gallery import is not used, and `returnImage` is disabled. The scanner rejects canonical-but-non-synthetic payloads without displaying or logging their contents.
- Canonical development input: decoded QR text must match `^[A-Za-z0-9-]{1,64}$`; preserve leading zeros, case, and hyphens without trimming or number parsing. Reject URL/JSON payloads, whitespace, and unsupported formats. The **development-only allowlist** accepts `SYNTHETIC-`-prefixed canonical IDs or the exact test fixture `00000123456`. Only registered synthetic roster IDs can produce an accepted Backend receipt; a `SYNTHETIC-` prefix alone does not establish roster eligibility. The physical HNU ID's QR payload is **not specified** by Backend M2.3 and must not be assumed to contain the plain-text Student ID Number.
- Confirmation: the Staff member sees the selected event, checkpoint, direction, and masked Student ID before a capture is created.
- Ingestion: authenticated Supabase client calls `ingest_attendance_scan` with `p_scan_id`, `p_event_id`, `p_checkpoint_id`, and `p_student_id`. Staff identity is derived by Backend from `auth.uid()`; the client never submits a role or Staff UUID. Before each capture/retry request, Mobile obtains the current SDK session (refreshing if required), verifies its owner matches the originating scan and pinned encrypted store, and supplies that session's access token through the PostgREST query builder's per-request `Authorization` header. Supabase Dart 2.16.5's HTTP client uses `putIfAbsent` and cannot replace an explicitly supplied header with a subsequent shared-client session. It never changes global client headers. A switch/sign-out after dispatch cannot reattribute the request to another Staff account; late results are treated as unconfirmed and left pending locally for the original owner.
- Receipts: `accepted`, `rejected`, and `duplicate` outcomes are persisted with the Backend's original `received_at` and `replayed` values. Rejected reasons are not distinguished in the UI.
- Pending: timeout, missing/malformed response, authorization or session interruption, serialization failures, and other unconfirmed outcomes remain pending. Staff must manually retry the exact same UUID and unchanged payload while signed in as its original owner; **pending** records block new scanning. An interrupted operation does not produce a confirmed local receipt even if a response arrives after account change. There is no background upload, batch upload, or offline scanning mode.
- Blocked (terminal conflict): SQLSTATE `23505` or `22023` marks immutable local evidence as `blocked`, visible to the owning Staff member with its original scan UUID for support/escalation. No retry, deletion, UUID reuse, or replacement capture of the same `(Staff, event, checkpoint, Student ID)` tuple is permitted. **Unrelated** captures can proceed when no pending records remain; blocked evidence stays prioritized in the recent-scan list. This avoids permanently disabling a Staff account without concealing unresolved submissions. Support must investigate the original UUID and Backend history; the app does not automatically repair or reconcile evidence.
- Authorization failures are not bypassed. Backend RLS and RPC checks remain authoritative; mocked tests do not prove live Backend security.

The Mobile client does not read or cache the frozen student roster, decide eligibility, use device time as proof of an open checkpoint, or mutate event state. It does not save camera images.

## Encrypted attendance storage and migration

The provisional scan store uses `sqlite3` 3.x with the SQLCipher build-hook configuration in `pubspec.yaml`. A cryptographically random 256-bit key is stored separately through `flutter_secure_storage`; it is never stored beside the database. The store verifies that SQLCipher is loaded and that the database can be read with the stored key. Account-scoped queries and mutations require the active authenticated Staff UUID. Account changes and sign-out close the handle and clear in-memory records without deleting pending attempts.

The `sqflite` dependency remains only to locate the former platform database directory; all new scan reads and writes use `sqlite3` with SQLCipher. The former plaintext database, `hnu_dash_scans.db`, is inspected during encrypted-store initialization. Its existing `provisional_scans` records are migrated into the encrypted database as **legacy and unassigned**: no Staff UUID or checkpoint is inferred, and these rows are never visible to a Staff account or automatically uploaded. The encrypted copy is verified before the plaintext database and its `-wal`, `-shm`, and `-journal` sidecars are removed. If migration or cleanup fails, the original is preserved and new scanning is disabled. An encrypted database with a missing key is not replaced or reset.

The SQLCipher community build bundled by `sqlite3` has its own licensing terms and links OpenSSL on Android; review licensing before redistribution. The SQLCipher build may use a different/older SQLite version than the package's default SQLite binary.

## Development-only data policy

**Use synthetic Student IDs exclusively. Do not collect real student identifiers or process real attendance until the remaining retention, recovery, and device-security requirements are formally approved.** The client rejects non-synthetic identifiers at scanner, workspace, RPC gateway, and new encrypted-record creation. There is no release switch to accept real IDs. This client-side guard is only a development safeguard, **not a security boundary** against a modified client. Existing legacy/unassigned rows are preserved but never submitted. Previously pending non-synthetic records are retained for support and cannot be retried. Encryption and account scoping do not approve production collection or resolve key-loss recovery, retention, or shared-device operational policy.

## M2.6 integration QA status (2026-11-17)

The last merged M2.5 code passed [GitHub Actions run #42571447633](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/actions/runs/42571447633), including Flutter tests, Android debug APK build, and SQLCipher native-library inspection. **This is not independent physical-device or Mobile–Backend integration verification.** M2.6 Part B independently verified synthetic Web–Backend event lifecycle, authorization, revocation and online scan receipts using authenticated API requests; the actual Flutter application was not exercised.

**Next:** [Mobile issue #7 — M2.6 Part C](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/issues/7) tracks Flutter/Android device QA against an isolated Backend with synthetic accounts and QR fixtures. See the [cross-repository M2.6 status](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/qa/m2-6-integration-status.md) (introduced in the corresponding Backend documentation PR).

## Validation

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

The test suite exercises SQLCipher key verification, ciphertext inspection, legacy migration, account isolation, pinned actual HTTP authorization headers, sign-out/switch during in-flight capture and retry, local receipt ownership, synthetic-only scan/storage/RPC gates, terminal blocked-record recovery, manual same-UUID retry, scanner validation, permission recovery, and workspace flows using synthetic records. CI also inspects the APK's bundled SQLCipher native library.

Canonical Backend contracts: [M2.1 Staff assignment](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/integration/milestone-2-part-1.md) and [M2.3 online ingestion](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/integration/milestone-2-part-3-scan-ingestion.md). M2.5 defines the **synthetic development input** expected by the current scanner; it does **not** establish the physical HNU ID QR encoding. The [physical QR specification decision](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/issues/9) is pending. Historical closed Backend PR #2 is superseded.

Independent physical-device verification remains required for Google OAuth callback/session restoration, camera permission grant/denial/recovery, **synthetic** QR scanning, SQLCipher on a target Android device, and Mobile–Backend revocation/replay behavior. Real HNU ID decoding requires an approved QR specification and is not authorized in development QA. Do not deploy for real attendance until the separate release gates are approved.
