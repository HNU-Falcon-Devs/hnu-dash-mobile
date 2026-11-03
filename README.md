# HNU DASH Mobile

HNU DASH Mobile is the planned Android attendance tool for authorized staff at Holy Name University events. Staff will scan physical student IDs and, when internet access is unavailable, keep scans on the device until they can be sent for checking.

## How it fits into HNU DASH

- **Mobile (this repository)** will collect scans on-site and hold them safely until they can be synchronized.
- [Backend](https://github.com/HNU-Falcon-Devs/hnu-dash-backend) will check uploaded scans and determine official attendance.
- [Web](https://github.com/HNU-Falcon-Devs/hnu-dash-web) will let organizers manage events and review records, and students view their attendance.

An offline or uploaded scan is **not** automatically an official attendance result.

## Current status

**Development foundation ready; not yet an operational scanning app.** The Android app currently shows a landing screen. A tested local storage component can keep synthetic, provisional scans and their pending or confirmed upload outcomes, including across app restarts.

QR scanning, sign-in, staff assignments, and live synchronization are **not available yet**. The current local storage is not encrypted or isolated by staff account, so **do not use real student data**.

## Developer setup

Requires Flutter (stable channel), Dart, the Android SDK, and an emulator or Android device. The local store uses SQLite through `sqflite`.

Install [Flutter](https://docs.flutter.dev/get-started/install) with Android development support, then run:

```bash
flutter doctor
flutter pub get
flutter run
```

The development Android application ID is `dev.hnudash.hnu_dash_mobile`; the final ID requires maintainer approval.

## Validation

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug
```

Run the storage tests alone with `flutter test test/offline_attendance_store_test.dart`. Linux test hosts need the SQLite native library (`libsqlite3-dev`), which CI installs. Debug APKs are generated under `build/app/outputs/flutter-apk/` and ignored by Git.

## Safety and future integration

Mobile will never determine official attendance or bypass backend permissions. Before enabling real collection, the team must approve event authorization, ID format, backend synchronization rules, and privacy safeguards such as encryption, staff access, data retention, and recovery. Keep changes scoped to this repository and add dependencies only when needed.
