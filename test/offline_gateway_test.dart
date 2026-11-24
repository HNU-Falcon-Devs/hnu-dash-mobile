import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/offline_capture.dart';
import 'package:hnu_dash_mobile/scan_ingestion.dart';
import 'package:hnu_dash_mobile/secure_attendance_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_fixture.dart';

void main() {
  late Directory directory;
  late MemorySecureValues keys;
  late OfflineFixture fixture;
  late SupabaseStaffScanGateway gateway;
  late SecureAttendanceStore store;
  late String account;
  late List<Map<String, dynamic>> prepares;
  late List<Map<String, dynamic>> uploads;
  late AttendanceScanRpc prepareHandler;
  late AttendanceScanRpc uploadHandler;
  late int onlineCalls;

  Future<void> open(String staff) async {
    account = staff;
    await gateway.openForAccount(staff);
  }

  Future<String> prepare() => gateway.prepareOffline(
    eventId: eventId,
    assignmentId: assignmentA,
    title: 'Synthetic Assembly',
    starts: fixture.starts,
    ends: fixture.ends,
    cutoff: fixture.cutoff,
    checkpoints: [fixture.checkpoint],
  );

  OfflineClaim queue(String student) => gateway.captureOffline(
    preparationId: preparationA,
    checkpointId: checkpointId,
    studentId: student,
  );

  Future<String> sync({
    String preparationId = preparationA,
    bool Function()? continuing,
  }) => gateway.syncOffline(
    (_) {},
    preparationId: preparationId,
    shouldContinue: continuing ?? () => true,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('offline-gateway-');
    keys = MemorySecureValues();
    prepares = [];
    uploads = [];
    onlineCalls = 0;
    gateway = SupabaseStaffScanGateway.test(
      currentStaffId: () => account,
      currentSession: () async =>
          StaffScanSession(staffUserId: account, accessToken: 'token-$account'),
      ingest: (_, _) async {
        onlineCalls++;
        throw TimeoutException('synthetic');
      },
      prepare: (params, token) async {
        expect(token, 'token-$staffA');
        prepares.add(Map.of(params));
        return prepareHandler(params, token);
      },
      upload: (params, token) async {
        expect(token, 'token-$staffA');
        uploads.add(Map.of(params));
        return uploadHandler(params, token);
      },
      openStore: (staff) async {
        store = await SecureAttendanceStore.open(
          databasePath: '${directory.path}/evidence.db',
          legacyDatabasePath: '${directory.path}/legacy.db',
          keyStore: keys,
          staffUserId: staff,
        );
        return store;
      },
    );
    await open(staffA);
    fixture = OfflineFixture(DateTime.now().toUtc());
    prepareHandler = (params, _) async => fixture.response(
      params['p_request_id'] as String,
      serverIssued: DateTime.now().toUtc(),
    );
    uploadHandler = (params, _) async => acknowledgement(params);
  });

  tearDown(() async {
    await gateway.close();
    await directory.delete(recursive: true);
  });

  test('lost preparation response reuses the durable request UUID', () async {
    Map<String, Object>? original;
    prepareHandler = (params, _) async {
      final id = params['p_request_id'] as String;
      expect(store.offlineRequest(eventId, assignmentA).id, id);
      if (original == null) {
        original = fixture.response(id, serverIssued: DateTime.now().toUtc());
        throw TimeoutException('response lost');
      }
      return {...original!, 'replayed': true};
    };
    await prepare();
    expect(gateway.activePreparation, isNull);
    await prepare();
    expect(prepares, hasLength(2));
    expect(prepares[0], prepares[1]);
    expect(gateway.activePreparation?.id, preparationA);
  });

  test('restart recovery cannot establish a new capture time anchor', () async {
    Map<String, Object>? original;
    prepareHandler = (params, _) async {
      if (original == null) {
        original = fixture.response(
          params['p_request_id'] as String,
          serverIssued: DateTime.now().toUtc(),
        );
        throw TimeoutException('response lost');
      }
      return {...original!, 'replayed': true};
    };
    await prepare();
    await gateway.close();
    await open(staffA);
    await prepare();
    expect(prepares[0], prepares[1]);
    expect(gateway.activePreparation, isNull);
    expect(() => queue('SYNTHETIC-A'), throwsA(isA<OfflineCaptureException>()));
  });

  test('malformed and lost acknowledgements retain exact payload', () async {
    await prepare();
    queue('SYNTHETIC-A');
    queue('SYNTHETIC-B');
    uploadHandler = (_, _) async => throw TimeoutException('response lost');
    await sync();
    expect(gateway.offlineCounts().queued, 2);
    uploadHandler = (_, _) async => {'status': 'submitted'};
    await sync();
    expect(gateway.offlineCounts().queued, 2);
    uploadHandler = (params, _) async =>
        acknowledgement(params, replayed: true);
    await sync();
    expect(uploads, hasLength(4));
    expect(uploads[0], uploads[1]);
    expect(uploads[1], uploads[2]);
    expect(uploads[2], isNot(uploads[3]));
    expect(gateway.offlineCounts().submitted, 2);
    expect(gateway.offlineCounts().queued, 0);
    expect(onlineCalls, 0);
  });

  test('terminal conflict is retained and pauses sequential upload', () async {
    await prepare();
    queue('SYNTHETIC-A');
    queue('SYNTHETIC-B');
    uploadHandler = (_, _) async =>
        throw const PostgrestException(message: 'conflict', code: '23505');
    await sync();
    expect(uploads, hasLength(1));
    expect(gateway.offlineCounts().blocked, 1);
    expect(gateway.offlineCounts().queued, 1);
    uploadHandler = (params, _) async => acknowledgement(params);
    await sync();
    expect(uploads, hasLength(2));
    expect(gateway.offlineCounts().blocked, 1);
    expect(gateway.offlineCounts().submitted, 1);
  });

  test('state or authorization denial preserves an original upload', () async {
    await prepare();
    final claim = queue('SYNTHETIC-A');
    for (final code in ['55000', '42501']) {
      uploadHandler = (_, _) async =>
          throw PostgrestException(message: 'synthetic denial', code: code);
      await sync();
      expect(gateway.activePreparation, isNull);
      expect(gateway.offlineCounts().queued, 1);
      expect(
        store.readQueuedOffline(preparationA).single.parameters,
        claim.parameters,
      );
    }
    uploadHandler = (params, _) async =>
        acknowledgement(params, replayed: true);
    await sync();
    expect(uploads, hasLength(3));
    expect(
      uploads.every((payload) => payload['p_capture_id'] == claim.id),
      isTrue,
    );
    expect(uploads[0], uploads[1]);
    expect(uploads[1], uploads[2]);
    expect(gateway.offlineCounts().submitted, 1);
    expect(gateway.offlineCounts().queued, 0);
  });

  test(
    'denied historical preparation cannot starve another selection',
    () async {
      final historical = OfflineFixture(
        fixture.issued.subtract(const Duration(days: 2)),
        assignment: assignmentB,
        preparation: preparationB,
        event: 'd0000000-0000-4000-8000-000000000002',
        checkpointIdentifier: 'e0000000-0000-4000-8000-000000000002',
      );
      final request = store.offlineRequest(
        historical.event,
        historical.assignment,
      );
      final old = historical.parse(request.id);
      store.saveOfflinePreparation(old);
      final denied = store.createOfflineClaim(
        guard: historical.guard(old),
        checkpointId: historical.checkpoint.id,
        studentId: 'SYNTHETIC-OLD',
      );
      await prepare();
      final first = queue('SYNTHETIC-NEW-A');
      final second = queue('SYNTHETIC-NEW-B');
      final groups = gateway.offlineSyncGroups();
      expect(groups.map((group) => group.id), [preparationB, preparationA]);
      expect(groups.map((group) => group.queued), [1, 2]);
      var denialCode = '55000';
      uploadHandler = (params, _) async {
        if (params['p_preparation_id'] == preparationB) {
          throw PostgrestException(
            message: 'synthetic denial',
            code: denialCode,
          );
        }
        return acknowledgement(params);
      };
      await sync(preparationId: preparationB);
      denialCode = '42501';
      await sync(preparationId: preparationB);
      expect(uploads, [denied.parameters, denied.parameters]);
      expect(gateway.offlineCounts().queued, 3);
      await sync();
      expect(uploads, [
        denied.parameters,
        denied.parameters,
        first.parameters,
        second.parameters,
      ]);
      expect(gateway.offlineCounts().queued, 1);
      expect(gateway.offlineCounts().submitted, 2);
      expect(
        store.readQueuedOffline(preparationB).single.parameters,
        denied.parameters,
      );
      expect(gateway.offlineSyncGroups().single.id, preparationB);
      await open(staffB);
      expect(gateway.offlineSyncGroups(), isEmpty);
      await sync(preparationId: preparationB);
      expect(uploads, hasLength(4));
      await open(staffA);
      expect(
        store.readQueuedOffline(preparationB).single.parameters,
        denied.parameters,
      );
    },
  );

  test(
    'account switch during preparation retains only the original request',
    () async {
      final dispatched = Completer<void>();
      final response = Completer<dynamic>();
      prepareHandler = (_, _) {
        dispatched.complete();
        return response.future;
      };
      final pending = prepare();
      final checked = expectLater(pending, throwsStateError);
      await dispatched.future;
      final original = prepares.single['p_request_id'] as String;
      await open(staffB);
      expect(gateway.activePreparation, isNull);
      expect(gateway.offlineSyncGroups(), isEmpty);
      await open(staffA);
      response.complete(fixture.response(original));
      await checked;
      expect(gateway.activePreparation, isNull);
      expect(store.offlineRequest(eventId, assignmentA).id, original);
      prepareHandler = (params, _) async =>
          fixture.response(params['p_request_id'] as String, replayed: true);
      await prepare();
      expect(prepares[0], prepares[1]);
      expect(gateway.activePreparation, isNull);
      expect(gateway.offlineCounts().queued, 0);
    },
  );

  test('foreground stop retains the remaining claim', () async {
    await prepare();
    queue('SYNTHETIC-A');
    queue('SYNTHETIC-B');
    var foreground = true;
    uploadHandler = (params, _) async {
      foreground = false;
      return acknowledgement(params);
    };
    await sync(continuing: () => foreground);
    expect(uploads, hasLength(1));
    expect(gateway.offlineCounts().queued, 1);
    foreground = true;
    await sync(continuing: () => foreground);
    expect(gateway.offlineCounts().submitted, 2);
  });

  test('account switch cannot acknowledge a late upload', () async {
    await prepare();
    queue('SYNTHETIC-A');
    final dispatched = Completer<void>();
    final response = Completer<dynamic>();
    uploadHandler = (_, _) {
      dispatched.complete();
      return response.future;
    };
    final pending = sync();
    final checked = expectLater(pending, throwsStateError);
    await dispatched.future;
    await open(staffB);
    expect(gateway.offlineCounts().queued, 0);
    response.complete(acknowledgement(uploads.single));
    await checked;
    await open(staffA);
    expect(gateway.offlineCounts().queued, 1);
    expect(gateway.activePreparation, isNull);
    uploadHandler = (params, _) async =>
        acknowledgement(params, replayed: true);
    await sync();
    expect(uploads[0], uploads[1]);
    expect(gateway.offlineCounts().submitted, 1);
  });
}
