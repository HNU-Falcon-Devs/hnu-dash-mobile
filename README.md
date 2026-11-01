# HNU DASH Mobile

HNU DASH Mobile is the Flutter companion app for collecting physical attendance at HNU events. This repository currently contains an Android application foundation: it launches a landing screen and has no attendance, authentication, or backend functionality yet.

## Stack and setup

- Flutter (stable channel) and Dart
- Android SDK and an Android emulator or device

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

The APK is generated under `build/app/outputs/flutter-apk/` and is ignored by Git.

## System boundary

HNU DASH Web is a separately maintained Next.js management interface. Its Supabase/PostgreSQL backend is the authoritative source for attendance. Future mobile work may download assigned events and authorized rosters, scan HNU credentials, hold provisional records offline, synchronize them, and show backend validation results. These features need an agreed backend contract and are **not implemented** in this foundation. The mobile app must not create authoritative attendance records or bypass backend authorization.

Keep changes focused on this repository. Use standard Flutter conventions and add dependencies only when a feature requires them.
