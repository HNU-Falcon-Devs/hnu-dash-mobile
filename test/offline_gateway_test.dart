import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/offline_capture.dart';
import 'package:hnu_dash_mobile/offline_completion.dart';
import 'package:hnu_dash_mobile/scan_ingestion.dart';
import 'package:hnu_dash_mobile/secure_attendance_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_fixture.dart';
import 'completion_fixture.dart';

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
  late AttendanceScanRpc statusHandler;
  late AttendanceScanRpc completionHandler;
  late List<Map<String, dynamic>> declarations;
  late List<Map<String, dynamic>> statusRequests;
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
    declarations = [];
    statusRequests = [];
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
      status: (params, token) async {
        expect(token, 'token-$staffA');
        statusRequests.add(Map.of(params));
        return statusHandler(params, token);
      },
      complete: (params, token) async {
        expect(token, 'token-$staffA');
        declarations.add(Map.of(params));
        return completionHandler(params, token);
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
    statusHandler = (params, _) async {
      final id = params['p_preparation_id'] as String;
      final item = store.preparationSummary(id);
      return statusResponse(item.preparation, uploaded: item.counts.submitted);
    };
    completionHandler = (params, _) async {
      final id = params['p_preparation_id'] as String;
      final item = store.preparationSummary(id);
      final count = params['p_acknowledged_count'] as int;
      expect(item.intent, count);
      return completionResponse(item.preparation, count);
    };
  });

  tearDown(() async {
    await gateway.close();
    await directory.delete(recursive: true);
  });

  Future<String> complete(int count, {String id = preparationA}) =>
      gateway.completePreparation(id, count, () => true);

  test('zero and nonzero explicit completion persist exact counts', () async {
    await prepare();
    expect(gateway.preparations().single.counts.submitted, 0);
    await complete(0);
    final zero = store.preparationSummary(preparationA);
    expect(zero.intent, 0);
    expect(zero.accounting?.disposition, 'completed');
    expect(declarations.single, {
      'p_preparation_id': preparationA,
      'p_acknowledged_count': 0,
    });
    expect(() => queue('SYNTHETIC-LATE'), throwsA(isA<OfflineCaptureException>()));
    final other = OfflineFixture(
      fixture.issued,
      assignment: assignmentB,
      preparation: preparationB,
      event: 'd0000000-0000-4000-8000-000000000002',
      checkpointIdentifier: 'e0000000-0000-4000-8000-000000000002',
    );
    final request = store.offlineRequest(other.event, other.assignment);
    final prep = other.parse(request.id);
    store.saveOfflinePreparation(prep);
    final claim = store.createOfflineClaim(
      guard: other.guard(prep), checkpointId: other.checkpoint.id,
      studentId: 'SYNTHETIC-OTHER',
    );
    await sync(preparationId: preparationB);
    await complete(1, id: preparationB);
    expect(store.preparationSummary(preparationB).accounting?.declared, 1);
    expect(store.preparationSummary(preparationA).accounting?.declared, 0);
    expect(uploads.single, claim.parameters);
  });

  test('queued blocked and server count mismatch never dispatch completion', () async {
    await prepare();
    final claim = queue('SYNTHETIC-PENDING');
    await complete(0);
    expect(declarations, isEmpty);
    store.blockOffline(claim);
    await complete(0);
    expect(declarations, isEmpty);
    expect(store.preparationSummary(preparationA).intent, isNull);
  });

  test('server-only evidence count cannot become a local declaration', () async {
    await prepare();
    final prep = store.preparationSummary(preparationA).preparation;
    statusHandler = (_, _) async => statusResponse(prep, uploaded: 1);
    await complete(0);
    await complete(1);
    expect(declarations, isEmpty);
    expect(store.preparationSummary(preparationA).intent, isNull);
  });

  test('after-seal completion allows zero count without reopening uploads', () async {
    await prepare();
    final prep = store.preparationSummary(preparationA).preparation;
    statusHandler = (_, _) async =>
        statusResponse(prep, sealed: true, state: 'SYNCING');
    await complete(0);
    expect(store.preparationSummary(preparationA).accounting?.declared, 0);
    expect(gateway.activePreparation, isNull);
    expect(uploads, isEmpty);
  });

  test('lost and malformed completion retains immutable intent across restart', () async {
    await prepare();
    queue('SYNTHETIC-A');
    await sync();
    completionHandler = (_, _) async => throw TimeoutException('lost response');
    await complete(1);
    expect(store.preparationSummary(preparationA).intent, 1);
    expect(store.preparationSummary(preparationA).accounting, isNull);
    expect(gateway.activePreparation, isNull);
    await gateway.close();
    await open(staffA);
    await complete(0);
    expect(declarations, hasLength(1));
    completionHandler = (_, _) async => {'disposition': 'completed'};
    await complete(1);
    expect(store.preparationSummary(preparationA).accounting, isNull);
    completionHandler = (params, _) async => completionResponse(
      store.preparationSummary(preparationA).preparation,
      params['p_acknowledged_count'] as int,
      replayed: true,
    );
    await complete(1);
    expect(declarations, hasLength(3));
    expect(declarations.every((p) => p['p_acknowledged_count'] == 1), isTrue);
    expect(store.preparationSummary(preparationA).accounting?.declared, 1);
    expect(gateway.offlineCounts().submitted, 1);
    expect(gateway.activePreparation, isNull);
  });

  test('authoritative status recovers completion or loss but never renews capture', () async {
    await prepare();
    final prep = store.preparationSummary(preparationA).preparation;
    completionHandler = (_, _) async => throw TimeoutException('lost response');
    await complete(0);
    statusHandler = (_, _) async =>
        statusResponse(prep, disposition: 'completed');
    final status = await gateway.preparationStatus(preparationA, () => true);
    expect(status.accounting?.declared, 0);
    expect(store.preparationSummary(preparationA).intent, 0);
    expect(store.preparationSummary(preparationA).accounting?.disposition, 'completed');
    expect(await gateway.resumeOffline(preparationA, () => true), isFalse);
    expect(declarations, hasLength(1));
  });

  test('known loss retains queued claims and allows legitimate upload replay', () async {
    await prepare();
    final claim = queue('SYNTHETIC-A');
    final prep = store.preparationSummary(preparationA).preparation;
    statusHandler = (_, _) async =>
        statusResponse(prep, uploaded: 1, disposition: 'lost', sealed: true,
            state: 'SYNCING');
    await gateway.preparationStatus(preparationA, () => true);
    expect(store.preparationSummary(preparationA).accounting?.disposition, 'lost');
    expect(gateway.activePreparation, isNull);
    expect(await gateway.resumeOffline(preparationA, () => true), isFalse);
    await complete(0);
    expect(declarations, isEmpty);
    uploadHandler = (params, _) async => acknowledgement(params, replayed: true);
    await sync();
    expect(uploads.single, claim.parameters);
    expect(store.preparationSummary(preparationA).counts.submitted, 1);
  });

  test('resume requires valid status; denial and malformed response fail closed', () async {
    await prepare();
    final prep = store.preparationSummary(preparationA).preparation;
    gateway.suspendOffline();
    expect(gateway.canCaptureOffline(preparationA, checkpointId), isFalse);
    statusHandler = (_, _) async =>
        throw const PostgrestException(message: 'denied', code: '42501');
    await expectLater(gateway.resumeOffline(preparationA, () => true), throwsA(isA<PostgrestException>()));
    expect(gateway.canCaptureOffline(preparationA, checkpointId), isFalse);
    statusHandler = (_, _) async => {...statusResponse(prep), 'expires_at': prep.cutoff.toIso8601String()};
    await expectLater(gateway.resumeOffline(preparationA, () => true), throwsFormatException);
    expect(gateway.canCaptureOffline(preparationA, checkpointId), isFalse);
    statusHandler = (_, _) async => statusResponse(prep);
    expect(await gateway.resumeOffline(preparationA, () => true), isTrue);
    expect(gateway.canCaptureOffline(preparationA, checkpointId), isTrue);
    await gateway.close();
    await open(staffA);
    await gateway.preparationStatus(preparationA, () => true);
    expect(await gateway.resumeOffline(preparationA, () => true), isFalse);
    expect(gateway.canCaptureOffline(preparationA, checkpointId), isFalse);
  });

  test('late status and completion responses cannot cross A-B-A accounts', () async {
    await prepare();
    final prep = store.preparationSummary(preparationA).preparation;
    final dispatched = Completer<void>();
    final response = Completer<dynamic>();
    statusHandler = (_, _) {
      dispatched.complete();
      return response.future;
    };
    final pending = gateway.preparationStatus(preparationA, () => true);
    final checked = expectLater(pending, throwsStateError);
    await dispatched.future;
    await open(staffB);
    expect(gateway.preparations(), isEmpty);
    await expectLater(gateway.preparationStatus(preparationA, () => true), throwsStateError);
    await open(staffA);
    response.complete(statusResponse(prep, disposition: 'completed'));
    await checked;
    expect(store.preparationSummary(preparationA).accounting, isNull);
    statusHandler = (_, _) async => statusResponse(prep);
    final sent = Completer<void>();
    final reply = Completer<dynamic>();
    completionHandler = (_, _) {
      sent.complete();
      return reply.future;
    };
    final completing = complete(0);
    final completionCheck = expectLater(completing, throwsStateError);
    await sent.future;
    expect(store.preparationSummary(preparationA).intent, 0);
    await open(staffB);
    expect(gateway.preparations(), isEmpty);
    await open(staffA);
    reply.complete(completionResponse(prep, 0));
    await completionCheck;
    expect(store.preparationSummary(preparationA).intent, 0);
    expect(store.preparationSummary(preparationA).accounting, isNull);
  });

  test('strict status and completion response parsing rejects wrong scope and counts', () {
    final prep = fixture.parse(requestId);
    for (final bad in [
      {...statusResponse(prep), 'preparation_id': preparationB},
      {...statusResponse(prep), 'uploaded_count': -1},
      {...statusResponse(prep), 'uploaded_count': 9007199254740992},
      {...statusResponse(prep), 'uploaded_count': 1.0},
      {...statusResponse(prep), 'can_complete': 'true'},
      {...statusResponse(prep), 'declared_count': 0},
      {...statusResponse(prep), 'unexpected': true},
    ]) {
      expect(() => OfflinePreparationStatus.parse(bad, prep), throwsFormatException);
    }
    for (final bad in [
      {...completionResponse(prep, 0), 'accounted_by': staffB},
      {...completionResponse(prep, 0), 'uploaded_count': 1},
      {...completionResponse(prep, 0), 'replayed': 'true'},
      {...completionResponse(prep, 0), 'accounted_at': 'invalid'},
    ]) {
      expect(() => OfflineAccounting.acknowledgement(bad, prep, 0), throwsFormatException);
    }
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
