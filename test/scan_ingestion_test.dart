import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/scan_ingestion.dart';
import 'package:hnu_dash_mobile/secure_attendance_store.dart';
import 'package:hnu_dash_mobile/secure_value_store.dart';
import 'package:path/path.dart' as path;
import 'package:supabase_flutter/supabase_flutter.dart';

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
  late String? currentStaffId;
  late SecureAttendanceStore openedStore;
  late SupabaseStaffScanGateway gateway;
  late List<Map<String, dynamic>> requests;

  Future<void> setupGateway({
    required Future<dynamic> Function(Map<String, dynamic>) ingest,
  }) async {
    gateway = SupabaseStaffScanGateway.test(
      currentStaffId: () => currentStaffId,
      ingest: (parameters) {
        requests.add(Map<String, dynamic>.from(parameters));
        return ingest(parameters);
      },
      openStore: (staffId) async {
        openedStore = await SecureAttendanceStore.open(
          databasePath: databasePath,
          legacyDatabasePath: legacyPath,
          staffUserId: staffId,
          keyStore: secrets,
        );
        return openedStore;
      },
    );
    await gateway.openForAccount(currentStaffId!);
  }

  Map<String, dynamic> receipt(
    Map<String, dynamic> request, {
    String outcome = 'accepted',
    String timestamp = '2026-11-08T02:15:00Z',
    bool replayed = false,
  }) => {
    'scan_id': request['p_scan_id'],
    'outcome': outcome,
    'received_at': timestamp,
    'replayed': replayed,
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hnu-ingestion-test-');
    databasePath = path.join(directory.path, 'encrypted.db');
    legacyPath = path.join(directory.path, 'hnu_dash_scans.db');
    secrets = MemorySecureValueStore();
    currentStaffId = 'staff-a';
    requests = [];
  });

  tearDown(() async {
    await gateway.close();
    await directory.delete(recursive: true);
  });

  test(
    'submits the exact Backend RPC parameters and persists accepted receipt',
    () async {
      await setupGateway(ingest: (request) async => receipt(request));
      final result = await gateway.capture(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: '00001234',
      );

      expect(requests, hasLength(1));
      expect(requests.single.keys.toSet(), {
        'p_scan_id',
        'p_event_id',
        'p_checkpoint_id',
        'p_student_id',
      });
      expect(requests.single['p_event_id'], 'event-a');
      expect(requests.single['p_checkpoint_id'], 'checkpoint-a');
      expect(requests.single['p_student_id'], '00001234');
      expect(result.record?.status, ScanStatus.accepted);
      expect(result.message, contains('not finalized attendance'));
      final saved = await openedStore.readRecent();
      expect(saved.single.status, ScanStatus.accepted);
      expect(saved.single.receivedAt, '2026-11-08T02:15:00Z');
    },
  );

  test(
    'persists rejected and duplicate outcomes without exposing reasons',
    () async {
      var first = true;
      for (final outcome in ['rejected', 'duplicate']) {
        if (!first) await gateway.close();
        first = false;
        await setupGateway(
          ingest: (request) async =>
              receipt(request, outcome: outcome, replayed: true),
        );
        final result = await gateway.capture(
          eventId: 'event-$outcome',
          checkpointId: 'checkpoint-$outcome',
          studentId: 'SYNTHETIC-$outcome',
        );
        expect(result.record?.status.name, outcome);
        expect(result.record?.replayed, isTrue);
        if (outcome == 'rejected') {
          expect(result.message, contains('reason is not exposed'));
          expect(result.message, isNot(contains('roster')));
        } else {
          expect(result.message, contains('duplicate attempt'));
        }
      }
    },
  );

  test(
    'timeout preserves the same UUID and payload for explicit retry',
    () async {
      var firstCall = true;
      await setupGateway(
        ingest: (request) async {
          if (firstCall) {
            firstCall = false;
            throw TimeoutException('private transport detail');
          }
          return receipt(request, replayed: true);
        },
      );

      final initial = await gateway.capture(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: '00009876',
      );
      expect(initial.record?.status, ScanStatus.pending);
      expect(initial.message, contains('same scan ID'));
      expect(initial.message, isNot(contains('private transport detail')));

      final retry = await gateway.retry(initial.record!.scanId);
      expect(retry.record?.scanId, initial.record!.scanId);
      expect(retry.record?.status, ScanStatus.accepted);
      expect(retry.record?.replayed, isTrue);
      expect(requests, hasLength(2));
      expect(requests[1], requests[0]);
    },
  );

  test(
    'a pending attempt blocks another scan until manually resolved',
    () async {
      await setupGateway(
        ingest: (_) async => throw TimeoutException('network unavailable'),
      );
      final first = await gateway.capture(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: 'SYNTHETIC-00001',
      );
      final second = await gateway.capture(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: 'SYNTHETIC-00002',
      );
      expect(first.record?.status, ScanStatus.pending);
      expect(second.record, isNull);
      expect(requests, hasLength(1));
      expect(await gateway.hasUnresolvedRecords(), isTrue);
    },
  );

  test('Backend authorization and state errors remain pending', () async {
    var first = true;
    for (final code in ['42501', '55000', '22023', '40001']) {
      if (!first) await gateway.close();
      first = false;
      databasePath = path.join(directory.path, 'encrypted-$code.db');
      legacyPath = path.join(directory.path, 'legacy-$code.db');
      await setupGateway(
        ingest: (_) async => throw PostgrestException(
          message: 'synthetic internal error',
          code: code,
        ),
      );
      final result = await gateway.capture(
        eventId: 'event-$code',
        checkpointId: 'checkpoint-$code',
        studentId: 'SYNTHETIC-$code',
      );
      final expectedStatus = code == '22023'
          ? ScanStatus.blocked
          : ScanStatus.pending;
      expect(result.record?.status, expectedStatus);
      expect(result.retryAllowed, code != '22023');
      expect(result.message, isNot(contains('synthetic internal error')));
      expect(await openedStore.hasUnresolvedRecords(), isTrue);
    }
  });

  test('conflicting UUID is blocked and not automatically retried', () async {
    await setupGateway(
      ingest: (_) async => throw PostgrestException(
        message: 'synthetic unique conflict',
        code: '23505',
      ),
    );
    final result = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00003',
    );
    expect(result.record?.status, ScanStatus.blocked);
    expect(result.retryAllowed, isFalse);
    expect(await openedStore.hasUnresolvedRecords(), isTrue);
    expect(await openedStore.findPending(result.record!.scanId), isNull);
  });

  test('malformed Backend receipt remains pending', () async {
    await setupGateway(
      ingest: (_) async => {
        'scan_id': 'different-scan',
        'outcome': 'accepted',
        'received_at': 'not-a-date',
        'replayed': false,
      },
    );
    final result = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00004',
    );
    expect(result.record?.status, ScanStatus.pending);
    expect(await openedStore.hasUnresolvedRecords(), isTrue);
  });

  test(
    'account changes prevent an old account from submitting again',
    () async {
      await setupGateway(ingest: (request) async => receipt(request));
      currentStaffId = 'staff-b';
      await expectLater(
        gateway.capture(
          eventId: 'event-a',
          checkpointId: 'checkpoint-a',
          studentId: 'SYNTHETIC-00005',
        ),
        throwsStateError,
      );
      expect(requests, isEmpty);
    },
  );

  test('account switch during capture cannot cross accounts', () async {
    String? activeStaff = 'staff-a';
    var staffIdReads = 0;
    gateway = SupabaseStaffScanGateway.test(
      currentStaffId: () {
        staffIdReads++;
        if (staffIdReads == 3) {
          scheduleMicrotask(() {
            activeStaff = 'staff-b';
            unawaited(gateway.openForAccount('staff-b'));
          });
        }
        return activeStaff;
      },
      ingest: (parameters) async {
        requests.add(Map<String, dynamic>.from(parameters));
        return receipt(parameters);
      },
      openStore: (staffId) => SecureAttendanceStore.open(
        databasePath: databasePath,
        legacyDatabasePath: legacyPath,
        staffUserId: staffId,
        keyStore: secrets,
      ),
    );

    await gateway.openForAccount('staff-a');
    await expectLater(
      gateway.capture(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: 'SYNTHETIC-00007',
      ),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);

    expect(requests, isEmpty);
    expect(await gateway.readRecent(), isEmpty);
    expect(activeStaff, 'staff-b');
  });

  test('retry cannot read another Staff account pending record', () async {
    await setupGateway(
      ingest: (_) async => throw TimeoutException('synthetic timeout'),
    );
    final saved = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00006',
    );
    await gateway.close();
    currentStaffId = 'staff-b';
    await setupGateway(ingest: (request) async => receipt(request));

    final result = await gateway.retry(saved.record!.scanId);
    expect(result.record, isNull);
    expect(requests, hasLength(1));
    expect(requests.single['p_student_id'], 'SYNTHETIC-00006');
  });
}
