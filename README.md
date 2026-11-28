# HNU DASH Mobile

Flutter Android companion for HNU DASH. As of 2026-11-26, M4.3A/B synthetic offline capture, upload and preparation accounting are merged; [post-merge CI](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/actions/runs/45547158608) passed 91 tests, APK build and SQLCipher ABI verification. The existing M2.5 **development-only online workflow** remains:

1. Select an assigned event whose Backend state is `OPEN`.
2. Select one of that event's configured IN/OUT checkpoints.
3. Scan a clearly synthetic development QR test identifier using the camera. Real HNU student IDs are not allowed in development.
4. Confirm the event, checkpoint, and masked identifier.
5. Persist one UUIDv4 capture in SQLCipher-encrypted SQLite.
6. Submit immediately through the existing `ingest_attendance_scan` RPC.
7. Persist and display the Backend's original receipt, or retain an unresolved attempt for explicit same-UUID retry.

The Backend remains authoritative for Staff identity and assignment, event/checkpoint ownership, event state, server-time capture windows, frozen-roster eligibility, and receipt outcomes. An accepted receipt is capture evidence, **not finalized attendance**.

## Development setup

Requires Flutter **3.47.9 / Dart 3.13.7** and Android SDK. The project requires Dart `^3.13.7`; Flutter 3.47.5 / Dart 3.13.4 cannot resolve its dependencies. CI uses Flutter tag `3.47.9` at commit `c197ca5199e9ee5661e865596c9c07294dfab51c`. For a separate local SDK without changing an existing Flutter installation:

```bash
git clone --depth 1 --branch 3.47.9 https://github.com/flutter/flutter.git "$HOME/develop/flutter-3.47.9"
git -C "$HOME/develop/flutter-3.47.9" rev-parse HEAD # expect c197ca5199e9ee5661e865596c9c07294dfab51c
export PATH="$HOME/develop/flutter-3.47.9/bin:$PATH"
flutter --version # expect Flutter 3.47.9 and Dart 3.13.7
```

Run:

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
- Pending: timeout, missing/malformed response, authorization or session interruption, serialization failures, and other unconfirmed outcomes remain pending. Staff must manually retry the exact same UUID and unchanged payload while signed in as its original owner; **pending** records block new scanning. An interrupted operation does not produce a confirmed local receipt even if a response arrives after account change. The online path never falls back to offline capture; no background or batch upload is performed.
- Blocked (terminal conflict): SQLSTATE `23505` or `22023` marks immutable local evidence as `blocked`, visible to the owning Staff member with its original scan UUID for support/escalation. No retry, deletion, UUID reuse, or replacement capture of the same `(Staff, event, checkpoint, Student ID)` tuple is permitted. **Unrelated** captures can proceed when no pending records remain; blocked evidence stays prioritized in the recent-scan list. This avoids permanently disabling a Staff account without concealing unresolved submissions. Support must investigate the original UUID and Backend history; the app does not automatically repair or reconcile evidence.
- Authorization failures are not bypassed. Backend RLS and RPC checks remain authoritative; mocked tests do not prove live Backend security.

The Mobile client does not read or cache the frozen student roster, decide eligibility, use device time as proof of an open checkpoint, or mutate event state. It does not save camera images.

## M4.3A synthetic offline foundation

