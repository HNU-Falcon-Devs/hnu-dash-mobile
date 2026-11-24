import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/offline_capture.dart';
import 'package:hnu_dash_mobile/secure_attendance_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'offline_fixture.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late MemorySecureValues keys;
  late SecureAttendanceStore store;
  final fixture = OfflineFixture(DateTime.utc(2026, 11, 24, 1));

  Future<SecureAttendanceStore> open({
    String staff = staffA,
    MemorySecureValues? keyStore,
  }) => SecureAttendanceStore.open(
    databasePath: databasePath,
    legacyDatabasePath: path.join(directory.path, 'legacy.db'),
    staffUserId: staff,
    keyStore: keyStore ?? keys,
  );

  OfflineTimeGuard prepare(OfflineFixture source) {
    final request = store.offlineRequest(eventId, source.assignment);
    final preparation = source.parse(request.id);
    store.saveOfflinePreparation(preparation);
    return source.guard(preparation);
  }

  OfflineClaim capture(OfflineTimeGuard guard, String studentId) =>
      store.createOfflineClaim(
        guard: guard,
        checkpointId: checkpointId,
        studentId: studentId,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hnu-offline-');
    databasePath = path.join(directory.path, 'encrypted.db');
    keys = MemorySecureValues();
    store = await open();
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('version 1 migration preserves online and legacy evidence', () async {
    final pending = await store.createPending(
      eventId: eventId,
      checkpointId: checkpointId,
      studentId: '00000123456',
    );
    final accepted = await store.createPending(
      eventId: eventId,
      checkpointId: checkpointId,
      studentId: 'SYNTHETIC-OLD',
    );
    await store.recordReceipt(
      scanId: accepted.scanId,
      outcome: ScanStatus.accepted,
      receivedAt: fixture.issued.toIso8601String(),
      replayed: false,
    );
    await store.close();
    // Disposable equivalent of the original encrypted v1 schema.
    final database = sqlite3.open(databasePath);
    final key = keys.values[SecureAttendanceStore.encryptionKeyName]!;
    database.execute("PRAGMA key = \"x'$key'\";");
    database.execute('DROP TABLE offline_claims;');
    database.execute('DROP TABLE offline_preparations;');
    database.execute('DROP TABLE offline_requests;');
    database.execute(
      '''
      INSERT INTO attendance_scans
        (scan_id,event_id,student_id,submission_status,legacy,legacy_status)
      VALUES ('legacy-id',?,'SYNTHETIC-LEGACY','legacy',1,'saved');
      ''',
      [eventId],
    );
    database.execute('PRAGMA user_version = 1;');
    database.close();

    store = await open();
    final recent = await store.readRecent();
    expect(
      recent.map((r) => r.scanId),
      containsAll([pending.scanId, accepted.scanId]),
    );
    expect((await store.readPending()).single.studentId, '00000123456');
    expect(
      recent.singleWhere((r) => r.scanId == accepted.scanId).status,
      ScanStatus.accepted,
    );
    expect(store.offlineCounts().queued, 0);
    await store.close();
    final migrated = sqlite3.open(databasePath);
    migrated.execute("PRAGMA key = \"x'$key'\";");
    expect(migrated.select('PRAGMA user_version;').single.values.single, 2);
    expect(
      migrated
          .select("SELECT student_id FROM attendance_scans WHERE legacy = 1;")
          .single['student_id'],
      'SYNTHETIC-LEGACY',
    );
    migrated.close();
  });

  test(
    'request and queued payload survive reopen; other account is isolated',
    () async {
      final request = store.offlineRequest(eventId, assignmentA);
      expect(request.created, isTrue);
      await store.close();
      store = await open();
      expect(store.offlineRequest(eventId, assignmentA), (
        id: request.id,
        created: false,
      ));
      final prep = fixture.parse(request.id);
      store.saveOfflinePreparation(prep);
      final claim = capture(fixture.guard(prep), 'SYNTHETIC-00Ab-C');
      await store.close();

      store = await open(staff: staffB);
      expect(store.offlineCounts().queued, 0);
      expect(store.readQueuedOffline(preparationA), isEmpty);
      expect(store.offlineSyncGroups(), isEmpty);
      expect(
        () => store.acknowledgeOffline(
          claim,
          OfflineAcknowledgement(fixture.issued, false),
        ),
        throwsStateError,
      );
      expect(
        () => capture(fixture.guard(prep), '00000123456'),
        throwsStateError,
      );
      await store.close();

      store = await open();
      final saved = store.readQueuedOffline(preparationA).single;
      expect(saved.parameters, claim.parameters);
      store.acknowledgeOffline(
        saved,
        OfflineAcknowledgement(fixture.issued, true),
      );
      expect(store.offlineCounts().submitted, 1);
      expect(store.readRecentOffline().single.replayed, isTrue);
      expect(store.readQueuedOffline(preparationA), isEmpty);
    },
  );

  test(
    'missing or wrong key preserves ciphertext and offline evidence',
    () async {
      final claim = capture(prepare(fixture), 'SYNTHETIC-SECRET-0001');
      await store.close();
      final bytes = await File(databasePath).readAsBytes();
      expect(latin1.decode(bytes), isNot(contains(claim.studentId)));
      expect(latin1.decode(bytes), isNot(contains('SQLite format 3')));
      final wrong = MemorySecureValues()
        ..values[SecureAttendanceStore.encryptionKeyName] = '0' * 64;
      await expectLater(open(keyStore: MemorySecureValues()), throwsStateError);
      await expectLater(open(keyStore: wrong), throwsA(anything));
      expect(await File(databasePath).readAsBytes(), bytes);
      store = await open();
      expect(
        store.readQueuedOffline(preparationA).single.parameters,
        claim.parameters,
      );
    },
  );

  test(
    'online pending and terminal conflict cannot be bypassed offline',
    () async {
      final guard = prepare(fixture);
      final pending = await store.createPending(
        eventId: eventId,
        checkpointId: checkpointId,
        studentId: '00000123456',
      );
      expect(
        () => capture(guard, 'SYNTHETIC-OTHER'),
        throwsA(isA<OfflineCaptureException>()),
      );
      await store.markBlocked(pending.scanId);
      expect(
        () => capture(guard, '00000123456'),
        throwsA(isA<OfflineCaptureException>()),
      );
      final offline = capture(guard, 'SYNTHETIC-OTHER');
      await expectLater(
        store.createPending(
          eventId: eventId,
          checkpointId: checkpointId,
          studentId: offline.studentId,
        ),
        throwsStateError,
      );
      expect(store.readQueuedOffline(preparationA).single.id, offline.id);
    },
  );

  test(
    '2400 unresolved claims across accounts are retained without eviction',
    () async {
      final guard = prepare(fixture);
      for (
        var index = 0;
        index < SecureAttendanceStore.offlineQueueCapacity;
        index++
      ) {
        capture(guard, 'SYNTHETIC-$index');
      }
      final first = store.readQueuedOffline(preparationA).first;
      store.blockOffline(first);
      expect(store.offlineCounts().queued, 2399);
      expect(store.offlineCounts().blocked, 1);
      expect(
        () => capture(guard, 'SYNTHETIC-OVERFLOW'),
        throwsA(isA<OfflineCaptureException>()),
      );
      expect(store.readRecentOffline(offset: 2390), hasLength(10));
      await store.close();

      store = await open(staff: staffB);
      final other = OfflineFixture(
        fixture.issued,
        staff: staffB,
        assignment: assignmentB,
        preparation: preparationB,
      );
      final otherGuard = prepare(other);
      expect(store.offlineCounts().queued, 0);
      expect(
        () => capture(otherGuard, 'SYNTHETIC-B'),
        throwsA(isA<OfflineCaptureException>()),
      );
      await store.close();

      store = await open();
      expect(store.offlineCounts().queued, 2399);
      expect(store.offlineCounts().blocked, 1);
      final queued = store.readQueuedOffline(preparationA).first;
      store.acknowledgeOffline(
        queued,
        OfflineAcknowledgement(fixture.issued, false),
      );
      expect(store.offlineCounts().submitted, 1);
      capture(guard, 'SYNTHETIC-NEW');
      expect(store.offlineCounts().queued, 2399);
      expect(store.offlineCounts().blocked, 1);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
