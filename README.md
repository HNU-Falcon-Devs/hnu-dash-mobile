# HNU DASH Mobile

HNU DASH Mobile is the Flutter companion app for collecting physical attendance at HNU events. The Android app currently launches a landing screen. A local SQLite component can save and read provisional scans, list pending scans, and record a confirmed accepted or rejected result. Scanning and synchronization are not available in the app yet.

## Stack and setup

- Flutter (stable channel) and Dart
- Android SDK and an Android emulator or device
- SQLite via `sqflite` for local provisional scan storage

Install [Flutter](https://docs.flutter.dev/get-started/install) with Android development support, then run:

```bash
flutter doctor
flutter pub get
flutter run
```

The Android application ID is `dev.hnudash.hnu_dash_mobile` for development. Maintainers must approve the final ID before release.

## Validation

Run the same checks used by CI:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

Run just the SQLite persistence tests with `flutter test test/offline_attendance_store_test.dart`. Linux test hosts need the SQLite native library (`libsqlite3-dev`); CI installs it explicitly.

The APK is generated under `build/app/outputs/flutter-apk/` and is ignored by Git.

## System boundary

HNU DASH Web is a separately maintained Next.js management interface. The separate Supabase/PostgreSQL backend is the authoritative source for attendance. Locally stored scans have client-generated IDs for later retries, but remain provisional until that backend confirms a result. The mobile app must not create authoritative attendance records or bypass backend authorization.

Before enabling real student data or capture, maintainers must agree on event authorization, credential format, and the backend synchronization and confirmation contract. Privacy decisions are also required for data minimization, encryption at rest, retention and deletion, and device access. The current SQLite database is not encrypted and must not be treated as production-safe for student data. Event assignment, ID scanning, authentication, and live synchronization remain deferred.

Keep changes focused on this repository. Use standard Flutter conventions and add dependencies only when a feature requires them.