The authorized [Mobile #14](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/issues/14) implementation depends on the [merged M4.1 Backend contract](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/13788b8b78c22f31deb269aa1296612936650941/docs/integration/milestone-4-part-1-offline-evidence.md). The assigned-event query uses its offline settings and assignment identity. Capture and upload use only M4.1; M4.3B adds the two accepted Staff accounting endpoints described below.

1. Refresh assigned events and explicitly prepare an offline-enabled event while online. The preparation request UUID is encrypted and persisted before the RPC. Validate the response against the selected assignment, event and checkpoint schedule.
2. Explicitly enter offline mode and choose a prepared checkpoint. Capture only while conservative server-time bounds are within both the lease and checkpoint. The guard combines monotonic elapsed time with wall-clock consistency (two-second tolerance); it refuses ambiguous boundaries and clock changes. The claimed timestamp at confirmation remains untrusted.
3. Scan a synthetic QR and confirm its masked ID. Save the immutable claim and UUID to the account-scoped encrypted queue without an online RPC. An unresolved online attempt blocks offline capture. Queued and blocked claims count toward the installation-wide 2,400 unresolved development guard.
4. Select one preparation explicitly and sync its queued claims in the foreground, in insertion order. A denial pauses only that selected pass; the original evidence remains queued and another preparation may be explicitly selected. No automatic skipping or deletion. Each claim uses the original immutable payload and UUID with the current owner's pinned bearer. A lost or malformed response retains the claim for replay; terminal conflicts are preserved for support. Submission is not acceptance, review completion, or finalized attendance.
5. Restart or sign-out clears the in-memory time anchor. A recovered preparation replay without the original anchor cannot enable capture. Obtain a new server-permitted preparation; existing claims remain available to their original owner for explicit sync. The client does not use device time to reject a legitimate upload replay.

Schema v2 introduced separate offline request, preparation and claim tables; M4.3B schema v3 adds durable completion intent and accounting transactionally. Existing online and unassigned legacy evidence remains intact. No production retention, recovery, physical QR or shared-device policy is established.

## Encrypted attendance storage and migration

The provisional scan store uses `sqlite3` 3.x with the SQLCipher build-hook configuration in `pubspec.yaml`. A cryptographically random 256-bit key is stored separately through `flutter_secure_storage`; it is never stored beside the database. The store verifies that SQLCipher is loaded and that the database can be read with the stored key. Account-scoped queries and mutations require the active authenticated Staff UUID. Account changes and sign-out close the handle and clear in-memory records without deleting pending attempts.

The `sqflite` dependency remains only to locate the former platform database directory; all new scan reads and writes use `sqlite3` with SQLCipher. The former plaintext database, `hnu_dash_scans.db`, is inspected during encrypted-store initialization. Its existing `provisional_scans` records are migrated into the encrypted database as **legacy and unassigned**: no Staff UUID or checkpoint is inferred, and these rows are never visible to a Staff account or automatically uploaded. The encrypted copy is verified before the plaintext database and its `-wal`, `-shm`, and `-journal` sidecars are removed. If migration or cleanup fails, the original is preserved and new scanning is disabled. An encrypted database with a missing key is not replaced or reset.

The SQLCipher community build bundled by `sqlite3` has its own licensing terms and links OpenSSL on Android; review licensing before redistribution. The SQLCipher build may use a different/older SQLite version than the package's default SQLite binary.

## Development-only data policy

**Use synthetic Student IDs exclusively. Do not collect real student identifiers or process real attendance until the remaining retention, recovery, and device-security requirements are formally approved.** The client rejects non-synthetic identifiers at scanner, workspace, RPC gateway, and new encrypted-record creation. There is no release switch to accept real IDs. This client-side guard is only a development safeguard, **not a security boundary** against a modified client. Existing legacy/unassigned rows are preserved but never submitted. Previously pending non-synthetic records are retained for support and cannot be retried. Encryption and account scoping do not approve production collection or resolve key-loss recovery, retention, or shared-device operational policy.

## Integration QA status (2026-11-26)

[Mobile #7](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/issues/7#issuecomment-7110814051) accepted bounded synthetic online Android–Backend integration on Mobile `e4e5e6ee` and Backend `88104382`: actual synthetic camera scans, online authorization/revocation, network loss and same-UUID replay. This is historical device evidence, not physical testing of the current M4 APK. [Web #24](https://github.com/HNU-Falcon-Devs/hnu-dash-web/issues/24#issuecomment-7135489451) accepted the online browser/RPC lifecycle, not Mobile runtime.

[M4.5A acceptance](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/issues/19#issuecomment-7180150336) passed bounded synthetic browser/RPC/database offline integration with Mobile as a pinned reference only, not an executed Android client. **Next:** separately authorized physical offline QA and residual security/recovery verification coordinated in [Mobile #13](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/issues/13). See the [historical cross-repository M2.6 status](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/qa/m2-6-integration-status.md) and issue adjudications.

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

Current-revision physical offline QA and targeted residual device-security checks remain required; do not repeat historical online device acceptance merely to recreate receipts. Real HNU ID decoding requires an approved QR specification and is not authorized in development QA. Do not deploy for real attendance until separate release gates are approved.

## M4.3B Staff preparation accounting

Select a locally stored preparation (including zero-claim sessions), check authoritative status online, and explicitly declare its unchanged acknowledged count only when all local claims are submitted and the server count agrees. SQLCipher schema v3 retains immutable completion intent before dispatch and terminal accounting; pending declarations stop new capture after restart. Retry the same count, never manufacture counts from server-only claims. Resume capture only after an online status check with the original valid time anchor. Completion may occur after seal; upload replay remains independent of status. This is not proof of all evidence or attendance acceptance. No manager review or reconciliation API is consumed.

## Development-only unsigned release verification (Mobile #19)

The separate **Development unsigned release** GitHub Actions job checks release-mode compilation and packaging only, with the existing development application ID and OAuth callback. Release builds have no signing configuration; Android signing overrides are rejected. The mandatory Repository integrity debug job is unchanged. No release key, real project configuration, APK artifact upload, installation or publishing is authorized.

The job uses the pinned Flutter SDK, enforces the lockfile, inventories Dart packages and root license/notice candidates (including missing candidates), and prints the Android release runtime dependency graph. It uses a reserved invalid synthetic URL and dummy public key, never a live backend. The verifier records the unsigned APK hash, effective manifest (including min/target SDK and permissions), unsigned signature evidence, native hashes, DT_NEEDED dependencies, all ELF LOAD alignments, and zipalign 16 KiB check. ELF 16 KiB alignment is required for the two 64-bit ABIs; ARM32 is reported, not a device support promise. A failed check blocks the development verification; do not weaken it to obtain a green job.

### Redistribution review (not cleared)

| Dependency / material | Source / preliminary disposition |
| --- | --- |
| sqlite3 3.9.1 / SQLCipher Community 4.20.0 | [Exact upstream source](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/tool/download_sqlite.dart), [asset hashes](https://github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-3.9.1); community BSD-style copyright, attribution, license/disclaimer and non-endorsement obligations require review and user-accessible notices. |
| OpenSSL 4.1.0 | [Upstream build](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/.github/workflows/compile_sqlite.yml), [SBOM generator](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/tool/generate_sbom.dart); statically linked into SQLCipher on Android; Apache-2.0 license and applicable notices need review. Absence of libcrypto.so is not evidence of absence. |
| Flutter engine, Dart packages, Android Gradle dependencies, bundled scanner/ML Kit, other native libraries | Inventory from job logs; reconcile versions, native hashes and exact upstream license texts/third-party terms, including transitive and bundled material. Package-root notice hashes are evidence of candidates, not proof of completeness. |

No distribution clearance: verify upstream binary provenance (packaging/stripping can change hashes), security advisories, exact license/attribution requirements, institution approval, and provide offline user-accessible notices plus required accompanying materials before redistribution. No new dependencies or license acceptance inferred. The current developer APK identity is not a production identity, and existing encrypted evidence must not be deleted or moved to force an upgrade. Signed release, production config, device support policy and physical encrypted-data upgrade checks remain separately gated by [Mobile #19](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/issues/19), [Mobile #13](https://github.com/HNU-Falcon-Devs/hnu-dash-mobile/issues/13) and [Backend #24](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/issues/24).

## M1 policy 2 — fixture-only local-first consumer

Authorized [M1 package](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/issues/27#issuecomment-7226350590)
and [owner approval](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/issues/27#issuecomment-7226560645).
Canonical Backend revision `c53cbdcfab92d99857f91de1b7046856e7e63de2`:
[B1 preparation](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/c53cbdcfab92d99857f91de1b7046856e7e63de2/docs/integration/offline-first-b1-foundation.md)
and [B2 evidence/accounting](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/c53cbdcfab92d99857f91de1b7046856e7e63de2/docs/integration/offline-first-b2-reconciliation.md).

- `lib/offline_v2.dart`: exact policy 2 receipt/clock/status parsing, separate QR
  and confirmation observations, advisory consecutive checkpoint/category
  warnings. B2 is the only eligibility authority.
- `lib/offline_v2_gateway.dart`: explicit injected fixture context; no
  connection from `main.dart` or normal Staff navigation. The harness must
  provide the securely restored original owner, a monotonic account-change
  epoch (including sign-out and A→B→A), live session for RPCs and foreground
  state. No new offline login. Each request pins the bearer via the existing
  per-query header technique. Late results after account/lifecycle change
  leave immutable attempts unconfirmed.
- SQLCipher schema 4 adds separate requests/preparations/claims. No v1
  conversion, rekey or deletion. Original request UUID/observation is
  persisted before dispatch; a replay cannot create a response anchor.
  The same owner cannot create new mixed-version work while another
  version has unresolved claims/preparations; legacy retry/accounting
  remains available. Both versions share the installation-wide 2,400
  unresolved offline claim guard; only counts are shared across accounts.
  A failed key or malformed context fails closed; no reset/purge.
- Android `elapsedRealtime()` (includes sleep) and best-effort API 24
  `Settings.Global.BOOT_COUNT` supply client evidence; the baseline unsigned
  APK manifest reports minSdk 24. Neither is an attestation. Native
  observation at the QR callback (not a camera frame timestamp) is distinct
  from explicit confirmation. Original request and response observations
  are stored; a same-boot app-process restart can recover them. Reboot,
  unavailable marker, replay without original response end, clock jumps and
  unknown fields remain uncertain; no fabricated anchor or local time limit.
  Clock bounds are advisory and use B2's synthetic constants, not measured
  drift. Physical Android clock/reboot/secure recovery has not been tested.
- Explicit stop is reversible only while the original scope remains safe
  and no terminal status/intent is retained. Capture needs no network and
  cannot upload automatically. Known SYNCING/terminal status stops collection;
  a disconnected device may be stale. New admission requires SYNCING/unsealed
  status; Backend checks the actual server deadline, not device wall time.
  Before dispatch persist attempted state; definitive admission denial is
  not an acknowledgement, ambiguous sent attempts retain exact payload
  for authorized replay after closure/seal/accounting. No skip or next group.
- Completion requires explicit count, matching server/local distinct durable
  submissions (including zero), no unresolved/blocked records and a stored
  immutable intent. Lost response retries the same count. A status-only
  completed disposition is not a fabricated local receipt. Loss and terminal
  status never enable capture. No roster oracle or official attendance claim.

| Exact RPC | Named parameters |
| --- | --- |
| `prepare_offline_capture_v2` | `p_event_id,p_assignment_id,p_request_id` |
| `get_offline_preparation_status_v2` | `p_preparation_id` |
| `submit_offline_capture_v2` | `p_preparation_id,p_capture_id,p_checkpoint_id,p_student_id,p_clock` |
| `complete_offline_preparation_v2` | `p_preparation_id,p_acknowledged_count` |

Generic submitted receipts are not accepted attendance. SQLSTATE 22023/23505
retain blocked immutable claim evidence; 42501/55000 pause admission with
original evidence retained; 40001, transport interruption and malformed
acknowledgement remain unconfirmed. No client-side deadline admission or
roster eligibility decision. The test-only workspace is under `test/`,
not an ordinary navigation route. Mock transport and encrypted fixture tests
do not establish actual Backend HTTP, real OAuth or physical Android
acceptance. Ordinary version discovery, creation/opening/assignment and
coordinated activation/cutover require separate Backend-owned contracts,
combined tuple acceptance and owner authorization. Mobile #13/#19 and
institutional QR/privacy/recovery/redistribution gates remain pending.
