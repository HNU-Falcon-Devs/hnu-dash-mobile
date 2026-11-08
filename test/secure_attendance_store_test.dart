import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/secure_attendance_store.dart';
import 'package:hnu_dash_mobile/secure_value_store.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

class MemorySecureValueStore implements SecureValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late Directory directory;
  late String databasePath;
  late String legacyPath;
  late MemorySecureValueStore secrets;
  late SecureAttendanceStore store;

  Future<SecureAttendanceStore> openStore({
    String staffId = 'staff-a',
    MemorySecureValueStore? keyStore,
  }) => SecureAttendanceStore.open(
    databasePath: databasePath,
    legacyDatabasePath: legacyPath,
    staffUserId: staffId,
    keyStore: keyStore ?? secrets,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hnu-secure-scans-');
    databasePath = path.join(directory.path, 'encrypted.db');
    legacyPath = path.join(directory.path, 'hnu_dash_scans.db');
    secrets = MemorySecureValueStore();
    store = await openStore();
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('uses SQLCipher and stores no plaintext Student ID marker', () async {
    const marker = 'SYNTHETIC-STUDENT-00123';
    final saved = await store.createPending(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: marker,
    );
    expect(saved.scanId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(
      secrets.values[SecureAttendanceStore.encryptionKeyName],
      matches(RegExp(r'^[0-9a-f]{64}$')),
    );

    await store.close();
    final bytes = await File(databasePath).readAsBytes();
    expect(latin1.decode(bytes, allowInvalid: true), isNot(contains(marker)));

    final database = sqlite3.open(databasePath);
    final key = secrets.values[SecureAttendanceStore.encryptionKeyName]!;
    database.execute("PRAGMA key = \"x'$key'\";");
    expect(
      database.select('PRAGMA cipher_version;').first.values.first,
      isNotNull,
    );
    expect(
      database.select('SELECT count(*) FROM sqlite_master;'),
      hasLength(1),
    );
    database.close();
  });

  test('database cannot be opened with a different encryption key', () async {
    await store.createPending(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00001',
    );
    await store.close();

    final wrongKeyStore = MemorySecureValueStore()
      ..values[SecureAttendanceStore.encryptionKeyName] = '0' * 64;
    await expectLater(openStore(keyStore: wrongKeyStore), throwsA(anything));
  });

  test('missing key never replaces an existing encrypted database', () async {
    await store.createPending(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00002',
    );
    await store.close();

    await expectLater(
      openStore(keyStore: MemorySecureValueStore()),
      throwsA(isA<StateError>()),
    );
    expect(await File(databasePath).exists(), isTrue);
  });

  test('pending records survive close and reopen with the same UUID', () async {
    final saved = await store.createPending(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: '00001234',
    );
    await store.close();
    store = await openStore();

    final pending = await store.readPending();
    expect(pending, hasLength(1));
    expect(pending.single.scanId, saved.scanId);
    expect(pending.single.studentId, '00001234');
    expect(pending.single.eventId, 'event-a');
    expect(pending.single.checkpointId, 'checkpoint-a');
    expect(pending.single.staffUserId, 'staff-a');
  });

  test(
    'receipt outcomes and replay metadata persist without normalization',
    () async {
      final accepted = await store.createPending(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: '00000001',
      );
      final rejected = await store.createPending(
        eventId: 'event-a',
        checkpointId: 'checkpoint-b',
        studentId: 'Student-AbC',
      );
      final duplicate = await store.createPending(
        eventId: 'event-b',
        checkpointId: 'checkpoint-c',
        studentId: 'A-0003',
      );

      const timestamp = '2026-11-08T02:15:00.123Z';
      await store.recordReceipt(
        scanId: accepted.scanId,
        outcome: ScanStatus.accepted,
        receivedAt: timestamp,
        replayed: true,
      );
      await store.recordReceipt(
        scanId: rejected.scanId,
        outcome: ScanStatus.rejected,
        receivedAt: timestamp,
        replayed: false,
      );
      await store.recordReceipt(
        scanId: duplicate.scanId,
        outcome: ScanStatus.duplicate,
        receivedAt: timestamp,
        replayed: true,
      );

      final records = await store.readRecent(limit: 10);
      expect(records.map((record) => record.status), [
        ScanStatus.duplicate,
        ScanStatus.rejected,
        ScanStatus.accepted,
      ]);
      expect(records.first.replayed, isTrue);
      expect(records.first.receivedAt, timestamp);
      expect(records.last.studentId, '00000001');
      expect(await store.readPending(), isEmpty);
      expect(await store.hasUnresolvedRecords(), isFalse);
    },
  );

  test('blocked conflicts remain unresolved and cannot be retried', () async {
    final saved = await store.createPending(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00004',
    );
    await store.markBlocked(saved.scanId);
    expect(await store.findPending(saved.scanId), isNull);
    expect(await store.hasUnresolvedRecords(), isTrue);
    expect((await store.readRecent()).single.status, ScanStatus.blocked);
  });

  test('account isolation prevents reads and mutations', () async {
    final accountA = await store.createPending(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00005',
    );
    await store.close();

    final accountB = await openStore(staffId: 'staff-b');
    expect(await accountB.readRecent(), isEmpty);
    expect(await accountB.readPending(), isEmpty);
    expect(await accountB.hasUnresolvedRecords(), isFalse);
    expect(await accountB.findPending(accountA.scanId), isNull);
    await expectLater(
      accountB.recordReceipt(
        scanId: accountA.scanId,
        outcome: ScanStatus.accepted,
        receivedAt: '2026-11-08T02:15:00Z',
        replayed: false,
      ),
      throwsStateError,
    );
    await expectLater(accountB.markBlocked(accountA.scanId), throwsStateError);
    await accountB.close();

    store = await openStore(staffId: 'staff-a');
    expect((await store.readPending()).single.scanId, accountA.scanId);
  });

  test(
    'legacy plaintext records migrate as unassigned and never appear to Staff',
    () async {
      const markers = [
        'LEGACY-SYNTHETIC-00006',
        'LEGACY-SYNTHETIC-00007',
        'LEGACY-SYNTHETIC-00008',
      ];
      final legacy = sqlite3.open(legacyPath);
      legacy.execute('''
      CREATE TABLE provisional_scans (
        id TEXT PRIMARY KEY,
        event_id TEXT NOT NULL,
        credential_value TEXT NOT NULL,
        status TEXT NOT NULL
      );
    ''');
      for (var index = 0; index < markers.length; index++) {
        legacy.execute('INSERT INTO provisional_scans VALUES (?, ?, ?, ?);', [
          'legacy-scan-${index + 1}',
          'legacy-event-${index + 1}',
          markers[index],
          ['pending', 'accepted', 'rejected'][index],
        ]);
      }
      legacy.close();

      await store.close();
      store = await openStore();
      expect(await File(legacyPath).exists(), isFalse);
      expect(await store.readRecent(), isEmpty);
      expect(await store.readPending(), isEmpty);
      expect(await store.hasUnresolvedRecords(), isFalse);

      await store.close();
      final encrypted = sqlite3.open(databasePath);
      final key = secrets.values[SecureAttendanceStore.encryptionKeyName]!;
      encrypted.execute("PRAGMA key = \"x'$key'\";");
      for (var index = 0; index < markers.length; index++) {
        final rows = encrypted.select(
          '''
        SELECT event_id, checkpoint_id, student_id, staff_user_id,
          submission_status, legacy, legacy_status
        FROM attendance_scans WHERE scan_id = ?;
      ''',
          ['legacy-scan-${index + 1}'],
        );
        expect(rows, hasLength(1));
        expect(rows.single['event_id'], 'legacy-event-${index + 1}');
        expect(rows.single['checkpoint_id'], isNull);
        expect(rows.single['student_id'], markers[index]);
        expect(rows.single['staff_user_id'], isNull);
        expect(rows.single['submission_status'], 'legacy');
        expect(rows.single['legacy'], 1);
        expect(
          rows.single['legacy_status'],
          ['pending', 'accepted', 'rejected'][index],
        );
      }
      encrypted.close();

      final raw = await File(databasePath).readAsBytes();
      final rawText = latin1.decode(raw, allowInvalid: true);
      for (final marker in markers) {
        expect(rawText, isNot(contains(marker)));
      }
    },
  );

  test(
    'failed legacy migration preserves the original plaintext database',
    () async {
      final legacy = sqlite3.open(legacyPath);
      legacy.execute('CREATE TABLE unrelated (value TEXT);');
      legacy.close();

      await store.close();
      await expectLater(openStore(), throwsA(isA<StateError>()));
      expect(await File(legacyPath).exists(), isTrue);
    },
  );

  test('rejects malformed Student IDs without persisting them', () async {
    for (final value in [
      '',
      ' 0001',
      '0001 ',
      'https://example.test/1',
      'A_B',
    ]) {
      await expectLater(
        store.createPending(
          eventId: 'event-a',
          checkpointId: 'checkpoint-a',
          studentId: value,
        ),
        throwsArgumentError,
      );
    }
    expect(await store.readRecent(), isEmpty);
  });
}
