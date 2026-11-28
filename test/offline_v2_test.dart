import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/offline_capture.dart';
import 'package:hnu_dash_mobile/offline_v2.dart';
import 'package:hnu_dash_mobile/offline_v2_gateway.dart';
import 'package:hnu_dash_mobile/scan_ingestion.dart';
import 'package:hnu_dash_mobile/secure_attendance_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_fixture.dart';
import 'offline_v2_fixture_workspace.dart';

const organization = '91000000-0000-4000-8000-000000000001';
const eventV2 = '92000000-0000-4000-8000-000000000001';
const assignmentV2 = '93000000-0000-4000-8000-000000000001';
const preparationV2 = '94000000-0000-4000-8000-000000000001';
const checkpointV2 = '95000000-0000-4000-8000-000000000001';
const checkpointV2Out = '95000000-0000-4000-8000-000000000002';
final issued = DateTime.utc(2027, 1, 1);
final scope = V2Scope(
  eventId: eventV2,
  assignmentId: assignmentV2,
  organizationId: organization,
  checkpoints: [
    OfflineCheckpoint(
      checkpointV2,
      'Entrance',
      'IN',
      issued.add(const Duration(hours: 1)),
      issued.add(const Duration(hours: 2)),
    ),
    OfflineCheckpoint(
      checkpointV2Out,
      'Exit',
      'OUT',
      issued.add(const Duration(hours: 2)),
      issued.add(const Duration(hours: 3)),
    ),
  ],
);

V2Observation observation(
  int elapsed, {
  String? boot = 'boot_8',
  int? wallMs,
}) => V2Observation(
  elapsedMs: elapsed,
  boot: boot,
  wallAt: issued
      .add(Duration(milliseconds: wallMs ?? elapsed - 1200))
      .toIso8601String(),
);

Map<String, dynamic> prepResponse(
  String request, {
  bool replayed = false,
  String state = 'DRAFT',
}) => {
  'policy_version': 2,
  'preparation_id': preparationV2,
  'request_id': request,
  'event_id': eventV2,
  'organization_id': organization,
  'assignment_id': assignmentV2,
  'staff_user_id': staffA,
  'issued_at': issued.toIso8601String(),
  'assignment_assigned_at': issued
      .subtract(const Duration(minutes: 1))
      .toIso8601String(),
  'roster_frozen_at': issued
      .subtract(const Duration(minutes: 2))
      .toIso8601String(),
  'event_title': 'Synthetic assembly',
  'event_starts_at': issued.add(const Duration(minutes: 30)).toIso8601String(),
  'event_ends_at': issued.add(const Duration(hours: 4)).toIso8601String(),
  'prepared_event_state': state,
  'checkpoints': scope.checkpoints.map((c) => c.toJson()).toList(),
  'replayed': replayed,
};

class FakeClock {
  final samples = <V2Observation>[];

  Future<V2Observation> call() async => samples.removeAt(0);

  void pair(int qr, int confirmation, {String? boot = 'boot_8'}) {
    samples.addAll([
      observation(qr, boot: boot),
      observation(confirmation, boot: boot),
    ]);
  }
}

class FakeV2Backend {
  String state = 'DRAFT';
  bool sealed = false;
  int deadlineHours = 28;
  String? disposition;
  String? requestId;
  bool losePrepare = false;
  bool loseSubmit = false;
  bool loseComplete = false;
  bool malformedAck = false;
  String? denySubmit;
  bool denyStatus = false;
  Completer<void>? submitStarted;
  Completer<void>? releaseSubmit;
  final calls = <V2Rpc>[];
  final sent = <Map<String, dynamic>>[];
  final claims = <String, String>{};
  final completions = <int>[];
  void Function(Map<String, dynamic>)? beforePrepare;

  Map<String, dynamic> status() => {
    'policy_version': 2,
    'preparation_id': preparationV2,
    'event_state': state,
    'sync_deadline': ['DRAFT', 'OPEN'].contains(state)
        ? null
        : issued.add(Duration(hours: deadlineHours)).toIso8601String(),
    'sealed': sealed,
    'uploaded_count': claims.length,
    'disposition': disposition,
  };

