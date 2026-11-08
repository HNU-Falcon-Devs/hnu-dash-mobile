# HNU DASH Mobile

Flutter Android companion for HNU DASH. Milestone 2.4 provides a **development-only, read-only Staff workspace** with Google sign-in, assigned events and configurable IN/OUT checkpoints. No QR scanning, roster downloading, scan upload, offline synchronization, or official attendance decisions are provided. Backend remains the authority.

## Development setup

Requires Flutter stable and Android SDK. Run:

```bash
flutter pub get
flutter run --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR-PUBLISHABLE-KEY
```

Use only a Supabase publishable or supported public anon key, **never service-role credentials or Google client secrets**. Build-time defines are embedded into the client and are **not** secret storage. Missing configuration displays an explicit setup screen.

An authorized operator must configure the Google OAuth provider in Supabase Auth / Google Cloud, permit **dev.hnudash.mobile://login-callback** under Supabase Authentication → URL Configuration → Redirect URLs, and enable the existing verified `@hnu.edu.ph` account policy. No hosted settings were changed. The Android manifest declares VIEW/BROWSABLE callbacks to the Flutter activity. Existing development Android application ID: `dev.hnudash.hnu_dash_mobile`; production identifier still requires approval.

`supabase_flutter` 2.x persists the session by default. Authenticated sessions do **not** grant Staff rights: the client reads `event_staff`, `events` and `event_checkpoints` through Backend RLS, and verifies effective event access using `can_access_assigned_event(eid)` before displaying checkpoints. On refresh/resume it clears prior data first. Session changes, sign-out, and revoked access remove all in-memory event/checkpoint data; no roster or event cache is persisted. Schedules use Asia/Manila display time.

The existing unencrypted SQLite provisional-scan store and tests are unchanged. **Do not use real student identifiers or roster data in development builds.** Session tokens are persisted by the Supabase Flutter SDK's built-in device preferences; audit secure token-at-rest storage, shared-device isolation, and device logout before any deployment.

## Validation

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

The SQLite FFI tests require libsqlite3-dev on Linux. CI must pass the existing `Repository integrity` check. Device-level Google OAuth callback and actual Backend RLS/revocation still need independent tests with controlled synthetic identities; widget mocks cannot prove backend security.

Canonical contracts: [M2.1 Staff assignment](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/integration/milestone-2-part-1.md) and [M2.3 online ingestion](https://github.com/HNU-Falcon-Devs/hnu-dash-backend/blob/main/docs/integration/milestone-2-part-3-scan-ingestion.md). Historical closed Backend PR #2 is superseded.
