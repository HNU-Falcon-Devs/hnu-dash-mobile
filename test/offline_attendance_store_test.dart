import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/offline_attendance_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory temporaryDirectory;
  late String databasePath;
  late OfflineAttendanceStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'hnu-scans-test-',
    );
    databasePath = path.join(temporaryDirectory.path, 'scans.db');
    store = await OfflineAttendanceStore.open(
      databasePath,
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await store.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('saves a provisional scan and reads its opaque identifiers', () async {
    expect(await store.readScans(), isEmpty);

    final saved = await store.saveScan(
      eventId: 'synthetic-event',
      credentialValue: 'synthetic-credential',
    );
    final records = await store.readScans();

    expect(saved.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(records, hasLength(1));
    expect(records.single.id, saved.id);
    expect(records.single.eventId, 'synthetic-event');
    expect(records.single.credentialValue, 'synthetic-credential');
    expect(records.single.status, ScanStatus.pending);
  });

  test(
    'keeps pending scans and their IDs after closing and reopening',
    () async {
      final first = await store.saveScan(
        eventId: 'event-a',
        credentialValue: 'credential-a',
      );
      final second = await store.saveScan(
        eventId: 'event-b',
        credentialValue: 'credential-b',
      );

      await store.close();
      store = await OfflineAttendanceStore.open(
        databasePath,
        factory: databaseFactoryFfi,
      );

      expect((await store.readPendingScans()).map((scan) => scan.id), [
        first.id,
        second.id,
      ]);
    },
  );

  test('only confirmed outcomes remove scans from the pending list', () async {
    final accepted = await store.saveScan(
      eventId: 'event-a',
      credentialValue: 'credential-a',
    );
    final rejected = await store.saveScan(
      eventId: 'event-a',
      credentialValue: 'credential-b',
    );
    final stillPending = await store.saveScan(
      eventId: 'event-b',
      credentialValue: 'credential-c',
    );

    await store.recordConfirmedResult(
      accepted.id,
      ConfirmedScanResult.accepted,
    );
    await store.recordConfirmedResult(
      rejected.id,
      ConfirmedScanResult.rejected,
    );

    final records = await store.readScans();
    expect(records.map((scan) => scan.status), [
      ScanStatus.accepted,
      ScanStatus.rejected,
      ScanStatus.pending,
    ]);
    expect((await store.readPendingScans()).map((scan) => scan.id), [
      stillPending.id,
    ]);
  });

  test('failed confirmation preserves a pending scan for retry', () async {
    final saved = await store.saveScan(
      eventId: 'event-a',
      credentialValue: 'credential-a',
    );
    final connection = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await connection.execute('''
      CREATE TRIGGER fail_confirmation
      BEFORE UPDATE ON provisional_scans
      BEGIN
        SELECT RAISE(ABORT, 'simulated failure');
      END
    ''');
    await connection.close();

    await expectLater(
      store.recordConfirmedResult(saved.id, ConfirmedScanResult.accepted),
      throwsA(isA<DatabaseException>()),
    );
    expect((await store.readPendingScans()).single.id, saved.id);

    await store.close();
    store = await OfflineAttendanceStore.open(
      databasePath,
      factory: databaseFactoryFfi,
    );
    expect((await store.readPendingScans()).single.id, saved.id);
  });

  test(
    'an unknown or already confirmed ID cannot change other records',
    () async {
      final saved = await store.saveScan(
        eventId: 'event-a',
        credentialValue: 'credential-a',
      );

      await expectLater(
        store.recordConfirmedResult('missing-id', ConfirmedScanResult.accepted),
        throwsStateError,
      );
      expect((await store.readPendingScans()).single.id, saved.id);

      await store.recordConfirmedResult(saved.id, ConfirmedScanResult.rejected);
      await expectLater(
        store.recordConfirmedResult(saved.id, ConfirmedScanResult.accepted),
        throwsStateError,
      );
      expect((await store.readScans()).single.status, ScanStatus.rejected);
    },
  );

  test('rejects missing identifiers without persisting a scan', () async {
    await expectLater(
      store.saveScan(eventId: '', credentialValue: 'credential-a'),
      throwsArgumentError,
    );
    await expectLater(
      store.saveScan(eventId: 'event-a', credentialValue: ''),
      throwsArgumentError,
    );
    expect(await store.readScans(), isEmpty);
  });
}