  Future<dynamic> call(
    V2Rpc rpc,
    Map<String, dynamic> params,
    String bearer,
  ) async {
    expect(bearer, 'owner-token');
    calls.add(rpc);
    switch (rpc) {
      case V2Rpc.prepare:
        beforePrepare?.call(params);
        expect(params['p_event_id'], eventV2);
        expect(params['p_assignment_id'], assignmentV2);
        final request = params['p_request_id'] as String;
        final replay = requestId != null;
        if (replay) expect(request, requestId);
        requestId = request;
        if (losePrepare) {
          losePrepare = false;
          throw TimeoutException('synthetic lost response');
        }
        return prepResponse(request, replayed: replay, state: state);
      case V2Rpc.status:
        expect(params, {'p_preparation_id': preparationV2});
        if (denyStatus) {
          throw const PostgrestException(message: 'denied', code: '42501');
        }
        return status();
      case V2Rpc.submit:
        sent.add(Map<String, dynamic>.from(params));
        final id = params['p_capture_id'] as String;
        final payload = jsonEncode(params);
        final previous = claims[id];
        if (denySubmit != null) {
          throw PostgrestException(
            message: 'synthetic denial',
            code: denySubmit,
          );
        }
        if (previous == null) {
          if (state != 'SYNCING' || sealed || disposition != null) {
            throw const PostgrestException(message: 'closed', code: '55000');
          }
          claims[id] = payload;
        } else {
          expect(payload, previous);
        }
        submitStarted?.complete();
        if (releaseSubmit != null) await releaseSubmit!.future;
        if (loseSubmit) {
          loseSubmit = false;
          throw TimeoutException('synthetic lost response');
        }
        return {
          'policy_version': malformedAck ? 1 : 2,
          'preparation_id': preparationV2,
          'capture_id': id,
          'status': 'submitted',
          'received_at': issued.add(const Duration(hours: 5)).toIso8601String(),
          'replayed': previous != null,
        };
      case V2Rpc.complete:
        final count = params['p_acknowledged_count'] as int;
        expect(count, claims.length);
        completions.add(count);
        final replay = disposition == 'completed';
        disposition = 'completed';
        if (loseComplete) {
          loseComplete = false;
          throw TimeoutException('synthetic lost response');
        }
        return {
          'policy_version': 2,
          'preparation_id': preparationV2,
          'disposition': 'completed',
          'uploaded_count': count,
          'declared_count': count,
          'reason': null,
          'accounted_at': issued
              .add(const Duration(hours: 6))
              .toIso8601String(),
          'accounted_by': staffA,
          'replayed': replay,
        };
    }
  }
}

