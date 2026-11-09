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
  late List<String> authorizationTokens;

  Future<void> setupGateway({
    required Future<dynamic> Function(Map<String, dynamic>) ingest,
  }) async {
    gateway = SupabaseStaffScanGateway.test(
      currentStaffId: () => currentStaffId,
      currentSession: () async => currentStaffId == null
          ? null
          : StaffScanSession(
              staffUserId: currentStaffId!,
              accessToken: 'token-${currentStaffId!}',
            ),
      ingest: (parameters, token) {
        requests.add(Map<String, dynamic>.from(parameters));
        authorizationTokens.add(token);
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
    authorizationTokens = [];
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
        studentId: '00000123456',
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
      expect(requests.single['p_student_id'], '00000123456');
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
        studentId: '00000123456',
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
      expect(await openedStore.hasUnresolvedRecords(), code != '22023');
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
    expect(await openedStore.hasUnresolvedRecords(), isFalse);
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
    final accountSwitch = Completer<void>();
    gateway = SupabaseStaffScanGateway.test(
      currentStaffId: () {
        staffIdReads++;
        if (staffIdReads == 3) {
          scheduleMicrotask(() {
            activeStaff = 'staff-b';
            unawaited(
              gateway
                  .openForAccount('staff-b')
                  .then(
                    (_) => accountSwitch.complete(),
                    onError: (Object error, StackTrace stackTrace) =>
                        accountSwitch.completeError(error, stackTrace),
                  ),
            );
          });
        }
        return activeStaff;
      },
      currentSession: () async => activeStaff == null
          ? null
          : StaffScanSession(
              staffUserId: activeStaff!,
              accessToken: 'token-${activeStaff!}',
            ),
      ingest: (parameters, token) async {
        requests.add(Map<String, dynamic>.from(parameters));
        authorizationTokens.add(token);
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
    await accountSwitch.future;

    expect(requests, isEmpty);
    expect(await gateway.readRecent(), isEmpty);
    expect(activeStaff, 'staff-b');
  });

  test('synthetic roster ID is allowed with leading zeros', () async {
    await setupGateway(ingest: (request) async => receipt(request));
    final result = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: '00000123456',
    );
    expect(result.record?.studentId, '00000123456');
    expect(requests.single['p_student_id'], '00000123456');
    expect(authorizationTokens, ['token-staff-a']);
  });

  test('non-synthetic valid IDs are rejected before storage or RPC', () async {
    await setupGateway(ingest: (request) async => receipt(request));
    for (final value in ['00012345', '202611091234', 'HNU-2026-123']) {
      final result = await gateway.capture(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: value,
      );
      expect(result.record, isNull);
      expect(result.retryAllowed, isFalse);
      expect(result.message, isNot(contains(value)));
    }
    expect(await openedStore.readRecent(), isEmpty);
    expect(requests, isEmpty);
    expect(authorizationTokens, isEmpty);
  });

  test('capture aborts when the session belongs to another Staff', () async {
    gateway = SupabaseStaffScanGateway.test(
      currentStaffId: () => 'staff-a',
      currentSession: () async => const StaffScanSession(
        staffUserId: 'staff-b',
        accessToken: 'token-staff-b',
      ),
      ingest: (parameters, token) async {
        requests.add(Map<String, dynamic>.from(parameters));
        authorizationTokens.add(token);
        return receipt(parameters);
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
    await gateway.openForAccount('staff-a');
    final result = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: '00000123456',
    );
    expect(result.record?.status, ScanStatus.pending);
    expect((await openedStore.readPending()).single.scanId, result.record!.scanId);
    expect(requests, isEmpty);
    expect(authorizationTokens, isEmpty);
  });

  test('in-flight capture keeps the original bearer and pending evidence', () async {
    final inFlight = Completer<dynamic>();
    final sent = Completer<void>();
    await setupGateway(ingest: (request) {
      sent.complete();
      return inFlight.future;
    });
    final operation = gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: '00000123456',
    );
    await sent.future;
    final scanId = requests.single['p_scan_id'];
    expect(authorizationTokens, ['token-staff-a']);
    currentStaffId = 'staff-b';
    inFlight.complete(receipt(requests.single));
    final result = await operation;
    expect(result.record?.status, ScanStatus.pending);
    expect(result.record?.scanId, scanId);
    expect((await openedStore.readPending()).single.scanId, scanId);
    expect(await openedStore.findPending(scanId), isNotNull);
  });

  test('account change before retry never submits as the next account', () async {
    await setupGateway(
      ingest: (_) async => throw TimeoutException('synthetic timeout'),
    );
    final initial = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: '00000123456',
    );
    currentStaffId = 'staff-b';
    await expectLater(gateway.retry(initial.record!.scanId), throwsStateError);
    expect(authorizationTokens, ['token-staff-a']);
    expect((await openedStore.readPending()).single.scanId, initial.record!.scanId);
  });

  test('in-flight retry preserves the original Staff identity', () async {
    final inFlight = Completer<dynamic>();
    final retrySent = Completer<void>();
    var callCount = 0;
    await setupGateway(ingest: (request) {
      callCount++;
      if (callCount == 1) throw TimeoutException('synthetic timeout');
      retrySent.complete();
      return inFlight.future;
    });
    final first = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: '00000123456',
    );
    final retry = gateway.retry(first.record!.scanId);
    await retrySent.future;
    currentStaffId = 'staff-b';
    inFlight.complete(receipt(requests.last, replayed: true));
    final result = await retry;
    expect(result.record?.status, ScanStatus.pending);
    expect(requests, hasLength(2));
    expect(requests.first, requests.last);
    expect(authorizationTokens, ['token-staff-a', 'token-staff-a']);
    expect((await openedStore.readPending()).single.scanId, first.record!.scanId);
  });

  test('sign-out in-flight leaves a pending record with no receipt', () async {
    final inFlight = Completer<dynamic>();
    final sent = Completer<void>();
    await setupGateway(ingest: (request) {
      sent.complete();
      return inFlight.future;
    });
    final operation = gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: '00000123456',
    );
    await sent.future;
    currentStaffId = null;
    inFlight.complete(receipt(requests.single));
    final result = await operation;
    expect(result.record?.status, ScanStatus.pending);
    expect(authorizationTokens, ['token-staff-a']);
    expect((await openedStore.readPending()).single.scanId, result.record!.scanId);
  });

  test('terminal blocked evidence permits only unrelated captures', () async {
    var count = 0;
    await setupGateway(ingest: (request) async {
      count++;
      if (count == 1) {
        throw PostgrestException(
          message: 'synthetic conflict',
          code: '23505',
        );
      }
      return receipt(request);
    });
    final blocked = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00003',
    );
    expect(blocked.record?.status, ScanStatus.blocked);
    expect(await gateway.hasUnresolvedRecords(), isFalse);
    await expectLater(
      gateway.capture(
        eventId: 'event-a',
        checkpointId: 'checkpoint-a',
        studentId: 'SYNTHETIC-00003',
      ),
      throwsStateError,
    );
    final next = await gateway.capture(
      eventId: 'event-a',
      checkpointId: 'checkpoint-a',
      studentId: 'SYNTHETIC-00004',
    );
    expect(next.record?.status, ScanStatus.accepted);
    expect(requests, hasLength(2));
    final records = await openedStore.readRecent();
    expect(records.map((item) => item.scanId), contains(blocked.record!.scanId));
    expect((await openedStore.readRecent()).first.status, ScanStatus.blocked);
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