void main() {
  test('B1 response validates policy, exact scope, and DRAFT/OPEN context', () {
    for (final state in ['DRAFT', 'OPEN']) {
      final raw = prepResponse(requestId, state: state);
      expect(
        V2Preparation.parse(raw, scope, staffA, requestId).id,
        preparationV2,
      );
      for (final invalid in [
        {...raw, 'policy_version': 1},
        {...raw, 'staff_user_id': staffB},
        {...raw, 'assignment_id': assignmentB},
        {...raw, 'checkpoints': []},
        {...raw, 'prepared_event_state': 'SYNCING'},
        {...raw, 'issued_at': '2027-01-01T00:00:00'},
        {...raw, 'unexpected': true},
      ]) {
        expect(
          () => V2Preparation.parse(invalid, scope, staffA, requestId),
          throwsFormatException,
        );
      }
    }
  });

  test('ten-key evidence preserves observations and uncertainty', () {
    final anchor = V2Anchor(observation(1000), observation(1200), 'original');
    final good = anchor.evidence(issued, observation(3200), observation(3400));
    validateV2Clock(good);
    expect(good, {
      'anchor_request_elapsed_ms': 1000,
      'anchor_response_elapsed_ms': 1200,
      'qr_elapsed_ms': 3200,
      'confirmation_elapsed_ms': 3400,
      'qr_wall_at': '2027-01-01T00:00:02.000Z',
      'confirmation_wall_at': '2027-01-01T00:00:02.200Z',
      'anchor_boot_marker': 'boot_8',
      'capture_boot_marker': 'boot_8',
      'anchor_provenance': 'original',
      'anomaly': 'none',
    });
    expect(
      anchor.evidence(
        issued,
        observation(3200, boot: 'boot_9'),
        observation(3400, boot: 'boot_9'),
      )['anomaly'],
      'reboot',
    );
    expect(
      anchor.evidence(
        issued,
        observation(3200, boot: null),
        observation(3400),
      )['anomaly'],
      'missing',
    );
    expect(
      anchor.evidence(
        issued,
        observation(3200, wallMs: 100000),
        observation(3400),
      )['anomaly'],
      'clock_jump',
    );
    expect(
      anchor.evidence(issued, observation(3200), observation(40000))['anomaly'],
      'inconsistent',
    );
    final replay = V2Anchor(
      observation(1000),
      null,
      'replayed',
    ).evidence(issued, observation(3200), observation(3400));
    expect(replay['anchor_response_elapsed_ms'], isNull);
    expect(replay['anchor_provenance'], 'replayed');
    expect(replay['anomaly'], 'missing');
    expect(
      () => validateV2Clock({...good, 'qr_elapsed_ms': 9007199254740992}),
      throwsFormatException,
    );
    expect(() => validateV2Clock({...good, 'extra': 0}), throwsFormatException);
  });

  test(
    'warnings are half-open, consecutive, checkpoint and segment scoped',
    () {
      final warning = V2Warnings();
      final cp = scope.checkpoints.first;
      final early = observation(3200);
      final onTime = observation(3601200);
      final late = observation(7201200);
      expect(warning.observe(cp, early), V2Warning.early);
      warning.acknowledge();
      expect(warning.observe(cp, early), isNull);
      expect(warning.observe(cp, onTime), isNull);
      expect(warning.observe(cp, early), V2Warning.early);
      warning.acknowledge();
      expect(warning.observe(cp, late), V2Warning.late);
      warning.acknowledge();
      expect(warning.observe(scope.checkpoints.last, early), V2Warning.early);
      warning.acknowledge();
      warning.reset();
      expect(warning.observe(scope.checkpoints.last, early), V2Warning.early);
      expect(warning.observe(cp, V2Observation()), V2Warning.unknown);
    },
  );

  test(
    'four successor RPCs use exact endpoint names and pinned bearer',
    () async {
      final observed = <String>[];
      final client = SupabaseClient(
        'https://project.example',
        'sb_publishable_synthetic_test',
        httpClient: MockClient((request) async {
          observed.add(request.url.path);
          expect(request.headers['authorization'], 'Bearer owner-token');
          return http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
        accessToken: () async => 'other-token',
      );
      addTearDown(client.dispose);
      for (final rpc in V2Rpc.values) {
        await pinnedV2Rpc(client, rpc, {'synthetic': true}, 'owner-token');
      }
      expect(observed, [
        '/rest/v1/rpc/prepare_offline_capture_v2',
        '/rest/v1/rpc/get_offline_preparation_status_v2',
        '/rest/v1/rpc/submit_offline_capture_v2',
        '/rest/v1/rpc/complete_offline_preparation_v2',
      ]);
    },
  );

  group('SQLCipher and fixture controller', () {
    late Directory directory;
    late String databasePath;
    late MemorySecureValues keys;
    late SecureAttendanceStore store;
    late FakeClock clock;
    late FakeV2Backend backend;
    late OfflineV2Controller controller;
    late String owner;
    late int epoch;
    late bool foreground;
    late int liveLookups;

    Future<SecureAttendanceStore> open({
      String staff = staffA,
      MemorySecureValues? keyStore,
    }) => SecureAttendanceStore.open(
      databasePath: databasePath,
      legacyDatabasePath: path.join(directory.path, 'legacy.db'),
      staffUserId: staff,
      keyStore: keyStore ?? keys,
    );

    OfflineV2Controller bind() => OfflineV2Controller(
      store: store,
      currentStaffId: () => owner,
      accountEpoch: () => epoch,
      liveSession: () async {
        liveLookups++;
        return StaffScanSession(staffUserId: owner, accessToken: 'owner-token');
      },
      foreground: () => foreground,
      rpc: backend.call,
      clock: clock.call,
    );

    Future<void> prepare() async {
      controller.selectFixture(scope);
      clock.pair(1000, 1200);
      await controller.prepare();
    }

    Future<V2Claim> capture({
      String id = '00000123456',
      int qr = 3603200,
      String? boot = 'boot_8',
    }) async {
      clock.pair(qr, qr + 200, boot: boot);
      final pending = await controller.observeQr(id);
      if (pending.warning != null) controller.continueAfterWarning(pending);
      return controller.confirm(pending);
    }

    void start() {
      controller.resume();
      controller.selectCheckpoint(checkpointV2);
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('hnu-v2-');
      databasePath = path.join(directory.path, 'encrypted.db');
      keys = MemorySecureValues();
      store = await open();
      clock = FakeClock();
      backend = FakeV2Backend();
      owner = staffA;
      epoch = 0;
      foreground = true;
      liveLookups = 0;
      controller = bind();
    });

    tearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    test('original request is durable before dispatch; capture is local even online', () async {
      backend.beforePrepare = (params) {
        final request = store.reserveV2Request(scope, observation(9000));
        expect(request.created, isFalse);
        expect(request.id, params['p_request_id']);
        expect(request.observation.elapsedMs, 1000);
      };
      await prepare();
      start();
      final before = liveLookups;
      final claim = await capture();
      expect(claim.parameters['p_student_id'], '00000123456');
      expect(
        claim.id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(claim.parameters['p_clock']['anomaly'], 'none');
      expect(liveLookups, before);
      expect(backend.calls, [V2Rpc.prepare]);
      expect(controller.counts!.queued, 1);
      expect(controller.installationUnresolved, 1);
      expect(
        () => store.offlineRequest(eventId, assignmentA),
        throwsStateError,
      );
      await expectLater(
        store.createPending(
          eventId: eventId,
          checkpointId: checkpointId,
          studentId: 'SYNTHETIC-LEGACY',
        ),
        throwsStateError,
      );
      await expectLater(controller.observeQr('REAL-123'), throwsStateError);
      expect(
        store.unresolvedV2Claims(preparationV2).single.payload,
        claim.payload,
      );
    });

    test(
      'same boot restart recovers; reboot and long overrun remain evidence',
      () async {
        await prepare();
        start();
        final original = await capture();
        await store.close();
        store = await open();
        controller = bind();
        controller.selectFixture(scope);
        expect(controller.collecting, isFalse);
        expect(controller.selected!.anchor.response!.elapsedMs, 1200);
        start();
        final sameBoot = await capture(qr: 3604200);
        expect(sameBoot.parameters['p_clock']['anomaly'], 'none');
        final reboot = await capture(qr: 100, boot: 'boot_9');
        expect(reboot.parameters['p_clock']['anomaly'], 'reboot');
        final late = await capture(qr: 12 * 3600000 + 1200);
        expect(
          late.parameters['p_clock']['qr_elapsed_ms'],
          12 * 3600000 + 1200,
        );
        expect(
          store.unresolvedV2Claims(preparationV2).first.payload,
          original.payload,
        );
        expect(backend.calls, [V2Rpc.prepare]);
      },
    );

    test(
      'lost preparation receipt replays request without fresh anchor',
      () async {
        backend.losePrepare = true;
        controller.selectFixture(scope);
        clock.samples.add(observation(1000));
        await expectLater(
          controller.prepare(),
          throwsA(isA<TimeoutException>()),
        );
        final original = backend.requestId;
        await store.close();
        store = await open();
        controller = bind();
        controller.selectFixture(scope);
        clock.pair(9000, 9200);
        await controller.prepare();
        expect(backend.requestId, original);
        expect(controller.selected!.anchor.request.elapsedMs, 1000);
        expect(controller.selected!.anchor.response, isNull);
        start();
        final claim = await capture();
        expect(claim.parameters['p_clock']['anchor_provenance'], 'replayed');
        expect(
          claim.parameters['p_clock']['anchor_response_elapsed_ms'],
          isNull,
        );
      },
    );

    test(
      'warnings require continuation and reset on stop/checkpoint change',
      () async {
        await prepare();
        start();
        clock.samples.add(observation(3200));
        final early = await controller.observeQr('SYNTHETIC-EARLY');
        expect(early.warning, V2Warning.early);
        await expectLater(controller.confirm(early), throwsStateError);
        controller.continueAfterWarning(early);
        clock.samples.add(observation(3400));
        await controller.confirm(early);
        clock.samples.add(observation(4200));
        final suppressed = await controller.observeQr('SYNTHETIC-NEXT');
        expect(suppressed.warning, isNull);
        controller.cancelQr();
        controller.selectCheckpoint(checkpointV2Out);
        clock.samples.add(observation(5200));
        expect(
          (await controller.observeQr('SYNTHETIC-EXIT')).warning,
          V2Warning.early,
        );
        controller.stop();
        start();
        clock.samples.add(observation(6200));
        expect(
          (await controller.observeQr('SYNTHETIC-RESTART')).warning,
          V2Warning.early,
        );
        expect(backend.calls, [V2Rpc.prepare]);
      },
    );

    test(
      'lost acknowledgement retries exact payload after seal, not unsent claim',
      () async {
        await prepare();
        start();
        final first = await capture();
        final second = await capture(id: 'SYNTHETIC-SECOND', qr: 3604200);
        controller.stop();
        await expectLater(controller.sync(), throwsStateError);
        expect(backend.sent, isEmpty);
        backend.state = 'SYNCING';
        backend.loseSubmit = true;
        await expectLater(controller.sync(), throwsA(isA<TimeoutException>()));
        expect(controller.counts!.attempted, 1);
        expect(controller.counts!.queued, 1);
        backend.sealed = true;
        await expectLater(controller.sync(), throwsStateError);
        expect(backend.sent, [first.parameters, first.parameters]);
        expect(controller.counts!.submitted, 1);
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          second.payload,
        );
        expect(() => controller.resume(), throwsStateError);
        backend.sealed =
            false; // Contradictory server response must fail closed.
        await expectLater(controller.sync(), throwsStateError);
        expect(backend.sent, [first.parameters, first.parameters]);
        backend.sealed = true;
        await expectLater(controller.complete(1), throwsStateError);
        expect(backend.completions, isEmpty);
      },
    );

    test(
      'contradictory OPEN to DRAFT status durably stops capture',
      () async {
        await prepare();
        start();
        final claim = await capture();
        controller.stop();
        backend.state = 'OPEN';
        expect((await controller.checkStatus()).state, 'OPEN');
        expect(controller.selected!.canCapture, isTrue);

        backend.state = 'DRAFT';
        await expectLater(
          controller.checkStatus(),
          throwsA(isA<V2StatusContradiction>()),
        );
        expect(controller.selected!.canCapture, isFalse);
        expect(() => controller.resume(), throwsStateError);
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          claim.payload,
        );

        await store.close();
        store = await open();
        controller = bind();
        controller.selectFixture(scope);
        expect(controller.selected!.canCapture, isFalse);
        expect(() => controller.resume(), throwsStateError);
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          claim.payload,
        );
        // The rejected status must not replace the retained OPEN state.
        await expectLater(
          controller.checkStatus(),
          throwsA(isA<V2StatusContradiction>()),
        );
        backend.state = 'OPEN';
        expect((await controller.checkStatus()).state, 'OPEN');
        expect(() => controller.resume(), throwsStateError);
        expect(backend.sent, isEmpty);
      },
    );

    test(
      'definitive deadline denial is queued; extension allows exact retry',
      () async {
        await prepare();
        start();
        final claim = await capture();
        controller.stop();
        backend.state = 'SYNCING';
        backend.denySubmit = '55000';
        await expectLater(
          controller.sync(),
          throwsA(isA<PostgrestException>()),
        );
        expect(controller.counts!.queued, 1);
        expect(controller.counts!.attempted, 0);
        backend.denySubmit = null;
        backend.deadlineHours = 30;
        await controller.sync();
        expect(backend.sent, [claim.parameters, claim.parameters]);
        expect(controller.counts!.submitted, 1);
      },
    );

    test(
      'malformed ack retains attempt; loss and conflict never skip',
      () async {
        await prepare();
        start();
        final first = await capture();
        await capture(id: 'SYNTHETIC-NEXT', qr: 3604200);
        controller.stop();
        backend.state = 'SYNCING';
        backend.malformedAck = true;
        await expectLater(controller.sync(), throwsFormatException);
        expect(controller.counts!.attempted, 1);
        backend.malformedAck = false;
        backend.denySubmit = '23505';
        await expectLater(
          controller.sync(),
          throwsA(isA<PostgrestException>()),
        );
        expect(controller.counts!.blocked, 1);
        expect(controller.counts!.queued, 1);
        backend.denySubmit = null;
        backend.sealed = true;
        backend.disposition = 'undrained';
        await expectLater(controller.sync(), throwsStateError);
        expect(backend.sent, [first.parameters, first.parameters]);
        expect(() => controller.resume(), throwsStateError);
        await expectLater(controller.complete(0), throwsStateError);
      },
    );

    test(
      'revocation retains the original evidence and stops capture',
      () async {
        await prepare();
        start();
        final claim = await capture();
        controller.stop();
        backend.state = 'SYNCING';
        backend.denyStatus = true;
        await expectLater(
          controller.sync(),
          throwsA(isA<PostgrestException>()),
        );
        expect(backend.sent, isEmpty);
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          claim.payload,
        );
        expect(() => controller.resume(), throwsStateError);
      },
    );

    test(
      'completion lost response survives restart and exact terminal retry',
      () async {
        await prepare();
        start();
        await capture();
        controller.stop();
        backend.state = 'SYNCING';
        await controller.sync();
        await expectLater(controller.complete(0), throwsStateError);
        backend.loseComplete = true;
        await expectLater(
          controller.complete(1),
          throwsA(isA<TimeoutException>()),
        );
        expect(controller.selected!.intent, 1);
        expect(() => controller.resume(), throwsStateError);
        await store.close();
        store = await open();
        controller = bind();
        controller.selectFixture(scope);
        backend.state = 'FINALIZED';
        backend.sealed = true;
        await controller.complete(1);
        expect(backend.completions, [1, 1]);
        expect(controller.selected!.completionReceipt!['replayed'], isTrue);
        expect(controller.selected!.disposition, 'completed');
        expect(() => controller.resume(), throwsStateError);
      },
    );

    test('zero is an explicit completion, not inferred from silence', () async {
      backend.state = 'OPEN';
      await prepare();
      backend.state = 'SYNCING';
      expect(backend.completions, isEmpty);
      await controller.complete(0);
      expect(backend.completions, [0]);
      expect(controller.selected!.intent, 0);
      expect(controller.selected!.disposition, 'completed');
    });

    test(
      'A-B-A switch during upload cannot write a late acknowledgement',
      () async {
        await prepare();
        start();
        final claim = await capture();
        controller.stop();
        backend.state = 'SYNCING';
        backend.submitStarted = Completer<void>();
        backend.releaseSubmit = Completer<void>();
        final syncing = controller.sync();
        final failed = expectLater(syncing, throwsStateError);
        await backend.submitStarted!.future;
        owner = staffB;
        epoch++;
        owner = staffA;
        epoch++;
        backend.releaseSubmit!.complete();
        await failed;
        expect(
          store.unresolvedV2Claims(preparationV2).single.state,
          V2ClaimState.attempted,
        );
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          claim.payload,
        );
        await controller.invalidate();
        store = await open(staff: staffB);
        expect(store.findV2Preparation(scope), isNull);
        expect(() => store.readV2Preparation(preparationV2), throwsStateError);
        await store.close();
        store = await open();
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          claim.payload,
        );
      },
    );

    test(
      'key loss leaves encrypted bytes unchanged; no plaintext evidence',
      () async {
        await prepare();
        start();
        final claim = await capture(id: 'SYNTHETIC-CIPHERTEXT');
        await store.close();
        final bytes = await File(databasePath).readAsBytes();
        expect(latin1.decode(bytes), isNot(contains('SYNTHETIC-CIPHERTEXT')));
        expect(latin1.decode(bytes), isNot(contains(claim.id)));
        await expectLater(
          open(keyStore: MemorySecureValues()),
          throwsStateError,
        );
        expect(await File(databasePath).readAsBytes(), bytes);
        store = await open();
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          claim.payload,
        );
      },
    );

    test(
      'populated v3 upgrade leaves every legacy row and count intact',
      () async {
        final fixture = OfflineFixture(DateTime.utc(2026, 11, 24, 1));
        final request = store.offlineRequest(eventId, assignmentA);
        final prep = fixture.parse(request.id);
        store.saveOfflinePreparation(prep);
        final guard = fixture.guard(prep);
        final queued = store.createOfflineClaim(
          guard: guard,
          checkpointId: checkpointId,
          studentId: 'SYNTHETIC-V1-QUEUED',
        );
        final blocked = store.createOfflineClaim(
          guard: guard,
          checkpointId: checkpointId,
          studentId: 'SYNTHETIC-V1-BLOCKED',
        );
        store.blockOffline(blocked);
        final fixture2 = OfflineFixture(
          fixture.issued,
          assignment: assignmentB,
          preparation: preparationB,
        );
        final request2 = store.offlineRequest(eventId, assignmentB);
        final prep2 = fixture2.parse(request2.id);
        store.saveOfflinePreparation(prep2);
        final submitted = store.createOfflineClaim(
          guard: fixture2.guard(prep2),
          checkpointId: checkpointId,
          studentId: 'SYNTHETIC-V1-SUBMITTED',
        );
        store.acknowledgeOffline(
          submitted,
          OfflineAcknowledgement(fixture.issued, false),
        );
        store.persistCompletionIntent(preparationB, 1);
        final pending = await store.createPending(
          eventId: eventId,
          checkpointId: checkpointId,
          studentId: 'SYNTHETIC-ONLINE-PENDING',
        );
        await store.close();
        final key = keys.values[SecureAttendanceStore.encryptionKeyName]!;
        Database raw() {
          final db = sqlite3.open(databasePath);
          db.execute("PRAGMA key = \"x'$key'\";");
          return db;
        }

        final old = raw();
        for (final table in [
          'offline_v2_claims',
          'offline_v2_preparations',
          'offline_v2_requests',
        ]) {
          old.execute('DROP TABLE $table;');
        }
        old.execute('PRAGMA user_version = 3;');
        const tables = [
          'attendance_scans',
          'offline_requests',
          'offline_preparations',
          'offline_claims',
          'offline_accounting',
        ];
        Map<String, Object> snapshot(Database db) => {
          for (final table in tables)
            table: db
                .select('SELECT * FROM $table ORDER BY rowid;')
                .map((row) => row.values.toList())
                .toList(),
        };
        final before = snapshot(old);
        old.close();
        store = await open();
        expect(
          store.readQueuedOffline(preparationA).single.parameters,
          queued.parameters,
        );
        expect(store.preparationSummary(preparationA).counts.blocked, 1);
        expect(store.preparationSummary(preparationB).intent, 1);
        expect((await store.readPending()).single.scanId, pending.scanId);
        expect(
          () => store.reserveV2Request(scope, observation(1000)),
          throwsStateError,
        );
        await store.close();
        final after = raw();
        expect(after.select('PRAGMA user_version;').single.values.single, 4);
        expect(snapshot(after), before);
        after.close();
        // Another account's v2 claim can coexist, but the guard counts both.
        store = await open(staff: staffB);
        final v2req = store.reserveV2Request(scope, observation(1000));
        final v2prep = V2Preparation.parse(
          {...prepResponse(v2req.id), 'staff_user_id': staffB},
          scope,
          staffB,
          v2req.id,
        );
        store.saveV2Preparation(
          v2req,
          v2prep,
          V2Anchor(observation(1000), observation(1200), 'original'),
        );
        final v2claim = store.createV2Claim(
          preparationId: preparationV2,
          checkpointId: checkpointV2,
          studentId: 'SYNTHETIC-V2-QUEUED',
          qr: observation(3603200),
          confirmation: observation(3603400),
        );
        expect(store.installationUnresolvedCount(), 3);
        expect(store.preparations(), isEmpty);
        await store.close();
        store = await open();
        expect(store.findV2Preparation(scope), isNull);
        expect(store.installationUnresolvedCount(), 3);
        expect(store.readQueuedOffline(preparationA).single.id, queued.id);
        await store.close();
        store = await open(staff: staffB);
        expect(
          store.unresolvedV2Claims(preparationV2).single.payload,
          v2claim.payload,
        );
      },
    );

    testWidgets(
      'fixture UI warns, confirms, masks and never uploads from capture',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        clock.pair(1000, 1200);
        await tester.pumpWidget(
          MaterialApp(
            home: OfflineV2FixtureWorkspace(
              controller: controller,
              fixtures: [scope],
              accountChanges: const Stream<void>.empty(),
              scannerBuilder: (_, onValue, _) => TextButton(
                onPressed: () => onValue('00000123456'),
                child: const Text('Emit synthetic QR'),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fixture 1').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Prepare online'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Resume local collection'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Entrance (IN)').last);
        await tester.pumpAndSettle();
        clock.pair(3200, 3400);
        await tester.tap(find.text('Scan QR'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Emit synthetic QR'));
        // A busy indicator animates behind the modal until capture finishes.
        // Advance route transitions without waiting for all tickers to stop.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Schedule warning'), findsOneWidget);
        await tester.tap(find.text('Continue'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Confirm local capture'), findsOneWidget);
        expect(find.textContaining('••••3456'), findsOneWidget);
        expect(find.textContaining('00000123456'), findsNothing);
        await tester.tap(find.text('Save locally'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Queued: 1'), findsOneWidget);
        expect(backend.calls, [V2Rpc.prepare]);
      },
    );
  });
}
